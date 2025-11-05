import Cocoa
import SwiftUI

/// Public interface for the keybinding assignment overlay
/// Delegates to OverlayManager for actual implementation
public class KeybindingAssignmentOverlay: NSObject {
  public static let shared = KeybindingAssignmentOverlay()

  public var isVisible: Bool {
    return OverlayManager.shared.isAnyOverlayVisible
  }

  private override init() {
    super.init()
  }

  public func show(for appPath: String) {
    OverlayManager.shared.showKeybindingAssignmentOverlay(for: appPath)
  }

  public func show(forWindow windowId: CGWindowID, windowTitle: String) {
    OverlayManager.shared.showKeybindingAssignmentOverlay(
      forWindow: windowId, windowTitle: windowTitle)
  }

  public func hide() {
    OverlayManager.shared.hideActive()
  }
}

struct KeybindingAssignmentView: View {
  let targetName: String
  let isWindowMode: Bool
  let onKeyPress: (Character) -> Void
  let onDismiss: () -> Void

  @State private var pressedKey: String = ""
  @State private var eventMonitor: Any?

  var body: some View {
    ZStack {
      // Full screen transparent background to capture clicks
      Color.black.opacity(0.6)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {
          onDismiss()
        }

      // Centered dialog
      VStack(spacing: 24) {
        Text("Assign Keybinding")
          .font(.title2)
          .fontWeight(.bold)
          .foregroundColor(.white)

        if isWindowMode {
          Text("Character for window:")
            .font(.body)
            .foregroundColor(.white.opacity(0.8))

          Text("\(targetName)")
            .font(.body)
            .fontWeight(.semibold)
            .foregroundColor(.cyan)
            .lineLimit(2)
            .multilineTextAlignment(.center)
        } else {
          Text("Character for \(targetName)")
            .font(.body)
            .foregroundColor(.white.opacity(0.8))
        }

        if !pressedKey.isEmpty {
          Text("⌘ + \(pressedKey.uppercased())")
            .font(.system(size: 32, weight: .bold, design: .monospaced))
            .foregroundColor(.green)
        }

        Text("Press ESC or click to cancel")
          .font(.caption)
          .foregroundColor(.white.opacity(0.5))
      }
      .padding(32)
      .background(
        RoundedRectangle(cornerRadius: 16)
          .fill(Color.black.opacity(0.9))
          .shadow(color: .black.opacity(0.5), radius: 30)
      )
      .frame(width: 400, height: 240)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(KeyEventHandlerView(pressedKey: $pressedKey, onKeyPress: onKeyPress))
  }
}

/// Helper view to handle keyboard events using NSViewRepresentable
private struct KeyEventHandlerView: NSViewRepresentable {
  @Binding var pressedKey: String
  let onKeyPress: (Character) -> Void

  func makeNSView(context: Context) -> KeyEventNSView {
    let view = KeyEventNSView()
    view.pressedKey = $pressedKey
    view.onKeyPress = onKeyPress
    return view
  }

  func updateNSView(_ nsView: KeyEventNSView, context: Context) {}

  class KeyEventNSView: NSView {
    var pressedKey: Binding<String>?
    var onKeyPress: ((Character) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
      guard let characters = event.characters,
        let char = characters.first,
        char.isLetter || char.isNumber
      else {
        super.keyDown(with: event)
        return
      }

      // Update UI to show pressed key
      pressedKey?.wrappedValue = String(char)

      // Delay slightly to show feedback before closing
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        self?.onKeyPress?(char)
      }
    }
  }
}
