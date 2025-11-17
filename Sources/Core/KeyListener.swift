import Carbon
import Cocoa
import IOKit.hid
import InputMethodKit

@available(macOS 15.0, *)
public class KeyListener {
  public static let shared = KeyListener()

  // Task that runs the event stream
  private var eventStreamTask: Task<Void, Never>?

  private var eventTap: CFMachPort?
  private var sequenceBuffer: [KeyPress] = []
  private var lastKeyPressTime: Date = Date()
  private var overlayShowTimer: Timer?

  /**
   * Tracks the physical state of the Caps Lock key via HID events.
   *
   * This is ONLY used when Caps Lock is mapped to "No Action" in System Settings.
   * When Caps Lock is mapped to another modifier (Control, Option, etc.), we rely on
   * CG event flags instead since the system provides them correctly.
   *
   * - nil: Caps Lock is NOT mapped to "No Action" - use CG event flags
   * - false: Caps Lock is mapped to "No Action" and key is released (or startup state)
   * - true: Caps Lock is mapped to "No Action" and key is pressed
   *
   * Race Handling:
   * HID events may arrive on a background queue and can precede or lag behind CG events.
   * We maintain this state from HID callbacks and check it when processing keyDown events,
   * but only inject .maskAlphaShift when capsLockRemapping is detected as "No Action".
   *
   * Device Handling:
   * This state is reset to nil when any keyboard device connects or disconnects to force re-detection.
   */
  private var isPhysicalCapsLockPressed: Bool? = false

  /**
   * Tracks what Caps Lock is remapped to in System Settings.
   *
   * Detected by observing flagsChanged events when Caps Lock key (keyCode 57/62) is pressed.
   *
   * When Caps Lock is remapped to act as another modifier, macOS sets an additional flag 0x100 (256)
   * in the event flags to distinguish it from the real modifier key. This is the "Caps Lock as modifier" marker.
   *
   * Flag patterns when Caps Lock is held (remapped):
   * - caps-as-option:  0x80100 (524608) vs option:  0x80080 (524576) - difference includes 0x100
   * - caps-as-control: 0x42100 (270592) vs control: 0x40101 (262401) - difference includes 0x100
   * - caps-as-command: 0x100110 (1048848) vs command: 0x100108 (1048840) - difference includes 0x100
   * - caps-as-globe:   0x800100 (8388864) same as globe (no way to distinguish)
   *
   * Detection strategy:
   * 1. Check if flag delta includes 0x100 - indicates Caps Lock remapped as modifier
   * 2. Check which standard modifier flag is also present to determine the target
   * 3. If only maskAlphaShift changed - standard Caps Lock
   * 4. If no flags changed - "No Action" (use HID tracking)
   *
   * Reset to nil on keyboard device changes to force re-detection.
   */
  private var capsLockRemapping: KeyboardModifierAction? = nil
  private var previousCGEventFlags: CGEventFlags.RawValue = 0

  /**
  * As seen in System Settings -> Keyboard -> Modifier Keys
  */
  private enum KeyboardModifierAction {
    case capsLock  // Caps Lock (maskAlphaShift)
    case control  // Control
    case option  // Option
    case shift  // Shift
    case command  // Command
    case globe  // Globe/Fn
    case noAction  // No Action - use HID tracking
  }

  // flag when Caps Lock is used as a remapped modifier (not the actual modifier key)
  private static let kCapsLockAsModifierFlag: UInt64 = 0x100

  private let hidMonitor = KeyboardHIDMonitor(
    monitorKeys: true,
    monitorDevices: true
  )
  private var hidKeyHandle: KeyboardHIDMonitor.CallbackHandle?
  private var hidDeviceHandle: KeyboardHIDMonitor.CallbackHandle?

  // keycodes are in the range 0-127
  // >3x faster than dictionary lookup
  private var keyCodeToKey: [Key?] = []

