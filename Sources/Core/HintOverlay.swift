import Cocoa
import SwiftUI

// MARK: - Hint Overlay Views and Components

/// Loading indicator shown while scanning for elements
struct LoadingOverlayView: View {
  let onDismiss: () -> Void

  var body: some View {
    ZStack {
      // Dismissable background
      Color.black.opacity(0.3)
        .onTapGesture {
          onDismiss()
        }

      // Loading indicator
      VStack(spacing: 12) {
        ProgressView()
          .scaleEffect(1.5)
          .progressViewStyle(CircularProgressViewStyle(tint: .white))

        Text("Scanning for links and buttons...")
          .font(.system(size: 16, weight: .medium))
          .foregroundColor(.white)
      }
      .padding(24)
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(Color.black.opacity(0.8))
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Main overlay view displaying clickable elements with numbered hints
struct HintOverlayView: View {
  let elements: [ClickableElement]
  let windowFrame: CGRect
  let hintManager: HintManager
  let onElementClick: (ClickableElement) -> Void
  let onDismiss: () -> Void

  @ObservedObject private var manager: HintManager

  init(
    elements: [ClickableElement],
    windowFrame: CGRect,
    hintManager: HintManager,
    onElementClick: @escaping (ClickableElement) -> Void,
    onDismiss: @escaping () -> Void
  ) {
    self.elements = elements
    self.windowFrame = windowFrame
    self.hintManager = hintManager
    self.onElementClick = onElementClick
    self.onDismiss = onDismiss
    self._manager = ObservedObject(wrappedValue: hintManager)
  }

  // Computed properties for matching elements
  private var matchingElements: [(index: Int, element: ClickableElement, hint: String)] {
    hintManager.getMatchingElements(for: hintManager.typedPrefix)
  }

  // Elements to display: all if no prefix, only matching if prefix exists
  private var elementsToDisplay: [(index: Int, element: ClickableElement, hint: String)] {
    if hintManager.typedPrefix.isEmpty {
      return elements.enumerated().compactMap { offset, element in
        guard let hint = hintManager.getHint(forIndex: offset) else { return nil }
        return (index: offset, element: element, hint: hint)
      }
    }
    return matchingElements
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        // Semi-transparent background that can be clicked to dismiss
        Color.black.opacity(0.3)
          .frame(width: geometry.size.width, height: geometry.size.height)
          .contentShape(Rectangle())
          .onTapGesture {
            debugLog("Background tapped")
            onDismiss()
          }

        // Hint badges for each element (only show matching ones when prefix is typed)
        ForEach(Array(elementsToDisplay), id: \.element.id) { item in
          let elementIndex = item.index
          let element = item.element
          let hint = item.hint
          let typedPrefix = hintManager.typedPrefix
          let isMatching = matchingElements.contains { $0.index == elementIndex }
          let matchedPrefixLength =
            typedPrefix.isEmpty
            ? 0 : (hint.hasPrefix(typedPrefix) ? typedPrefix.count : 0)

          elementHint(
            for: element,
            hint: hint,
            geometrySize: geometry.size,
            isMatching: isMatching,
            matchedPrefixLength: matchedPrefixLength
          )
        }

        // Instructions banner
        instructionsBanner
      }
    }
    .edgesIgnoringSafeArea(.all)
    .background(HintKeyEventHandlerView(hintManager: hintManager, onElementClick: onElementClick))
  }

  // MARK: - View Components
}

/// Helper view to handle keyboard events for hints using NSViewRepresentable
private struct HintKeyEventHandlerView: NSViewRepresentable {
  let hintManager: HintManager
  let onElementClick: (ClickableElement) -> Void

  func makeNSView(context: Context) -> HintKeyEventNSView {
    let view = HintKeyEventNSView()
    view.hintManager = hintManager
    view.onElementClick = onElementClick
    return view
  }

  func updateNSView(_ nsView: HintKeyEventNSView, context: Context) {}

  class HintKeyEventNSView: NSView {
    var hintManager: HintManager?
    var onElementClick: ((ClickableElement) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
      guard let hintManager = hintManager else {
        super.keyDown(with: event)
        return
      }

      let keyCode = Int64(event.keyCode)

      // Delete/Backspace
      if keyCode == Key.Named.delete.rawValue || keyCode == Key.Named.forwardDelete.rawValue {
        hintManager.removeLastCharacter()
        return
      }

      // Check if it's a valid hint character
      if let characters = event.characters?.lowercased(), let firstChar = characters.first,
        HintManager.hintCharactersSet.contains(firstChar)
      {
        let accepted = hintManager.appendCharacter(firstChar)

        if accepted {
          // Check if exactly one match after updating prefix
          let matchingElements = hintManager.getMatchingElements(for: hintManager.typedPrefix)

          // Auto-click if exactly one match
          if matchingElements.count == 1, let match = matchingElements.first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
              self?.onElementClick?(match.element)
            }
          }
        }
        return
      }

