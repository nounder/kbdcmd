import Carbon
import Cocoa

// MARK: - Key Enum (Union type: Character or SpecialKey)

enum Key: Hashable {
  case character(Character)
  case named(Named)
  
  enum Named: Int64, CaseIterable {
    case escape = 53
    case tab = 48
    case `return` = 36
    case delete = 51          // Backspace
    case forwardDelete = 117
    case space = 49
    case leftArrow = 123
    case rightArrow = 124
    case downArrow = 125
    case upArrow = 126
    case home = 115
    case end = 119
    case pageUp = 116
    case pageDown = 121
    case f1 = 122
    case f2 = 120
    case f3 = 99
    case f4 = 118
    case f5 = 96
    case f6 = 97
    case f7 = 98
    case f8 = 100
    case f9 = 101
    case f10 = 109
    case f11 = 103
    case f12 = 111
  }
}

// MARK: - Modifier Enum

enum Modifier: Hashable {
  case control(Side)
  case option(Side)
  case command(Side)
  case capsLock
  
  enum Side: Hashable {
    case left
    case right
    case either
  }
}

// MARK: - Keybindings Class

class Keybindings {
  static let shared = Keybindings()
  
  // Map: (CGEventFlags.rawValue) → (Key → Action)
  private var bindingsByFlagsAndKey: [UInt64: [Key: () -> Void]] = [:]
  
  // Modifier mask for extracting only relevant flags
  private let modifierMask: UInt64 = {
    CGEventFlags.maskControlLeft.rawValue |
    CGEventFlags.maskControlRight.rawValue |
    CGEventFlags.maskOptionLeft.rawValue |
    CGEventFlags.maskOptionRight.rawValue |
    CGEventFlags.maskCmdLeft.rawValue |
    CGEventFlags.maskCmdRight.rawValue |
    CGEventFlags.maskAlphaShift.rawValue
  }()
  
  init() {
    // Register default keybindings
    registerDefaultKeybindings()
  }
  
  // MARK: - Registration
  
  func register(_ key: Key, modifiers: Modifier..., action: @escaping () -> Void) {
    // Normalize character keys to uppercase
    let normalizedKey: Key
    switch key {
    case .character(let char):
      normalizedKey = .character(Character(String(char).uppercased()))
    case .named:
      normalizedKey = key
    }
    
    let modifiersList = Array(modifiers)
    
    // Check if any .either modifiers exist
    let hasEither = modifiersList.contains {
      if case .control(.either) = $0 { return true }
      if case .option(.either) = $0 { return true }
      if case .command(.either) = $0 { return true }
      return false
    }
    
    if hasEither {
      // Expand .either into multiple registrations
      let flagCombinations = expandEitherModifiers(modifiersList)
      for flags in flagCombinations {
        if bindingsByFlagsAndKey[flags] == nil {
          bindingsByFlagsAndKey[flags] = [:]
        }
        bindingsByFlagsAndKey[flags]?[normalizedKey] = action
      }
    } else {
      // Single registration (common case)
      let flags = computeFlagsRawValue(from: modifiersList)
      if bindingsByFlagsAndKey[flags] == nil {
        bindingsByFlagsAndKey[flags] = [:]
      }
      bindingsByFlagsAndKey[flags]?[normalizedKey] = action
    }
  }
  
  // MARK: - Lookup
  
  func processKey(_ key: Key, flags: CGEventFlags) -> Bool {
    let maskedFlags = maskRelevantFlags(flags.rawValue)
    
    if let keyBindings = bindingsByFlagsAndKey[maskedFlags],
       let action = keyBindings[key] {
      action()
      return true
    }
    
    return false
  }
  
  // MARK: - Helpers
  
  private func maskRelevantFlags(_ rawValue: UInt64) -> UInt64 {
    return rawValue & modifierMask
  }
  
  private func computeFlagsRawValue(from modifiers: [Modifier]) -> UInt64 {
    var flags: UInt64 = 0
    
    for mod in modifiers {
      switch mod {
      case .control(.left):
        flags |= CGEventFlags.maskControlLeft.rawValue
      case .control(.right):
        flags |= CGEventFlags.maskControlRight.rawValue
      case .option(.left):
        flags |= CGEventFlags.maskOptionLeft.rawValue
      case .option(.right):
        flags |= CGEventFlags.maskOptionRight.rawValue
      case .command(.left):
        flags |= CGEventFlags.maskCmdLeft.rawValue
      case .command(.right):
        flags |= CGEventFlags.maskCmdRight.rawValue
      case .capsLock:
        flags |= CGEventFlags.maskAlphaShift.rawValue
      case .control(.either), .option(.either), .command(.either):
        // Handled by expandEitherModifiers
        break
      }
    }
    
    return flags
  }
  