  private func buildKeyCodeCache() -> [Key?] {
    var cache: [Key?] = Array(repeating: nil, count: 128)

    for specialKey in Key.Named.allCases {
      let idx = Int(specialKey.rawValue)
      if idx < 128 {
        cache[idx] = .named(specialKey)
      }
    }

    // scan for character keys (skip already-mapped special keys)
    let inputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    guard let layoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
    else {
      return cache
    }
    let keyboardLayout = unsafeBitCast(
      CFDataGetBytePtr(unsafeBitCast(layoutData, to: CFData.self)),
      to: UnsafePointer<UCKeyboardLayout>.self
    )

    for keyCode in 0..<128 {
      // Skip if already mapped as special key
      if cache[keyCode] != nil { continue }

      var deadKeyState: UInt32 = 0
      var length = 0
      var chars = [UniChar](repeating: 0, count: 4)

      let status = UCKeyTranslate(
        keyboardLayout,
        UInt16(keyCode),
        UInt16(kUCKeyActionDisplay),
        0,
        UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysBit),
        &deadKeyState,
        4,
        &length,
        &chars
      )

      if status == noErr && length > 0 {
        let string = String(utf16CodeUnits: chars, count: length).uppercased()
        if let char = string.first {
          cache[keyCode] = .character(char)
        }
      }
    }

