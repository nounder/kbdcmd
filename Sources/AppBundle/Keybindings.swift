import Carbon
import Cocoa

class Keybindings {
  static let shared = Keybindings()

  private var rightCommandKeybindings: [Int64: () -> Void] = [
    37: {  // L
      cycleAppWindows()
    },
    2: {  // D
      // cmdOpenCycle("/Applications/kitty.app")
      cmdOpenCycle("/Applications/Ghostty.app")
    },
    1: {  // S
      cmdOpenCycle("/Applications/Safari.app")
    },
    3: {  // F
      cmdOpenCycle("/Applications/Google Chrome Canary.app")
    },
    9: {  // V
      cmdOpenCycle("/Applications/Cursor.app")
    },
    11: {  // B
      cmdOpenCycle("/Applications/Spotify.app")
    },
    8: {  // C
      cmdOpenCycle("/System/Applications/Calendar.app")
    },
    5: { // G
      cmdOpenCycle("/Applications/ChatGPT.app")
    },
    4: { // H
      cmdOpenCycle("/Users/rg/Applications/Claude.app")
    },
    38: { // J
      cmdOpenCycle("/Users/rg/Applications/Perplexity.app")
    },
    46: {  // M
      cmdOpenCycle("/System/Applications/Mail.app")
    },
    18: {  // 1
      switchToDesktop(number: 1)
    },
    19: {  // 2
      switchToDesktop(number: 2)
    },
    20: {  // 3
      switchToDesktop(number: 3)
    },
    21: {  // 4
      switchToDesktop(number: 4)
    },
    23: {  // 5
      switchToDesktop(number: 5)
    },
    25: {  // 6
      switchToDesktop(number: 6)
    },
    26: {  // 7
      switchToDesktop(number: 7)
    },
    28: {  // 8
      switchToDesktop(number: 8)
    },
    29: {  // 9
      switchToDesktop(number: 9)
    },
    31: {  // O
      AccessibilityOverlay.shared.show()
    },
  ]

  func processCharacter(_ keyCode: Int64) -> Bool {
    if let action = rightCommandKeybindings[keyCode] {
      action()

      return true
    }

    return false
  }
}
