import AppKit
import ApplicationServices
import Core
import SwiftUI

struct InstallDialogView: View {
  let onInstall: () -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "keyboard.badge.ellipsis")
        .font(.system(size: 56, weight: .light))
        .foregroundStyle(.primary)
        .symbolRenderingMode(.hierarchical)

      VStack(spacing: 8) {
        Text("Install Kbdcmd?")
          .font(.title2)
          .fontWeight(.semibold)

        Text(
          "Kbdcmd works best when installed in your Applications folder."
        )
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      }

      VStack(spacing: 10) {
        Button(action: onInstall) {
          Text("Install")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)

        Button(action: onCancel) {
          Text("Cancel")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .keyboardShortcut(.cancelAction)
      }
      .padding(.top, 4)
    }
    .padding(28)
    .frame(width: 280)
    .background(.ultraThinMaterial)
  }
}

@main
struct KbdcmdApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    Settings {
      EmptyView()
    }
  }
}

class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem!
  private var menu: NSMenu!

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Kill any previous instances of the app
    terminatePreviousInstances()

    // Check if running from Applications folder, offer to move if not
    if !isRunningFromApplicationsFolder() {
      if offerToMoveToApplications() {
        return  // App will relaunch from Applications
      }
    }

    // Check accessibility permissions
    if !AXIsProcessTrusted() {
      showAccessibilityAlert()
      return
    }

    setupMenuBar()
    startDaemon()
  }

  private func terminatePreviousInstances() {
    let currentPid = ProcessInfo.processInfo.processIdentifier
    let bundleId = Bundle.main.bundleIdentifier ?? "org.libred.kbdcmd"

    for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
      if app.processIdentifier != currentPid {
        app.terminate()
      }
    }
  }

  private func isRunningFromApplicationsFolder() -> Bool {
    guard let bundlePath = Bundle.main.bundlePath as NSString? else { return false }
    let path = bundlePath as String

    // Check both /Applications and ~/Applications
    if path.hasPrefix("/Applications/") { return true }
    if let home = FileManager.default.homeDirectoryForCurrentUser.path as String?,
      path.hasPrefix("\(home)/Applications/")
    {
      return true
    }
    return false
  }

  private func offerToMoveToApplications() -> Bool {
    let bundlePath = Bundle.main.bundlePath

    NSApp.activate(ignoringOtherApps: true)

    var userChoice: Bool?

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 280, height: 280),
      styleMask: [.titled, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = ""
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.standardWindowButton(.closeButton)?.isHidden = true
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true
    window.isMovableByWindowBackground = true
    window.backgroundColor = .clear
    window.center()

    let contentView = InstallDialogView(
      onInstall: {
        userChoice = true
        window.close()
        NSApp.stopModal()
      },
      onCancel: {
        userChoice = false
        window.close()
        NSApp.stopModal()
      }
    )
    window.contentView = NSHostingView(rootView: contentView)

    NSApp.runModal(for: window)

    guard userChoice == true else {
      print("User cancelled")
      return false
    }

    print("Starting install from: \(bundlePath)")

    let destinationPath = "/Applications/Kbdcmd.app"
    let fileManager = FileManager.default

    do {
      // Remove existing app in Applications if present
      if fileManager.fileExists(atPath: destinationPath) {
        print("Removing existing app at \(destinationPath)")
        try fileManager.removeItem(atPath: destinationPath)
      }

      // Copy the app (don't move, in case we're running from a read-only location)
      print("Copying app to \(destinationPath)")
      try fileManager.copyItem(atPath: bundlePath, toPath: destinationPath)
      print("Copy successful")

      // Launch the app from new location using open command
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      process.arguments = [destinationPath]
      try process.run()

      // Quit this instance
      NSApplication.shared.terminate(nil)
      return true

    } catch {
      print("Install error: \(error)")
      let errorAlert = NSAlert()
      errorAlert.messageText = "Failed to Install"
      errorAlert.informativeText =
        "Could not install Kbdcmd to Applications: \(error.localizedDescription)"
      errorAlert.alertStyle = .warning
      errorAlert.addButton(withTitle: "OK")
      errorAlert.runModal()
      return false
    }
  }

  private func setupMenuBar() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    if let button = statusItem.button {
      button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Kbdcmd")
    }

    menu = NSMenu()

    menu.addItem(NSMenuItem(title: "Kbdcmd v0.2.0", action: nil, keyEquivalent: ""))
    menu.addItem(NSMenuItem.separator())
    menu.addItem(NSMenuItem(title: "Status: Running", action: nil, keyEquivalent: ""))
    menu.addItem(NSMenuItem.separator())
    menu.addItem(NSMenuItem(title: "Restart", action: #selector(restart), keyEquivalent: "r"))
    menu.addItem(NSMenuItem.separator())
    menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

    statusItem.menu = menu
  }

  private func startDaemon() {
    // Initialize KeyListener (this sets up event tap on the current run loop)
    // No need to call .start() - the app's run loop will handle it
    _ = KeyListener.shared

    // Register all keybindings
    registerDefaultKeybindings()

    print("✓ Kbdcmd daemon started - listening for keyboard shortcuts")
  }

  @objc private func restart() {
    NSApplication.shared.terminate(nil)
    let task = Process()
    task.launchPath = Bundle.main.executablePath
    task.launch()
  }

  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }

  private func showAccessibilityAlert() {
    NSApp.activate(ignoringOtherApps: true)

    // Try to trigger the system permission prompt
    let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    let accessibilityEnabled = AXIsProcessTrustedWithOptions(options)

    // If still not enabled after prompt, show our alert
    if !accessibilityEnabled {
      let alert = NSAlert()
      alert.messageText = "Accessibility Permission Required"
      alert.informativeText = """
        Kbdcmd needs Accessibility permissions to monitor keyboard shortcuts.

        Please:
        1. Click "Open System Settings" below
        2. Find Kbdcmd in the list
        3. Toggle it ON
        4. Restart the app
        """
      alert.alertStyle = .warning
      alert.addButton(withTitle: "Open System Settings")
      alert.addButton(withTitle: "Quit")

      let response = alert.runModal()
      if response == .alertFirstButtonReturn {
        NSWorkspace.shared.open(
          URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
      }
    }

    NSApplication.shared.terminate(nil)
  }

  private func registerDefaultKeybindings() {
    let kb = Keybindings.shared

    // Right Command + ` to assign keybinding for frontmost app
    kb.register([KeyPress(key: .character("`"), flags: .maskCmdRight)]) { _ in
      if let appPath = WindowManager.main.getFrontmostAppPath() {
        KeybindingAssignmentOverlay.shared.show(for: appPath)
      }
    }

    // Right Command + Shift + ` to assign keybinding for frontmost window
    kb.register(
      [KeyPress(key: .character("`"), flags: [.maskCmdRight, .maskShiftLeft, .maskShiftRight])]
    ) { _ in
      if let windowId = WindowManager.main.getFrontmostWindow() {
        let windowTitle = WindowManager.main.getWindowTitle(windowId: windowId) ?? "Window"
        KeybindingAssignmentOverlay.shared.show(forWindow: windowId, windowTitle: windowTitle)
      }
    }

    // CapsLock + O for hints
    kb.register([KeyPress(key: .character("O"), flags: .maskAlphaShift)]) { _ in
      OverlayManager.shared.showHintOverlay()
    }

    // Right Command + / for hints
    kb.register([KeyPress(key: .character("/"), flags: .maskCmdRight)]) { _ in
      OverlayManager.shared.showHintOverlay()
    }

    // CapsLock + J/K for scrolling
    kb.register([KeyPress(key: .character("J"), flags: .maskAlphaShift)]) { _ in
      Scrolling.shared.smoothScroll(-120)
    }

    kb.register([KeyPress(key: .character("K"), flags: .maskAlphaShift)]) { _ in
      Scrolling.shared.smoothScroll(120)
    }

    // Character-only sequences (snippets)
    let seqTdf = [
      KeyPress(key: .character("t")),
      KeyPress(key: .character("d")),
      KeyPress(key: .character("f")),
    ]
    kb.register(seqTdf) { seq in
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
    kb.register(seqTds) { seq in
      let df = DateFormatter()
      df.dateFormat = "yyMMdd"
      let dateString = df.string(from: Date())
      Snippets.expandSnippet(for: seq, insert: dateString)
    }
  }
}