    return cache
  }

  init() {
    debugLog("KeyListener initializing...")
    // Build initial key code cache
    keyCodeToKey = buildKeyCodeCache()
    debugLog("Initial key code cache built")

    setupListeners()
  }

  private func setupListeners() {
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(keyboardInputSourceChanged),
      name: NSNotification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String),
      object: nil
    )
    debugLog("Registered for keyboard input source change notifications")

    // Set up HID monitor for Caps Lock key events
    hidKeyHandle = hidMonitor.onKeyEvent { [weak self] event in
      guard let self = self else { return }
      guard case let .key(page, usage, pressed) = event.kind,
        page == UInt32(kHIDPage_KeyboardOrKeypad),
        usage == UInt32(kHIDUsage_KeyboardCapsLock)
      else { return }

      // Always track physical state - we may not know the remapping yet
      if self.isPhysicalCapsLockPressed != pressed {
        self.isPhysicalCapsLockPressed = pressed
        debugLog("Physical CapsLock state = \(pressed) from device: \(event.device.product)")

        // If we're pressing Caps Lock but remapping is unknown, try to detect it
        if pressed && self.capsLockRemapping == nil {
          // Wait a brief moment for CG events, then check if we got flags
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }
            // If still no remapping detected, it's "No Action"
            if self.capsLockRemapping == nil {
              self.capsLockRemapping = .noAction
              debugLog("Caps Lock remapping detected: No Action (no CG flags observed)")
            }
          }
        }
      }
    }

    // Register for device change events to reset Caps Lock state
    hidDeviceHandle = hidMonitor.onDeviceChange { [weak self] event in
      guard let self = self else { return }
      switch event.kind {
      case .deviceConnected(let device):
        self.isPhysicalCapsLockPressed = nil
        self.capsLockRemapping = nil
        debugLog(
          "Keyboard connected (\(device.product)), resetting physical CapsLock state and remapping detection"
        )
      case .deviceDisconnected(let device):
        self.isPhysicalCapsLockPressed = nil
        self.capsLockRemapping = nil
        debugLog(
          "Keyboard disconnected (\(device.product)), resetting physical CapsLock state and remapping detection"
        )
      default:
        break
      }
    }

    // Start HID monitoring
    do {
      try hidMonitor.start()
      debugLog("HID monitor started successfully")
    } catch {
      debugLog("ERROR: Failed to start HID monitor: \(error)")
    }

    // Event tap will be created when startAsync() is called
    debugLog("KeyListener initialized")
  }

  deinit {
    DistributedNotificationCenter.default().removeObserver(self)
    hidKeyHandle = nil
    hidDeviceHandle = nil
    hidMonitor.stop()
  }

  @objc private func keyboardInputSourceChanged(_ notification: Notification) {
    debugLog("Keyboard input source changed, rebuilding key code cache")
    keyCodeToKey = buildKeyCodeCache()
    debugLog("Key code cache rebuilt")
  }

  static func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Bool {
    // Delegate overlay event handling to OverlayManager
    if OverlayManager.shared.interceptEvent(type: type, event: event) {
      return true
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

    if type == .keyDown || type == .keyUp || type == .flagsChanged {
      if type == .flagsChanged {
        debugLog(
          "flagsChanged event - keyCode=\(keyCode), flags=\(event.flags.rawValue), maskAlphaShift=\(event.flags.contains(.maskAlphaShift))"
        )
      }
      debugLog(
        "Event type=\(type.rawValue), keyCode=\(keyCode), flags=\(event.flags.rawValue)")
    }

    if type == .flagsChanged {
      if keyCode == Key.Named.rightCommand.rawValue {
        if event.flags.contains(.maskCmdRight) {
          // Right Command pressed - start timer to show overlay after 400ms
          Self.shared.scheduleOverlayShow()
        } else {
          // Right Command released - cancel timer and hide only window switcher
          Self.shared.cancelOverlayShow()
          // Only hide window switcher overlay (not sticky overlays like keybinding assignment or hint)
          if OverlayManager.shared.isWindowSwitcherVisible {
            OverlayManager.shared.hideActive()
          }
        }
      }

      handleCapsLockDetection(currentFlags: event.flags.rawValue)
      return false
    }

    // Handle keyUp events
    if type == .keyUp {
      // No special handling needed - HID events and flagsChanged handle state tracking
      return false
    }

    // a key with rcmd is pressed
    if type == .keyDown {
      let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

      // Skip Caps Lock key itself - it's handled via flagsChanged and HID events
      if keyCode == 57 || keyCode == 62 {
        return false  // Don't consume the event, let it pass through
      }

      // Fast array lookup: keyCode → Key (single operation!)
      guard keyCode >= 0 && keyCode < 128,
        let key = Self.shared.keyCodeToKey[Int(keyCode)]
      else {
        return false
      }

      // Handle Caps Lock modifier injection when mapped to "No Action"
      //
      // When Caps Lock is remapped to "No Action" in System Settings, CG events don't include
      // any modifier flags. We detect this via capsLockRemapping == .noAction.
      // In this case, we inject .maskAlphaShift when the physical key is pressed (tracked via HID).
      //
      // When Caps Lock is mapped to another modifier (Control, Option, etc.), we rely on CG events
      // to provide the correct flags and do NOT inject anything - the system handles it correctly.
      //
      // CGEventFlags is a struct (value type), so this creates a copy
      var eventFlags = CGEventFlags(rawValue: event.flags.rawValue)
      if Self.shared.capsLockRemapping == .noAction {
        // Caps Lock is mapped to "No Action" - use HID tracking to inject maskAlphaShift
        if Self.shared.isPhysicalCapsLockPressed == true
          && !eventFlags.contains(.maskAlphaShift)
        {
          eventFlags.insert(.maskAlphaShift)
          debugLog(
            "Injecting .maskAlphaShift for keyCode=\(keyCode) (Caps Lock mapped to No Action)")
        }
      }
      // else: Caps Lock is mapped to a modifier - CG events already have correct flags, don't inject

      // Another key pressed while holding right command - cancel overlay show
      if event.flags.contains(.maskCmdRight) {
        Self.shared.cancelOverlayShow()
      }

      Self.shared.processKeyPress(key, flags: eventFlags)

      // always consume when rcmd is active.
      // we're keeping this modifier for ourselves :3

      if event.flags.contains(.maskCmdRight) {
        return true
      }
    }

    return false
  }

  private func scheduleOverlayShow() {
    // Cancel any existing timer
    overlayShowTimer?.invalidate()

    overlayShowTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
      OverlayManager.shared.showWindowSwitcherOverlay()
    }
  }

  public func cancelOverlayShow() {
    overlayShowTimer?.invalidate()
    overlayShowTimer = nil
  }

  private static func handleCapsLockDetection(currentFlags: UInt64) {
    let previousFlags = Self.shared.previousCGEventFlags
    let flagDelta = currentFlags ^ previousFlags

    // Check if Caps Lock markers are being ADDED (not removed or staying the same)
    // AND that no other major modifiers are being added simultaneously (to avoid detecting
    // Shift+CapsLock as a CapsLock event when CapsLock is already held)
    let capsLockFlagAdded =
      ((flagDelta & kCapsLockAsModifierFlag) != 0
        && (currentFlags & kCapsLockAsModifierFlag) != 0)
      || ((flagDelta & CGEventFlags.maskAlphaShift.rawValue) != 0
        && (currentFlags & CGEventFlags.maskAlphaShift.rawValue) != 0)

    // Check if other major modifiers (shift, control, option, command) are being added
    let otherModifiersAdded =
      (flagDelta & 0x20000) != 0  // Shift
      || (flagDelta & 0x40000) != 0  // Control
      || (flagDelta & 0x80000) != 0  // Option
      || (flagDelta & 0x100000) != 0  // Command

    if capsLockFlagAdded && !otherModifiersAdded {
      let detectedRemapping = detectCapsLockRemapping(from: currentFlags)

      // Only update remapping on press (when flags are increasing), not on release
      // Check if we're pressing (adding flags beyond just 0x100)
      let isPress = currentFlags > previousFlags && currentFlags > 0x100

      if isPress {
        let previousRemapping = Self.shared.capsLockRemapping
        Self.shared.capsLockRemapping = detectedRemapping

        // When remapping changes, update physical state tracking accordingly
        if detectedRemapping == .noAction {
          // Enable physical state tracking for "No Action"
          if Self.shared.isPhysicalCapsLockPressed == nil {
            Self.shared.isPhysicalCapsLockPressed = false
          }
        } else {
          // Disable physical state tracking for other remappings (rely on CG flags)
          Self.shared.isPhysicalCapsLockPressed = nil
        }

        debugLog(
          "CapsLock press - flags: 0x\(String(currentFlags, radix: 16)), remapping: \(capsLockRemappingDescription(detectedRemapping))"
        )

        // Log when remapping changes (only if we had a previous remapping)
        if let prevRemapping = previousRemapping, detectedRemapping != prevRemapping {
          let prevDesc = capsLockRemappingDescription(prevRemapping)
          let newDesc = capsLockRemappingDescription(detectedRemapping)
          debugLog("Caps Lock remapping changed: \(prevDesc) -> \(newDesc)")
        }
      }
    }

    // Always track flags for all events to maintain state
    Self.shared.previousCGEventFlags = currentFlags
  }

  private func processKeyPress(_ key: Key, flags: CGEventFlags) -> Bool {
    let currentTime = Date()
    if currentTime.timeIntervalSince(lastKeyPressTime) > 0.2 {
      sequenceBuffer.removeAll()
    }
    lastKeyPressTime = currentTime

    sequenceBuffer.append(KeyPress(key: key, flags: flags))

    let result = Keybindings.shared.matchSequence(sequenceBuffer)

    switch result {
    case .complete(let action, let sequence, let consume):
      sequenceBuffer.removeAll()
      action(sequence)
      // Return consume flag: if consume=true, prevent event from reaching app
      // if consume=false, let the event pass through to the app
      return consume

    case .partial:
      // Waiting for more keys in sequence, don't consume event
      return false

    case .noMatch:
      // Not a sequence, reset and let key through
      sequenceBuffer.removeAll()
      return false
    }
  }

  public static func keyCodeToString(keyCode: Int, event: CGEvent) -> String? {
    guard
      let inputSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
      let layoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData),
      let keyboardLayout = unsafeBitCast(layoutData, to: CFData.self) as Data?
    else {
      return nil
    }

    var deadKeyState: UInt32 = 0
    var stringLength = 0
    var unicodeString = [UniChar](repeating: 0, count: 4)

    let modifiers = event.flags.rawValue

    keyboardLayout.withUnsafeBytes { layoutBytes in
      guard let layoutPtr = layoutBytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
      else {
        return
      }

      UCKeyTranslate(
        layoutPtr,
        UInt16(keyCode),
        UInt16(kUCKeyActionDown),
        UInt32(modifiers >> 16),
        UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysMask),
        &deadKeyState,
        4,
        &stringLength,
        &unicodeString)
    }

    return stringLength > 0 ? String(utf16CodeUnits: unicodeString, count: stringLength) : nil
  }

  public static func stringToKeyCode(char: String) -> CGKeyCode? {
    guard
      let inputSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
      let layoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData),
      let keyboardLayout = unsafeBitCast(layoutData, to: CFData.self) as Data?
    else {
      return nil
    }

    var deadKeyState: UInt32 = 0
    let maxStringLength = 4
    var actualStringLength = 0
    var unicodeString = [UniChar](repeating: 0, count: maxStringLength)

    for keyCode in 0...127 {
      for keyboardType in 0...10 {
        keyboardLayout.withUnsafeBytes { layoutBytes in
          guard
            let layoutPtr = layoutBytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
          else {
            return
          }

          UCKeyTranslate(
            layoutPtr,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(keyboardType),
            OptionBits(kUCKeyTranslateNoDeadKeysMask),
            &deadKeyState,
            maxStringLength,
            &actualStringLength,
            &unicodeString)
        }

        if String(utf16CodeUnits: unicodeString, count: Int(actualStringLength)) == char {
          return CGKeyCode(keyCode)
        }
      }
    }

    return nil
  }

  /// Starts the event listener using AsyncStream (modern async/await approach)
  public func startAsync() async {
    debugLog("Starting KeyListener with AsyncStream...")

    // Create event mask for keyDown, keyUp, flagsChanged, and mouse events
    let eventMask: CGEventMask =
      (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
      | (1 << CGEventType.flagsChanged.rawValue)
      | (1 << CGEventType.leftMouseDown.rawValue)

    // Create AsyncStream for events
    let eventStream = AsyncStreamUtils.eventTapStream(eventsOfInterest: eventMask)

    // Process events from the stream
    for await (event, proxy) in eventStream {
      let type = event.type
      let handled = Self.handleEvent(proxy: proxy, type: type, event: event)

      // If not handled, the event will pass through
      // The AsyncStream implementation handles this automatically
    }

    debugLog("KeyListener event stream ended")
  }

  /// Legacy synchronous start method (deprecated - use startAsync instead)
  @available(*, deprecated, message: "Use startAsync() instead")
  public func start() {
    Task {
      await startAsync()
    }
    // Keep the current thread alive
    RunLoop.current.run()
  }

  private static func detectCapsLockRemapping(from flags: UInt64) -> KeyboardModifierAction {
    let hasCapsAsModifierFlag = (flags & kCapsLockAsModifierFlag) != 0
    let hasAlphaShift = (flags & CGEventFlags.maskAlphaShift.rawValue) != 0

    // Priority: Check if both markers present first (standard Caps Lock)
    if hasCapsAsModifierFlag && hasAlphaShift {
      return .capsLock
    } else if hasCapsAsModifierFlag {
      // 0x100 marker present - Caps Lock is remapped as another modifier
      if flags & 0x40000 != 0 {
        return .control
      } else if flags & 0x80000 != 0 {
        return .option
      } else if flags & 0x100000 != 0 {
        return .command
      } else if flags & 0x20000 != 0 {
        return .shift
      } else if flags & 0x800000 != 0 {
        return .globe
      }
    } else if hasAlphaShift {
      return .capsLock
    }

    // Default to noAction if we can't determine
    return .noAction
  }

  private static func capsLockRemappingDescription(_ remapping: KeyboardModifierAction) -> String {
    switch remapping {
    case .capsLock:
      return "Caps Lock"
    case .control:
      return "Control"
    case .option:
      return "Option"
    case .shift:
      return "Shift"
    case .command:
      return "Command"
    case .globe:
      return "Globe/Fn"
    case .noAction:
      return "No Action"
    }
  }
}