      super.keyDown(with: event)
    }
  }
}

// MARK: - HintOverlayView Components Extension

extension HintOverlayView {
  /// Creates a hint badge at the top-left corner of an element with liquid glass effect
  private func elementHint(
    for element: ClickableElement,
    hint: String,
    geometrySize: CGSize,
    isMatching: Bool,
    matchedPrefixLength: Int
  ) -> some View {
    let minHintSize: CGFloat = 14
    let hintString = hint

    // COORDINATE SYSTEM CONVERSION:
    // - element.frame: Global screen coordinates with TOP-LEFT origin (across all displays)
    // - windowFrame: Window position in global screen coordinates with BOTTOM-LEFT origin
    // - SwiftUI view: Window-relative coordinates with TOP-LEFT origin
    //
    // Conversion steps:
    // 1. Convert element global position to window-relative
    // 2. Account for coordinate system difference (bottom-left vs top-left)

    // Get the primary screen height for coordinate system conversion
    let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? windowFrame.height

    // Convert window's top edge from bottom-left to top-left origin
    let windowTopYInTopLeft = primaryScreenHeight - windowFrame.maxY

    // Convert element position to window-relative coordinates
    let viewX = element.frame.minX - windowFrame.minX
    let viewY = element.frame.minY - windowTopYInTopLeft

    // Use .position() for absolute positioning within the geometry
    // .position() sets the CENTER of the view at the given coordinates
    // X: Position hint center at left edge (minX) by adding half minimum hint size
    // Y: Position hint center at top edge (minY) by adding half minimum hint size
    // Note: The badge will expand from center, so multi-digit numbers will grow appropriately
    let posX = viewX + minHintSize / 2
    let posY = viewY + minHintSize / 2

    // Hint label content
    let textContent: some View = Group {
      if matchedPrefixLength > 0 && matchedPrefixLength < hintString.count {
        // Show matched prefix in different color
        HStack(spacing: 0) {
          Text(String(hintString.prefix(matchedPrefixLength)))
            .font(.system(size: 14, weight: .regular))
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)

          Text(String(hintString.dropFirst(matchedPrefixLength)))
            .font(.system(size: 14, weight: .regular))
            .foregroundColor(.yellow)
            .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
        }
      } else {
        Text(hintString)
          .font(.system(size: 14, weight: .regular))
          .foregroundColor(.white)
          .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
      }
    }

    return
      textContent
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .frame(minWidth: minHintSize, minHeight: minHintSize)
      .background(
        ZStack {
          // Base blur layer
          RoundedRectangle(cornerRadius: 3)
            .fill(.ultraThinMaterial)

          // Color tint layer
          RoundedRectangle(cornerRadius: 3)
            .fill(isMatching ? Color.orange.opacity(0.3) : Color.blue.opacity(0.3))

          // Subtle highlight for glass effect
          RoundedRectangle(cornerRadius: 3)
            .fill(
              LinearGradient(
                colors: [
                  Color.white.opacity(0.3),
                  Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )

          // Border
          RoundedRectangle(cornerRadius: 3)
            .strokeBorder(
              isMatching ? Color.orange.opacity(0.6) : Color.white.opacity(0.5),
              lineWidth: 0.5
            )
        }
        .shadow(color: Color.black.opacity(0.3), radius: 2, x: 0, y: 1)
      )
      .fixedSize()
      .position(x: posX, y: posY)
      .opacity(element.isEnabled ? 1.0 : 0.4)
      .contentShape(Rectangle())
      .onTapGesture {
        debugLog("Tapped hint '\(hint)' for '\(element.title)'")
        onElementClick(element)
      }
  }

  /// Instructions banner at the top of the overlay
  private var instructionsBanner: some View {
    VStack {
      HStack {
        Spacer()
        VStack(spacing: 4) {
          Text("Press ESC to dismiss")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)

          if !hintManager.typedPrefix.isEmpty {
            Text("Typed: \(hintManager.typedPrefix)")
              .font(.system(size: 12, weight: .semibold))
              .foregroundColor(.yellow)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
          RoundedRectangle(cornerRadius: 8)
            .fill(Color.black.opacity(0.8))
        )
        .padding()
        Spacer()
      }
      Spacer()
    }
  }

  // MARK: - Helpers

}
