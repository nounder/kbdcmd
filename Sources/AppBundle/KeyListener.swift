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

  init() {
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
      print("Failed to create event tap")
      return
    }

    self.eventTap = eventTap
    let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
  }

  static func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Bool {
    // rcmd is pressed
    if type == .flagsChanged {
      let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
      
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
      
      return false
    }
    
    // a key with rcmd is pressed
    if type == .keyDown {
      let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

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

      if event.flags.contains(.maskCmdRight) {
        // Another key pressed while holding right command - cancel overlay show
        KeyListener.shared.cancelOverlayShow()
        return Keybindings.shared.processCharacter(keyCode)
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
