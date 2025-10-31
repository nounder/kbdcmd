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
    case delete = 51  // Backspace
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

// MARK: - Sequence Support

struct KeyPress {
  let key: Key
  let flags: CGEventFlags

  init(key: Key, flags: CGEventFlags = CGEventFlags(rawValue: 0)) {
    self.key = key
    self.flags = flags
  }
}

private struct KeyInSequence: Hashable {
  let key: Key
  let flags: UInt64

  init(_ press: KeyPress, modifierMask: UInt64) {
    switch press.key {
    case .character(let char):
      self.key = .character(Character(String(char).uppercased()))
    case .named:
      self.key = press.key
    }
    self.flags = press.flags.rawValue & modifierMask
  }
}

private class SequenceNode {
  var action: (([KeyPress]) -> Void)?
  var sequence: [KeyPress]?
  var children: [KeyInSequence: SequenceNode] = [:]
}

// MARK: - Keybindings Class

class Keybindings {
  static let shared = Keybindings()

  // Unified storage: trie structure for all keybindings (single-key and sequences)
  private var sequenceRoot = SequenceNode()

  // Modifier mask for extracting only relevant flags
  private let modifierMask: UInt64 = {
    CGEventFlags.maskControlLeft.rawValue | CGEventFlags.maskControlRight.rawValue
      | CGEventFlags.maskOptionLeft.rawValue | CGEventFlags.maskOptionRight.rawValue
      | CGEventFlags.maskCmdLeft.rawValue | CGEventFlags.maskCmdRight.rawValue
      | CGEventFlags.maskAlphaShift.rawValue
  }()

  init() {
    // Register default keybindings
    registerDefaultKeybindings()
  }

  // MARK: - Registration

  func register<S: Sequence>(_ sequence: S, action: @escaping ([KeyPress]) -> Void)
  where S.Element == KeyPress {

    let seq = Array(sequence)
    guard !seq.isEmpty else { return }

    let firstMasked = seq[0].flags.rawValue & modifierMask
    let firstHasModifiers = firstMasked != 0

    if firstHasModifiers {
      for i in 1..<seq.count {
        let masked = seq[i].flags.rawValue & modifierMask
        guard masked == 0 else {
          print("ERROR: Only first key in sequence can have modifiers")
          return
        }
      }
    }

    let expandedSequences = expandEitherInSequence(seq)

    for expanded in expandedSequences {
      var node = sequenceRoot
      for press in expanded {
        let element = KeyInSequence(press, modifierMask: modifierMask)
        if node.children[element] == nil {
          node.children[element] = SequenceNode()
        }
        node = node.children[element]!
      }
      node.sequence = expanded
      node.action = action
    }
  }

  // MARK: - Lookup

  enum SequenceMatch {
    case complete(action: ([KeyPress]) -> Void, sequence: [KeyPress])
    case partial
    case noMatch
  }

  func matchSequence<S: Sequence>(_ buffer: S) -> SequenceMatch
  where S.Element == KeyPress {

    var node = sequenceRoot
    var hasElements = false

    for press in buffer {
      hasElements = true
      let element = KeyInSequence(press, modifierMask: modifierMask)
      guard let nextNode = node.children[element] else {
        return .noMatch
      }
      node = nextNode
    }

    guard hasElements else { return .noMatch }

    if let action = node.action, let sequence = node.sequence {
      return .complete(action: action, sequence: sequence)
    }

    return node.children.isEmpty ? .noMatch : .partial
  }

  // MARK: - Helpers

  private func expandEitherInSequence(_ sequence: [KeyPress]) -> [[KeyPress]] {
    var hasEither = false
    for press in sequence {
      if hasEitherModifier(press.flags) {
        hasEither = true
        break
      }
    }

    if !hasEither {
      return [sequence]
    }

    var results: [[KeyPress]] = [[]]

    for press in sequence {
      if hasEitherModifier(press.flags) {
        let expansions = expandEitherFlags(press.flags)
        results = results.flatMap { partial in
          expansions.map { expandedFlags in
            partial + [KeyPress(key: press.key, flags: expandedFlags)]
          }
        }
      } else {
        results = results.map { $0 + [press] }
      }
    }

    return results
  }

