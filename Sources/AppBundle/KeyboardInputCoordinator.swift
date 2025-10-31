import Cocoa
import SwiftUI

/// ObservableObject that handles keyboard input for the overlay
class KeyboardInputCoordinator: ObservableObject {
  let elements: [ClickableElement]
  let onElementClick: (ClickableElement) -> Void
  let onDismiss: () -> Void

  @Published var typedPrefix: String = ""

  init(
    elements: [ClickableElement], onElementClick: @escaping (ClickableElement) -> Void,
    onDismiss: @escaping () -> Void
  ) {
    self.elements = elements
    self.onElementClick = onElementClick
    self.onDismiss = onDismiss
  }

  /// Handles keyboard events for typing index numbers
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

    // Check if it's a digit (0-9)
    if let characters = event.characters, let firstChar = characters.first,
      firstChar.isNumber
    {
      let newPrefix = typedPrefix + String(firstChar)

      // Check if any element matches this prefix
      let hasMatch = elements.enumerated().contains { index, _ in
        String(index + 1).hasPrefix(newPrefix)
      }

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

  func getMatchingElements(for prefix: String) -> [(index: Int, element: ClickableElement)] {
    guard !prefix.isEmpty else {
      return elements.enumerated().map { (index: $0.offset + 1, element: $0.element) }
    }

    return elements.enumerated()
      .filter { String($0.offset + 1).hasPrefix(prefix) }
      .map { (index: $0.offset + 1, element: $0.element) }
  }
}
