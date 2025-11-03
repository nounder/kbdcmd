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
  var consume: Bool = false  // By default, don't consume the event (let it pass through)
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
  }

  // MARK: - Registration

  func register<S: Sequence>(
    _ sequence: S, consume: Bool = true, action: @escaping ([KeyPress]) -> Void
  )
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
      node.consume = consume
    }
  }

  // MARK: - Lookup

  enum SequenceMatch {
    case complete(action: ([KeyPress]) -> Void, sequence: [KeyPress], consume: Bool)
    case partial
    case noMatch
  }

  func matchSequence<S: Sequence>(_ buffer: S) -> SequenceMatch
  where S.Element == KeyPress {

    let bufferArray = Array(buffer)
    guard !bufferArray.isEmpty else { return .noMatch }

    // Find all matching paths where registered modifiers are subset of pressed modifiers
    var candidates:
      [(action: ([KeyPress]) -> Void, sequence: [KeyPress], flags: UInt64, consume: Bool)] = []
    var hasPartialMatch = false

    findMatches(
      at: sequenceRoot,
      buffer: bufferArray,
      index: 0,
      candidates: &candidates,
      hasPartialMatch: &hasPartialMatch
    )

    // If we found complete matches, return the most specific one
    if !candidates.isEmpty {
      let bestMatch = candidates.max { a, b in
        isMoreSpecific(b.flags, than: a.flags)
      }!
      return .complete(
        action: bestMatch.action, sequence: bestMatch.sequence, consume: bestMatch.consume)
    }

    return hasPartialMatch ? .partial : .noMatch
  }

  private func findMatches(
    at node: SequenceNode,
    buffer: [KeyPress],
    index: Int,
    candidates: inout [(
      action: ([KeyPress]) -> Void, sequence: [KeyPress], flags: UInt64, consume: Bool
    )],
    hasPartialMatch: inout Bool
  ) {
    // Base case: we've matched all keys in the buffer
    if index >= buffer.count {
      if let action = node.action, let sequence = node.sequence {
        // Extract flags from first key press (only first key can have modifiers)
        let flags = sequence.first?.flags.rawValue ?? 0
        candidates.append((action: action, sequence: sequence, flags: flags, consume: node.consume))
      }
      if !node.children.isEmpty {
        hasPartialMatch = true
      }
      return
    }

    let press = buffer[index]
    let pressedElement = KeyInSequence(press, modifierMask: modifierMask)

    // Check all children where registered flags are a subset of pressed flags
    for (childKey, childNode) in node.children {
      // Keys must match
      guard childKey.key == pressedElement.key else { continue }

      // Registered flags must be a subset of pressed flags
      // (registeredFlags & pressedFlags) == registeredFlags
      if (childKey.flags & pressedElement.flags) == childKey.flags {
        findMatches(
          at: childNode,
          buffer: buffer,
          index: index + 1,
          candidates: &candidates,
          hasPartialMatch: &hasPartialMatch
        )
      }
    }
  }

  private func isMoreSpecific(_ a: UInt64, than b: UInt64) -> Bool {
    // If A contains all of B's flags AND has additional flags, A is more specific
    if (a & b) == b && a != b {
      return true
    }
    // If B contains all of A's flags AND has additional flags, B is more specific (A is not)
    if (b & a) == a && b != a {
      return false
    }
    // Neither is a subset of the other - use raw value as tiebreaker
    return a > b
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

}