  private func hasEitherModifier(_ flags: CGEventFlags) -> Bool {
    // Check if BOTH left and right variants are set (indicates .either)
    let hasControlBoth = flags.contains(.maskControlLeft) && flags.contains(.maskControlRight)
    let hasOptionBoth = flags.contains(.maskOptionLeft) && flags.contains(.maskOptionRight)
    let hasCmdBoth = flags.contains(.maskCmdLeft) && flags.contains(.maskCmdRight)

    return hasControlBoth || hasOptionBoth || hasCmdBoth
  }

  private func expandEitherFlags(_ flags: CGEventFlags) -> [CGEventFlags] {
    var results: [CGEventFlags] = [CGEventFlags(rawValue: 0)]

    // Handle control either
    if flags.contains(.maskControlLeft) && flags.contains(.maskControlRight) {
      results = results.flatMap { base in
        [
          CGEventFlags(rawValue: base.rawValue | CGEventFlags.maskControlLeft.rawValue),
          CGEventFlags(rawValue: base.rawValue | CGEventFlags.maskControlRight.rawValue),
        ]
      }
    } else if flags.contains(.maskControlLeft) {
      results = results.map {
        CGEventFlags(rawValue: $0.rawValue | CGEventFlags.maskControlLeft.rawValue)
      }
    } else if flags.contains(.maskControlRight) {
      results = results.map {
        CGEventFlags(rawValue: $0.rawValue | CGEventFlags.maskControlRight.rawValue)
      }
    }

    // Handle option either
    if flags.contains(.maskOptionLeft) && flags.contains(.maskOptionRight) {
      results = results.flatMap { base in
        [
          CGEventFlags(rawValue: base.rawValue | CGEventFlags.maskOptionLeft.rawValue),
          CGEventFlags(rawValue: base.rawValue | CGEventFlags.maskOptionRight.rawValue),
        ]
      }
    } else if flags.contains(.maskOptionLeft) {
      results = results.map {
        CGEventFlags(rawValue: $0.rawValue | CGEventFlags.maskOptionLeft.rawValue)
      }
    } else if flags.contains(.maskOptionRight) {
      results = results.map {
        CGEventFlags(rawValue: $0.rawValue | CGEventFlags.maskOptionRight.rawValue)
      }
    }

    // Handle command either
    if flags.contains(.maskCmdLeft) && flags.contains(.maskCmdRight) {
      results = results.flatMap { base in
        [
          CGEventFlags(rawValue: base.rawValue | CGEventFlags.maskCmdLeft.rawValue),
          CGEventFlags(rawValue: base.rawValue | CGEventFlags.maskCmdRight.rawValue),
        ]
      }
    } else if flags.contains(.maskCmdLeft) {
      results = results.map {
        CGEventFlags(rawValue: $0.rawValue | CGEventFlags.maskCmdLeft.rawValue)
      }
    } else if flags.contains(.maskCmdRight) {
      results = results.map {
        CGEventFlags(rawValue: $0.rawValue | CGEventFlags.maskCmdRight.rawValue)
      }
    }

    // Handle capsLock
    if flags.contains(.maskAlphaShift) {
      results = results.map {
        CGEventFlags(rawValue: $0.rawValue | CGEventFlags.maskAlphaShift.rawValue)
      }
    }

    return results
  }

  // MARK: - Default Keybindings

