import Carbon
import CoreGraphics
import Foundation

public struct Keystroke: Sendable {
  public let key: Key
  public let modifiers: Modifiers

  public init(_ key: Key, _ modifiers: Modifiers = []) {
    self.key = key
    self.modifiers = modifiers
  }

  public init(_ char: Character, _ modifiers: Modifiers = []) {
    self.key = .char(char)
    self.modifiers = modifiers
  }

  public enum Key: Sendable, Equatable {
    case char(Character)
    case code(CGKeyCode)
    case `return`
    case tab
    case space
    case delete
    case escape
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    public var keyCode: CGKeyCode? {
      switch self {
      case .char(let c):
        return KeyListener.stringToKeyCode(char: String(c).lowercased())
      case .code(let code):
        return code
      case .return:
        return 36
      case .tab:
        return 48
      case .space:
        return 49
      case .delete:
        return 51
      case .escape:
        return 53
      case .up:
        return 126
      case .down:
        return 125
      case .left:
        return 123
      case .right:
        return 124
      case .home:
        return 115
      case .end:
        return 119
      case .pageUp:
        return 116
      case .pageDown:
        return 121
      case .f1:
        return 122
      case .f2:
        return 120
      case .f3:
        return 99
      case .f4:
        return 118
      case .f5:
        return 96
      case .f6:
        return 97
      case .f7:
        return 98
      case .f8:
        return 100
      case .f9:
        return 101
      case .f10:
        return 109
      case .f11:
        return 103
      case .f12:
        return 111
      }
    }

    public var needsShift: Bool {
      guard case .char(let c) = self else { return false }
      let s = String(c)
      return s != s.lowercased() || Self.shiftedChars.keys.contains(s)
    }

    static let shiftedChars: [String: String] = [
      "!": "1", "@": "2", "#": "3", "$": "4",
      "%": "5", "^": "6", "&": "7", "*": "8",
      "(": "9", ")": "0", "_": "-", "+": "=",
      "{": "[", "}": "]", "|": "\\", ":": ";",
      "\"": "'", "<": ",", ">": ".", "?": "/",
      "~": "`",
    ]
  }

  public struct Modifiers: OptionSet, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
      self.rawValue = rawValue
    }

    public static let ctrl = Modifiers(rawValue: 1 << 0)
    public static let alt = Modifiers(rawValue: 1 << 1)
    public static let shift = Modifiers(rawValue: 1 << 2)
    public static let cmd = Modifiers(rawValue: 1 << 3)

    public var cgEventFlags: CGEventFlags {
      var flags = CGEventFlags()
      if contains(.ctrl) { flags.insert(.maskControl) }
      if contains(.alt) { flags.insert(.maskAlternate) }
      if contains(.shift) { flags.insert(.maskShift) }
      if contains(.cmd) { flags.insert(.maskCommand) }
      return flags
    }
  }
}

public func ctrl(_ key: Keystroke.Key) -> Keystroke {
  Keystroke(key, .ctrl)
}

public func alt(_ key: Keystroke.Key) -> Keystroke {
  Keystroke(key, .alt)
}

public func shift(_ key: Keystroke.Key) -> Keystroke {
  Keystroke(key, .shift)
}

public func cmd(_ key: Keystroke.Key) -> Keystroke {
  Keystroke(key, .cmd)
}

public func key(_ char: Character) -> Keystroke {
  Keystroke(.char(char))
}

public func key(_ key: Keystroke.Key) -> Keystroke {
  Keystroke(key)
}

public struct KeySequence: Sendable {
  public let items: [Item]

  public init(_ items: [Item]) {
    self.items = items
  }

  public init(_ items: Item...) {
    self.items = items
  }

  public enum Item: Sendable {
    case stroke(Keystroke)
    case text(String)
    case wait(Double)

    public static func key(_ key: Keystroke.Key, _ modifiers: Keystroke.Modifiers = []) -> Item {
      .stroke(Keystroke(key, modifiers))
    }

    public static func char(_ c: Character) -> Item {
      .stroke(Keystroke(.char(c)))
    }
  }
}

public struct KeyEmitter {
  public enum EmitError: Error, CustomStringConvertible {
    case noEventSource
    case invalidKeyCode(Keystroke.Key)
    case eventCreationFailed

    public var description: String {
      switch self {
      case .noEventSource:
        return "Failed to create event source"
      case .invalidKeyCode(let key):
        return "Invalid key code for: \(key)"
      case .eventCreationFailed:
        return "Failed to create key event"
      }
    }
  }