  private func expandEitherModifiers(_ modifiers: [Modifier]) -> [UInt64] {
    var results: [UInt64] = [0]
    
    for mod in modifiers {
      switch mod {
      case .control(.either):
        // Duplicate all existing results: one with left, one with right
        results = results.flatMap { base in
          [
            base | CGEventFlags.maskControlLeft.rawValue,
            base | CGEventFlags.maskControlRight.rawValue
          ]
        }
      case .option(.either):
        results = results.flatMap { base in
          [
            base | CGEventFlags.maskOptionLeft.rawValue,
            base | CGEventFlags.maskOptionRight.rawValue
          ]
        }
      case .command(.either):
        results = results.flatMap { base in
          [
            base | CGEventFlags.maskCmdLeft.rawValue,
            base | CGEventFlags.maskCmdRight.rawValue
          ]
        }
      default:
        // Add concrete modifier to all results
        let flagValue = getSingleFlagValue(mod)
        results = results.map { $0 | flagValue }
      }
    }
    
    return results
  }
  
  private func getSingleFlagValue(_ modifier: Modifier) -> UInt64 {
    switch modifier {
    case .control(.left):
      return CGEventFlags.maskControlLeft.rawValue
    case .control(.right):
      return CGEventFlags.maskControlRight.rawValue
    case .option(.left):
      return CGEventFlags.maskOptionLeft.rawValue
    case .option(.right):
      return CGEventFlags.maskOptionRight.rawValue
    case .command(.left):
      return CGEventFlags.maskCmdLeft.rawValue
    case .command(.right):
      return CGEventFlags.maskCmdRight.rawValue
    case .capsLock:
      return CGEventFlags.maskAlphaShift.rawValue
    case .control(.either), .option(.either), .command(.either):
      return 0
    }
  }
  
  // MARK: - Default Keybindings
  
  private func registerDefaultKeybindings() {
    // Right Command + Letter keybindings
    register(.character("L"), modifiers: .command(.right)) {
      cycleAppWindows()
    }
    
    register(.character("D"), modifiers: .command(.right)) {
      cmdOpenCycle("/Applications/Ghostty.app")
    }
    
    register(.character("S"), modifiers: .command(.right)) {
      cmdOpenCycle("/Applications/Safari.app")
    }
    
    register(.character("F"), modifiers: .command(.right)) {
      AccessibilityOverlay.shared.show()
    }
    
    register(.character("V"), modifiers: .command(.right)) {
      cmdOpenCycle("/Applications/Cursor.app")
    }
    
    register(.character("B"), modifiers: .command(.right)) {
      cmdOpenCycle("/Applications/Spotify.app")
    }
    
    register(.character("C"), modifiers: .command(.right)) {
      cmdOpenCycle("/System/Applications/Calendar.app")
    }
    
    register(.character("G"), modifiers: .command(.right)) {
      cmdOpenCycle("/Applications/ChatGPT.app")
    }
    
    register(.character("H"), modifiers: .command(.right)) {
      cmdOpenCycle("/Users/rg/Applications/Claude.app")
    }
    
    register(.character("J"), modifiers: .command(.right)) {
      cmdOpenCycle("/Users/rg/Applications/Perplexity.app")
    }
    
    register(.character("M"), modifiers: .command(.right)) {
      cmdOpenCycle("/System/Applications/Mail.app")
    }
    
    register(.character("Z"), modifiers: .command(.right)) {
      cmdOpenCycle("/Applications/Google Chrome Canary.app")
    }
    
    // Right Command + Number keybindings (desktop switching)
    register(.character("1"), modifiers: .command(.right)) {
      switchToDesktop(number: 1)
    }
    
    register(.character("2"), modifiers: .command(.right)) {
      switchToDesktop(number: 2)
    }
    
    register(.character("3"), modifiers: .command(.right)) {
      switchToDesktop(number: 3)
    }
    
    register(.character("4"), modifiers: .command(.right)) {
      switchToDesktop(number: 4)
    }
    
    register(.character("5"), modifiers: .command(.right)) {
      switchToDesktop(number: 5)
    }
    
    register(.character("6"), modifiers: .command(.right)) {
      switchToDesktop(number: 6)
    }
    
    register(.character("7"), modifiers: .command(.right)) {
      switchToDesktop(number: 7)
    }
    
    register(.character("8"), modifiers: .command(.right)) {
      switchToDesktop(number: 8)
    }
    
    register(.character("9"), modifiers: .command(.right)) {
      switchToDesktop(number: 9)
    }
  }
}