  private func registerDefaultKeybindings() {
    // Right Command + Letter keybindings (single-key sequences)
    register([KeyPress(key: .character("L"), flags: .maskCmdRight)]) { _ in
      cycleAppWindows()
    }

    register([KeyPress(key: .character("D"), flags: .maskCmdRight)]) { _ in
      cmdOpenCycle("/Applications/Ghostty.app")
    }

    register([KeyPress(key: .character("S"), flags: .maskCmdRight)]) { _ in
      cmdOpenCycle("/Applications/Safari.app")
    }

    register([KeyPress(key: .character("O"), flags: .maskAlphaShift)]) { _ in
      AccessibilityOverlay.shared.show()
    }

    register([KeyPress(key: .character("V"), flags: .maskCmdRight)]) { _ in
      cmdOpenCycle("/Applications/Cursor.app")
    }

    register([KeyPress(key: .character("B"), flags: .maskCmdRight)]) { _ in
      cmdOpenCycle("/Applications/Spotify.app")
    }

    register([KeyPress(key: .character("C"), flags: .maskCmdRight)]) { _ in
      cmdOpenCycle("/System/Applications/Calendar.app")
    }

    register([KeyPress(key: .character("G"), flags: .maskCmdRight)]) { _ in
      cmdOpenCycle("/Applications/ChatGPT.app")
    }

    register([KeyPress(key: .character("H"), flags: .maskCmdRight)]) { _ in
      cmdOpenCycle("/Users/rg/Applications/Claude.app")
    }

    register([KeyPress(key: .character("J"), flags: .maskCmdRight)]) { _ in
      cmdOpenCycle("/Users/rg/Applications/Perplexity.app")
    }

    register([KeyPress(key: .character("M"), flags: .maskCmdRight)]) { _ in
      cmdOpenCycle("/System/Applications/Mail.app")
    }

    register([KeyPress(key: .character("Z"), flags: .maskCmdRight)]) { _ in
      cmdOpenCycle("/Applications/Google Chrome Canary.app")
    }

    // Right Command + Number keybindings (desktop switching)
    register([KeyPress(key: .character("1"), flags: .maskCmdRight)]) { _ in
      switchToDesktop(number: 1)
    }

    register([KeyPress(key: .character("2"), flags: .maskCmdRight)]) { _ in
      switchToDesktop(number: 2)
    }

    register([KeyPress(key: .character("3"), flags: .maskCmdRight)]) { _ in
      switchToDesktop(number: 3)
    }

    register([KeyPress(key: .character("4"), flags: .maskCmdRight)]) { _ in
      switchToDesktop(number: 4)
    }

    register([KeyPress(key: .character("5"), flags: .maskCmdRight)]) { _ in
      switchToDesktop(number: 5)
    }

    register([KeyPress(key: .character("6"), flags: .maskCmdRight)]) { _ in
      switchToDesktop(number: 6)
    }

    register([KeyPress(key: .character("7"), flags: .maskCmdRight)]) { _ in
      switchToDesktop(number: 7)
    }

    register([KeyPress(key: .character("8"), flags: .maskCmdRight)]) { _ in
      switchToDesktop(number: 8)
    }

    register([KeyPress(key: .character("9"), flags: .maskCmdRight)]) { _ in
      switchToDesktop(number: 9)
    }

    // Character-only sequences (replacing snippet manager)
    let seqTdf = [
      KeyPress(key: .character("t")),
      KeyPress(key: .character("d")),
      KeyPress(key: .character("f")),
    ]
    register(seqTdf) { seq in
      let df = DateFormatter()
      df.dateFormat = "yyyy-MM-dd"
      let dateString = df.string(from: Date())
      Snippets.expandSnippet(for: seq, insert: dateString)
    }

    let seqTds = [
      KeyPress(key: .character("t")),
      KeyPress(key: .character("d")),
      KeyPress(key: .character("s")),
    ]
    register(seqTds) { seq in
      let df = DateFormatter()
      df.dateFormat = "yyMMdd"
      let dateString = df.string(from: Date())
      Snippets.expandSnippet(for: seq, insert: dateString)
    }
  }
}
