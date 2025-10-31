import Carbon
import Cocoa

class Keybindings {
  static let shared = Keybindings()

  private func keyCode(for char: Character) -> Int64 {
    let string = String(char).lowercased()
    guard let unicodeScalar = string.unicodeScalars.first else { return -1 }
    
    var deadKeyState: UInt32 = 0
    var length = 0
    var chars = [UniChar](repeating: 0, count: 4)
    
    let inputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    guard let layoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
      return -1
    }
    
    let keyboardLayout = unsafeBitCast(CFDataGetBytePtr(unsafeBitCast(layoutData, to: CFData.self)), to: UnsafePointer<UCKeyboardLayout>.self)
    
    for keyCode in 0..<128 {
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
        let resultString = String(utf16CodeUnits: chars, count: length).lowercased()
        if resultString == string {
          return Int64(keyCode)
        }
      }
    }
    
    return -1
  }

  private lazy var rightCommandKeybindings: [Int64: () -> Void] = [
    keyCode(for: "L"): {
      cycleAppWindows()
    },
    keyCode(for: "D"): {
      // cmdOpenCycle("/Applications/kitty.app")
      cmdOpenCycle("/Applications/Ghostty.app")
    },
    keyCode(for: "S"): {
      cmdOpenCycle("/Applications/Safari.app")
    },
    keyCode(for: "F"): {
      AccessibilityOverlay.shared.show()
    },
    keyCode(for: "V"): {
      cmdOpenCycle("/Applications/Cursor.app")
    },
    keyCode(for: "B"): {
      cmdOpenCycle("/Applications/Spotify.app")
    },
    keyCode(for: "C"): {
      cmdOpenCycle("/System/Applications/Calendar.app")
    },
    keyCode(for: "G"): {
      cmdOpenCycle("/Applications/ChatGPT.app")
    },
    keyCode(for: "H"): {
      cmdOpenCycle("/Users/rg/Applications/Claude.app")
    },
    keyCode(for: "J"): {
      cmdOpenCycle("/Users/rg/Applications/Perplexity.app")
    },
    keyCode(for: "M"): {
      cmdOpenCycle("/System/Applications/Mail.app")
    },
    keyCode(for: "1"): {
      switchToDesktop(number: 1)
    },
    keyCode(for: "2"): {
      switchToDesktop(number: 2)
    },
    keyCode(for: "3"): {
      switchToDesktop(number: 3)
    },
    keyCode(for: "4"): {
      switchToDesktop(number: 4)
    },
    keyCode(for: "5"): {
      switchToDesktop(number: 5)
    },
    keyCode(for: "6"): {
      switchToDesktop(number: 6)
    },
    keyCode(for: "7"): {
      switchToDesktop(number: 7)
    },
    keyCode(for: "8"): {
      switchToDesktop(number: 8)
    },
    keyCode(for: "9"): {
      switchToDesktop(number: 9)
    },
    keyCode(for: "Z"): {
      cmdOpenCycle("/Applications/Google Chrome Canary.app")
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
