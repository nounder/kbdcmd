import Cocoa
import SwiftUI

public class KeybindingAssignmentOverlay: NSObject {
  public static let shared = KeybindingAssignmentOverlay()

  private var window: NSWindow?
  private var hostingView: NSHostingView<KeybindingAssignmentView>?
  private var currentAppPath: String?
  private var currentWindowId: CGWindowID?
  private var assignmentMode: AssignmentMode = .app
  private var pressedKeyState: String = ""

  enum AssignmentMode {
    case app
    case window
  }

  public var isVisible: Bool {
    return window != nil
  }

  private override init() {
    super.init()
  }

  public func show(for appPath: String) {
    self.currentAppPath = appPath
    self.currentWindowId = nil
    self.assignmentMode = .app
    self.pressedKeyState = ""

    // Cancel any pending window switcher overlay timer
    KeyListener.shared.cancelOverlayShow()
    // Hide window switcher if it's already showing
    WindowSwitcherOverlay.shared.hide()

    let appName = (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
    let contentView = KeybindingAssignmentView(
      targetName: appName,
      pressedKey: pressedKeyState,
      isWindowMode: false
    )
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

  public func show(forWindow windowId: CGWindowID, windowTitle: String) {
    self.currentWindowId = windowId
    self.currentAppPath = nil
    self.assignmentMode = .window
    self.pressedKeyState = ""

    // Cancel any pending window switcher overlay timer
    KeyListener.shared.cancelOverlayShow()
    // Hide window switcher if it's already showing
    WindowSwitcherOverlay.shared.hide()

    let contentView = KeybindingAssignmentView(
      targetName: windowTitle,
      pressedKey: pressedKeyState,
      isWindowMode: true
    )
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
    
    let targetName: String
    let isWindowMode: Bool
    
    switch assignmentMode {
    case .app:
      targetName = (currentAppPath as? NSString)?.lastPathComponent.replacingOccurrences(of: ".app", with: "") ?? ""
      isWindowMode = false
    case .window:
      targetName = WindowManager.main.getWindowTitle(windowId: currentWindowId ?? 0) ?? "Window"
      isWindowMode = true
    }
    
    let updatedView = KeybindingAssignmentView(
      targetName: targetName,
      pressedKey: pressedKeyState,
      isWindowMode: isWindowMode
    )
    hostingView.rootView = updatedView
  }

  public func hide() {
    window?.orderOut(nil)
    window = nil
    hostingView = nil
    currentAppPath = nil
    currentWindowId = nil
    assignmentMode = .app
    pressedKeyState = ""
  }

  private func handleLetterInput(_ letter: Character) {
    switch assignmentMode {
    case .app:
      guard let appPath = currentAppPath else { return }
      Keybindings.shared.assignAppKeybinding(letter: letter, appPath: appPath)
    case .window:
      guard let windowId = currentWindowId else { return }
      // Always include minimized windows for window keybindings
      Keybindings.shared.assignWindowKeybinding(letter: letter, windowId: windowId, includeMinimized: true)
    }
    hide()
  }
}

struct KeybindingAssignmentView: View {
  let targetName: String
  let pressedKey: String
  let isWindowMode: Bool

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

        if isWindowMode {
          Text("Press a letter key for window:")
            .font(.body)
            .foregroundColor(.white.opacity(0.8))

          Text("\(targetName)")
            .font(.body)
            .fontWeight(.semibold)
            .foregroundColor(.cyan)
            .lineLimit(2)
            .multilineTextAlignment(.center)
        } else {
          Text("Press a letter key for \(targetName)")
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
  }
}
