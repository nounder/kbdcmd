import ApplicationServices
import Cocoa

final class Snippets {
  private static let backspaceKeyCode: CGKeyCode = 51  // Backspace
  private static let nonCharacterModifierMask: UInt64 = {
    CGEventFlags.maskControlLeft.rawValue | CGEventFlags.maskControlRight.rawValue
      | CGEventFlags.maskOptionLeft.rawValue | CGEventFlags.maskOptionRight.rawValue
      | CGEventFlags.maskCmdLeft.rawValue | CGEventFlags.maskCmdRight.rawValue
  }()

  private static func deleteCharacters(count: Int) {
    guard count > 0 else { return }
    for _ in 0..<count {
      simulateKeyPress(keyCode: backspaceKeyCode, flags: [])
    }
  }

  private static func typedCharacterCount(in sequence: [KeyPress]) -> Int {
    var count = 0
    for press in sequence {
      switch press.key {
      case .character:
        let hasNonCharMods = (press.flags.rawValue & nonCharacterModifierMask) != 0
        if !hasNonCharMods {
          count += 1
        }
      case .named:
        break
      }
    }
    return count
  }

  static func expandSnippet(for sequence: [KeyPress], insert text: String) {
    let toDelete = typedCharacterCount(in: sequence)
    deleteCharacters(count: toDelete)
    for ch in text {
      if let keyCode = KeyListener.stringToKeyCode(char: String(ch)) {
        simulateKeyPress(keyCode: keyCode, flags: [])
      }
    }
  }
}
