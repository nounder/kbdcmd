import Carbon
import Cocoa
import InputMethodKit

class KeyListener {
  static let shared = KeyListener()

  private var eventTap: CFMachPort?
  private var buffer: String = ""
  private var lastKeyPressTime: Date = Date()
  private let snippetManager = SnippetManager()
  private var overlayShowTimer: Timer?
  private var isCapsLockPressed: Bool = false
  
  // keycodes are in the range 0-127
  // >3x faster than dictionary lookup
  private lazy var keyCodeToKey: [Key?] = {
    var cache: [Key?] = Array(repeating: nil, count: 128)
    
    for specialKey in Key.Named.allCases {
      let idx = Int(specialKey.rawValue)
      if idx < 128 {
        cache[idx] = .named(specialKey)
      }
    }
    
    // Then, scan for character keys (skip already-mapped special keys)
    let inputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    guard let layoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
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
  }()

  init() {
    print("DEBUG: KeyListener initializing...")
    // Listen for keyDown, keyUp, and flagsChanged events (for modifier keys like right command)
    let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
    guard
      let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(eventMask),
        callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
          let handled = KeyListener.handleEvent(proxy: proxy, type: type, event: event)

          return handled ? nil : Unmanaged.passRetained(event)
        },
        userInfo: nil
      )
    else {
      print("ERROR: Failed to create event tap")
      return
    }

    self.eventTap = eventTap
    let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
    print("DEBUG: KeyListener initialized, event tap enabled")
  }

  static func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Bool {
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    
    // Debug: Print all events to see what we're receiving
    // Output goes to /tmp/kbcmd.stdout.log when running as daemon
    if type == .keyDown || type == .keyUp || type == .flagsChanged {
      // Log all flagsChanged events to see what we're getting
      if type == .flagsChanged {
        print("DEBUG: flagsChanged event - keyCode=\(keyCode), flags=\(event.flags.rawValue), maskAlphaShift=\(event.flags.contains(.maskAlphaShift))")
      }
      // Only log CapsLock-related events and J/K to reduce noise
      // CapsLock can be keyCode 57 (standard) or 62 (when disabled)
      if keyCode == 57 || keyCode == 62 || keyCode == 38 || keyCode == 40 {
        print("DEBUG: Event type=\(type.rawValue), keyCode=\(keyCode), flags=\(event.flags.rawValue)")
      }
    }
    
    // rcmd is pressed
    if type == .flagsChanged {
      
      // Right Command key code is 54
      if keyCode == 54 {
        if event.flags.contains(.maskCmdRight) {
          // Right Command pressed - start timer to show overlay after 400ms
          KeyListener.shared.scheduleOverlayShow()
        } else {
          // Right Command released - cancel timer and hide overlay
          KeyListener.shared.cancelOverlayShow()
          WindowSwitcherOverlay.shared.hide()
        }
      }
      
      // CapsLock detection - handle both keyCode 57 (standard) and 62 (when disabled)
      // CapsLock can have different keyCodes depending on keyboard type and system settings
      if keyCode == 57 || keyCode == 62 {
        // Determine if this is press or release based on flags value
        // For keyCode 57: check maskAlphaShift flag (standard CapsLock)
        // For keyCode 62: check flags value (when disabled, maskAlphaShift won't be set)
        let isPressed = keyCode == 57 ? event.flags.contains(.maskAlphaShift) : event.flags.rawValue > 256
        KeyListener.shared.isCapsLockPressed = isPressed
        print("DEBUG: CapsLock flagsChanged (keyCode=\(keyCode)), flags=\(event.flags.rawValue), setting isCapsLockPressed=\(isPressed)")
        
        // Stop scrolling if CapsLock is released
        if !isPressed {
          SmoothScrollManager.shared.stop()
        }
      }
      
      return false
    }
    
    // Handle keyUp events
    if type == .keyUp {
      // Check if CapsLock key is released (keyCode 57 or 62 depending on keyboard/system)
      if keyCode == 57 || keyCode == 62 {
        KeyListener.shared.isCapsLockPressed = false
        print("DEBUG: CapsLock keyUp detected (keyCode=\(keyCode)), setting isCapsLockPressed = false")
        SmoothScrollManager.shared.stop()
      }
      
      // Stop scrolling when J or K keys are released
      if keyCode == 38 || keyCode == 40 {  // J or K
        SmoothScrollManager.shared.stop()
        print("DEBUG: Scroll key released (keyCode=\(keyCode)), stopping scroll")
      }
      
      return false
    }
    
    // a key with rcmd is pressed
    if type == .keyDown {
      let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
      
      // Check if CapsLock key itself is pressed (keyCode 57 or 62 depending on keyboard/system)
      if keyCode == 57 || keyCode == 62 {
        KeyListener.shared.isCapsLockPressed = true
        print("DEBUG: CapsLock keyDown detected (keyCode=\(keyCode)), setting isCapsLockPressed = true")
        return false  // Don't consume the event, let it pass through
      }

      // ESC key (keyCode 53) dismisses accessibility overlay
      if keyCode == 53 && AccessibilityOverlay.shared.isVisible() {
        AccessibilityOverlay.shared.hide()
        return true
      }
      
      // If accessibility overlay is visible, handle keyboard events for overlay
      if AccessibilityOverlay.shared.isVisible() {
        let char = KeyListener.keyCodeToString(keyCode: Int(keyCode), event: event)
        if AccessibilityOverlay.shared.handleKeyboardEvent(keyCode: keyCode, characters: char) {
          return true  // Event was handled by overlay
        }
        return false  // Let other events pass through
      }

      // Handle CapsLock + J/K for smooth scrolling
      // Use our tracked state since CapsLock is disabled and maskAlphaShift won't be set
      if KeyListener.shared.isCapsLockPressed {
        print("DEBUG: CapsLock is active (tracked state), checking J/K keys, keyCode = \(keyCode)")
        if keyCode == 38 {  // J - scroll down
          print("DEBUG: Scrolling down")
          SmoothScrollManager.shared.scrollUnits(-10)  // 1 unit = ~800 pixels with 4x sensitivity
          return true
        } else if keyCode == 40 {  // K - scroll up
          print("DEBUG: Scrolling up")
          SmoothScrollManager.shared.scrollUnits(10)  // 1 unit = ~800 pixels with 4x sensitivity
          return true
        }
      }

      if event.flags.contains(.maskCmdRight) {
        // Another key pressed while holding right command - cancel overlay show
        KeyListener.shared.cancelOverlayShow()
        
        // Fast array lookup: keyCode → Key (single operation!)
        guard keyCode >= 0 && keyCode < 128,
              let key = KeyListener.shared.keyCodeToKey[Int(keyCode)] else {
          return false
        }
        
        return Keybindings.shared.processKey(key, flags: event.flags)
      } else {
        let char = KeyListener.keyCodeToString(keyCode: Int(keyCode), event: event)

        guard let char else {
          print("Error: Character is nil")

          return false
        }

        return KeyListener.shared.processCharacter(char)
      }
    }

    return false
  }
  
  private func scheduleOverlayShow() {
    // Cancel any existing timer
    overlayShowTimer?.invalidate()
    
    // Schedule new timer to show overlay after 200ms
    overlayShowTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
      WindowSwitcherOverlay.shared.show()
    }
  }
  
  private func cancelOverlayShow() {
    overlayShowTimer?.invalidate()
    overlayShowTimer = nil
  }

  private func processCharacter(_ char: String) -> Bool {
    let currentTime = Date()
    if currentTime.timeIntervalSince(lastKeyPressTime) > 0.4 {
      buffer = ""
    }
    lastKeyPressTime = currentTime

    buffer += char
    return checkAndExpandSnippet()
  }

  private func checkAndExpandSnippet() -> Bool {
    if let expansion = snippetManager.getExpansion(for: buffer) {
      expandSnippet(expansion)
      buffer = ""

      return true
    }

    return false
  }

  private func expandSnippet(_ expansion: String) {
    // Delete the trigger string
    for _ in 0..<buffer.count - 1 {
      simulateKeyPress(keyCode: 0x33, flags: [])  // Backspace key
    }

    // Type out the expansion
    for char in expansion {
      if let keyCode = KeyListener.stringToKeyCode(char: String(char)) {
        simulateKeyPress(keyCode: keyCode, flags: [])
      }
    }
  }

  static func keyCodeToString(keyCode: Int, event: CGEvent) -> String? {
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

  static func stringToKeyCode(char: String) -> CGKeyCode? {
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

  func start() {
    CFRunLoopRun()
  }
}
