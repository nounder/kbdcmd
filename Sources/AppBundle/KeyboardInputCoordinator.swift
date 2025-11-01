import Cocoa
import SwiftUI

/// ObservableObject that handles keyboard input for the overlay
class KeyboardInputCoordinator: ObservableObject {
  let elements: [ClickableElement]
  let onElementClick: (ClickableElement) -> Void
  let onDismiss: () -> Void
  let hints: [String]
  let hintToElement: [String: (index: Int, element: ClickableElement)]

  @Published var typedPrefix: String = ""

  init(
    elements: [ClickableElement], onElementClick: @escaping (ClickableElement) -> Void,
    onDismiss: @escaping () -> Void
  ) {
    self.elements = elements
    self.onElementClick = onElementClick
    self.onDismiss = onDismiss
    
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
      // Convert indices to hint string
      let hint = indices.map { String(chars[$0]) }.joined()
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

  /// Handles keyboard events for typing hint characters
  func handleKeyEvent(_ event: NSEvent) -> Bool {
    // ESC key dismisses overlay
    if event.keyCode == 53 {  // ESC key
      typedPrefix = ""
      onDismiss()
      return true
    }

    // Backspace/Delete clears prefix
    if event.keyCode == 51 || event.keyCode == 117 {  // Backspace or Delete
      if !typedPrefix.isEmpty {
        typedPrefix = String(typedPrefix.dropLast())
      }
      return true
    }

    // Check if it's a valid hint character
    if let characters = event.characters?.lowercased(), let firstChar = characters.first,
      Self.hintCharacters.contains(firstChar)
    {
      let newPrefix = typedPrefix + String(firstChar)

      // Check if any hint matches this prefix
      let hasMatch = hints.contains { $0.hasPrefix(newPrefix) }

      if hasMatch {
        typedPrefix = newPrefix

        // Check if exactly one match after updating prefix
        let matchingElements = getMatchingElements(for: typedPrefix)

        // Auto-click if exactly one match
        if matchingElements.count == 1, let match = matchingElements.first {
          // Use a small delay to allow visual feedback
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.onElementClick(match.element)
          }
        }

        return true
      }
    }

    return false
  }

  func getMatchingElements(for prefix: String) -> [(index: Int, element: ClickableElement, hint: String)] {
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
