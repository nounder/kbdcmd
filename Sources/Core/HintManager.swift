import Foundation

/// Manages hint generation and prefix matching for clickable elements
class HintManager: ObservableObject {
  let elements: [ClickableElement]
  let hints: [String]
  let hintToElement: [String: (index: Int, element: ClickableElement)]

  @Published var typedPrefix: String = ""

  init(elements: [ClickableElement]) {
    self.elements = elements

    // Generate hints of consistent length
    self.hints = Self.generateHints(count: elements.count)

    // Create mapping from hint to element
    var mapping: [String: (index: Int, element: ClickableElement)] = [:]
    for (index, element) in elements.enumerated() {
      if index < hints.count {
        mapping[hints[index]] = (index: index, element: element)
      }
    }
    self.hintToElement = mapping
  }

  /// Characters to use for hints (excluding similar-looking ones: i, l, o, 0, 1)
  private static let hintCharacters = Array("asdfghjkwertyupzxcvbnmq")

  /// Generates hint labels of consistent length for the given number of elements
  private static func generateHints(count: Int) -> [String] {
    guard count > 0 else { return [] }

    let chars = hintCharacters
    let base = chars.count

    // Calculate required length: ceil(log_base(count))
    let length = count == 1 ? 1 : Int(ceil(log(Double(count)) / log(Double(base))))

    // Generate hints lexicographically
    var hints: [String] = []
    var indices = Array(repeating: 0, count: length)

    for _ in 0..<count {
      // Convert indices to hint string (uppercase)
      let hint = indices.map { String(chars[$0]) }.joined().uppercased()
      hints.append(hint)

      // Increment indices (like counting in base-N)
      var carry = 1
      for i in (0..<length).reversed() {
        if carry == 0 { break }
        indices[i] += carry
        if indices[i] >= base {
          indices[i] = 0
          carry = 1
        } else {
          carry = 0
        }
      }
    }

    return hints
  }

  /// Returns hint characters used for validation
  static var hintCharactersSet: Set<Character> {
    return Set(hintCharacters)
  }

  /// Updates the typed prefix with a new character
  /// Returns true if the character was accepted (forms a valid prefix)
  func appendCharacter(_ char: Character) -> Bool {
    let newPrefix = typedPrefix + String(char).uppercased()

    // Check if any hint matches this prefix
    let hasMatch = hints.contains { $0.hasPrefix(newPrefix) }

    if hasMatch {
      typedPrefix = newPrefix
      return true
    }

    return false
  }

  /// Removes the last character from the typed prefix
  func removeLastCharacter() {
    if !typedPrefix.isEmpty {
      typedPrefix = String(typedPrefix.dropLast())
    }
  }

  /// Clears the typed prefix
  func clearPrefix() {
    typedPrefix = ""
  }

  func getMatchingElements(for prefix: String) -> [(
    index: Int, element: ClickableElement, hint: String
  )] {
    guard !prefix.isEmpty else {
      return hints.enumerated().compactMap { offset, hint in
        guard let mapped = hintToElement[hint] else { return nil }
        return (index: mapped.index, element: mapped.element, hint: hint)
      }
    }

    return hints.enumerated().compactMap { offset, hint in
      guard hint.hasPrefix(prefix), let mapped = hintToElement[hint] else { return nil }
      return (index: mapped.index, element: mapped.element, hint: hint)
    }
  }

  /// Returns the hint for a given element index
  func getHint(forIndex index: Int) -> String? {
    return index < hints.count ? hints[index] : nil
  }
}
