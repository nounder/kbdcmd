import Cocoa
import SwiftUI

public class KeybindingAssignmentOverlay: NSObject {
  public static let shared = KeybindingAssignmentOverlay()

  private var window: NSWindow?
  private var hostingView: NSHostingView<KeybindingAssignmentView>?
  private var currentAppPath: String?
  private var pressedKeyState: String = ""

  public var isVisible: Bool {
    return window != nil
  }

  private override init() {
    super.init()
  }

  public func show(for appPath: String) {
    self.currentAppPath = appPath
    self.pressedKeyState = ""

    // Cancel any pending window switcher overlay timer
    KeyListener.shared.cancelOverlayShow()
    // Hide window switcher if it's already showing
    WindowSwitcherOverlay.shared.hide()

    let appName = (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
    let contentView = KeybindingAssignmentView(appName: appName, pressedKey: pressedKeyState)
    let hostingView = NSHostingView(rootView: contentView)

    guard let screen = NSScreen.main else { return }
    let screenFrame = screen.frame

    let window = NSWindow(
      contentRect: screenFrame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )

    window.contentView = hostingView
    window.backgroundColor = .clear
    window.isOpaque = false
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.ignoresMouseEvents = false
    window.orderFrontRegardless()
    window.makeKey()

    self.window = window
    self.hostingView = hostingView
  }
  
  // Called from KeyListener when a key is pressed and overlay is visible
  public func handleKeyPress(keyCode: Int64, characters: String?) -> Bool {
    // ESC to cancel
    if keyCode == 53 {
      hide()
      return true
    }
    
    // Get character
    guard let characters = characters,
          let char = characters.first,
          char.isLetter else {
      return false
    }
    
    // Update the view to show pressed key
    pressedKeyState = String(char)
    updateView()
    
    // Delay slightly to show the pressed key before closing
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      self?.handleLetterInput(char)
    }
    
    return true
  }
  
  // Called when user clicks anywhere on the overlay
  public func handleMouseClick() -> Bool {
    hide()
    return true
  }
  
  private func updateView() {
    guard let hostingView = hostingView else { return }
    let appName = (currentAppPath as? NSString)?.lastPathComponent.replacingOccurrences(of: ".app", with: "") ?? ""
    let updatedView = KeybindingAssignmentView(appName: appName, pressedKey: pressedKeyState)
    hostingView.rootView = updatedView
  }

  public func hide() {
    window?.orderOut(nil)
    window = nil
    hostingView = nil
    currentAppPath = nil
    pressedKeyState = ""
  }

  private func handleLetterInput(_ letter: Character) {
    guard let appPath = currentAppPath else { return }
    
    Keybindings.shared.assignAppKeybinding(letter: letter, appPath: appPath)
    hide()
  }
}

struct KeybindingAssignmentView: View {
  let appName: String
  let pressedKey: String

  var body: some View {
    ZStack {
      // Full screen transparent background to capture clicks
      Color.black.opacity(0.6)
        .ignoresSafeArea()

      // Centered dialog
      VStack(spacing: 24) {
        Text("Assign Keybinding")
          .font(.title2)
          .fontWeight(.bold)
          .foregroundColor(.white)

        Text("Press a letter key for \(appName)")
          .font(.body)
          .foregroundColor(.white.opacity(0.8))

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
      .frame(width: 400, height: 200)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
