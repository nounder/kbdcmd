import ApplicationServices
import Cocoa
import Foundation

struct KeyboardSimulator {
  static func simulateKeyPress(keyCode: CGKeyCode, flags: CGEventFlags) {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }

    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    else { return }

    keyDown.flags = flags
    keyUp.flags = flags

    keyDown.post(tap: .cghidEventTap)
    usleep(400)  // Small delay to ensure the event is processed
    keyUp.post(tap: .cghidEventTap)
  }
}