  public static func emit(_ keystroke: Keystroke) throws {
    guard let source = CGEventSource(stateID: .hidSystemState) else {
      throw EmitError.noEventSource
    }

    guard let keyCode = keystroke.key.keyCode else {
      throw EmitError.invalidKeyCode(keystroke.key)
    }

    var flags = keystroke.modifiers.cgEventFlags
    if keystroke.key.needsShift {
      flags.insert(.maskShift)
    }

    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
      throw EmitError.eventCreationFailed
    }

    keyDown.flags = flags
    keyUp.flags = flags

    keyDown.post(tap: .cghidEventTap)
    usleep(20000)
    keyUp.post(tap: .cghidEventTap)
  }

  public static func emit(_ sequence: KeySequence, delay: Double = 0.05) throws {
    for (index, item) in sequence.items.enumerated() {
      switch item {
      case .stroke(let keystroke):
        try emit(keystroke)
      case .text(let text):
        for char in text {
          try emit(Keystroke(.char(char)))
        }
      case .wait(let seconds):
        usleep(UInt32(seconds * 1_000_000))
        continue
      }
      if index < sequence.items.count - 1 {
        usleep(UInt32(delay * 1_000_000))
      }
    }
  }

  public static func emit(_ items: [KeySequence.Item], delay: Double = 0.05) throws {
    try emit(KeySequence(items), delay: delay)
  }
}

public enum KeystrokeParser {
  public enum ParseError: Error, CustomStringConvertible {
    case invalidChord(String)
    case unknownKey(String)
    case emptyInput

    public var description: String {
      switch self {
      case .invalidChord(let chord):
        return "Invalid chord: \(chord)"
      case .unknownKey(let key):
        return "Unknown key: \(key)"
      case .emptyInput:
        return "Empty input"
      }
    }
  }

  private static let specialKeyMap: [String: Keystroke.Key] = [
    "return": .return, "enter": .return, "ret": .return, "cr": .return,
    "tab": .tab,
    "space": .space, "spc": .space,
    "delete": .delete, "backspace": .delete, "bs": .delete,
    "escape": .escape, "esc": .escape,
    "up": .up,
    "down": .down,
    "left": .left,
    "right": .right,
    "home": .home,
    "end": .end,
    "pageup": .pageUp, "pgup": .pageUp,
    "pagedown": .pageDown, "pgdn": .pageDown,
    "f1": .f1, "f2": .f2, "f3": .f3, "f4": .f4,
    "f5": .f5, "f6": .f6, "f7": .f7, "f8": .f8,
    "f9": .f9, "f10": .f10, "f11": .f11, "f12": .f12,
  ]

  private static let modifierMap: [String: Keystroke.Modifiers] = [
    "ctrl": .ctrl, "control": .ctrl, "c": .ctrl,
    "alt": .alt, "option": .alt, "opt": .alt, "m": .alt,
    "shift": .shift, "s": .shift,
    "cmd": .cmd, "command": .cmd, "super": .cmd, "win": .cmd,
  ]

  public static func parse(_ input: String) throws -> KeySequence.Item {
    guard !input.isEmpty else {
      throw ParseError.emptyInput
    }

    if input.hasPrefix("<") && input.hasSuffix(">") {
      return try parseChord(String(input.dropFirst().dropLast()))
    } else {
      return .text(input)
    }
  }

  public static func parseMultiple(_ inputs: [String]) throws -> [KeySequence.Item] {
    try inputs.map { try parse($0) }
  }

  private static func parseChord(_ chord: String) throws -> KeySequence.Item {
    guard !chord.isEmpty else {
      throw ParseError.invalidChord("<>")
    }

    // Check for wait/delay: <0.5> or <1.0> etc.
    if let seconds = Double(chord) {
      return .wait(seconds)
    }

    let parts = chord.lowercased().split { $0 == "-" || $0 == "+" }.map(String.init)
    guard !parts.isEmpty else {
      throw ParseError.invalidChord("<\(chord)>")
    }

    var modifiers = Keystroke.Modifiers()
    let keyPart = parts.last!
    let modifierParts = parts.dropLast()

    for mod in modifierParts {
      if let flag = modifierMap[mod] {
        modifiers.insert(flag)
      } else {
        throw ParseError.invalidChord("<\(chord)> - unknown modifier '\(mod)'")
      }
    }

    let key: Keystroke.Key
    if let special = specialKeyMap[keyPart] {
      key = special
    } else if keyPart.count == 1, let char = keyPart.first {
      key = .char(char)
    } else {
      throw ParseError.unknownKey(keyPart)
    }

    return .stroke(Keystroke(key, modifiers))
  }
}
