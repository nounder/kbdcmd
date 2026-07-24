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

struct AccessibilityPermissionView: View {
  @Binding var permissionGranted: Bool
  let onOpenSettings: () -> Void
  let onQuit: () -> Void

  var body: some View {
    VStack(spacing: 24) {
      // Animated icon
      ZStack {
        Circle()
          .fill(
            RadialGradient(
              colors: [Color.accentColor.opacity(0.3), Color.clear],
              center: .center,
              startRadius: 0,
              endRadius: 60
            )
          )
          .frame(width: 120, height: 120)

        Image(systemName: permissionGranted ? "checkmark.shield.fill" : "hand.raised.fill")
          .font(.system(size: 48, weight: .light))
          .foregroundStyle(permissionGranted ? .green : .accentColor)
          .symbolRenderingMode(.hierarchical)
      }

      VStack(spacing: 12) {
        Text(permissionGranted ? "Permission Granted!" : "Accessibility Permission Required")
          .font(.title2)
          .fontWeight(.semibold)

        if permissionGranted {
          Text("Starting Kbdcmd...")
            .font(.body)
            .foregroundStyle(.secondary)
        } else {
          Text("Kbdcmd needs Accessibility permission to monitor keyboard shortcuts and interact with other apps.")
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      if !permissionGranted {
        VStack(alignment: .leading, spacing: 10) {
          StepRow(number: 1, text: "Click \"Open System Settings\" below")
          StepRow(number: 2, text: "Find Kbdcmd in the list")
          StepRow(number: 3, text: "Toggle it ON", hint: "If already enabled, remove with − and re-add")
        }
        .padding(.horizontal, 8)

        HStack(spacing: 8) {
          Circle()
            .fill(Color.orange)
            .frame(width: 8, height: 8)
          Text("Waiting for permission...")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

        VStack(spacing: 10) {
          Button(action: onOpenSettings) {
            HStack {
              Image(systemName: "gear")
              Text("Open System Settings")
            }
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)

          Button(action: onQuit) {
            Text("Quit")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .controlSize(.large)
          .keyboardShortcut(.cancelAction)
        }
      }
    }
    .padding(32)
    .frame(width: 340)
    .background(.ultraThinMaterial)
    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: permissionGranted)
  }
}

struct StepRow: View {
  let number: Int
  let text: String
  var hint: String? = nil

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Text("\(number)")
        .font(.caption)
        .fontWeight(.bold)
        .foregroundStyle(.white)
        .frame(width: 20, height: 20)
        .background(Color.accentColor, in: Circle())

      VStack(alignment: .leading, spacing: 2) {
        Text(text)
          .font(.callout)
          .foregroundStyle(.primary)
        if let hint = hint {
          Text(hint)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
    }
  }
}

@main
struct KbdcmdApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    Settings {
      SettingsView()
    }
  }
}

class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem!
  private var menu: NSMenu!
  private var settingsWindow: NSWindow?
  private var permissionWindow: NSWindow?
  private var permissionTimer: Timer?
  private var permissionGranted = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Kill any previous instances of the app
    terminatePreviousInstances()

    // Check accessibility permissions
    if !AXIsProcessTrusted() {
      // Only offer to move to Applications if not already there and permission not granted
      if !isRunningFromApplicationsFolder() {
        if offerToMoveToApplications() {
          return  // App will relaunch from Applications
        }
      }
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
        // Polite terminate() is ignored by a headless accessory instance
        // whose run loop is busy with the event tap; force it so old and new
        // instances can't end up killing each other instead.
        app.forceTerminate()
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
      // Note: NSWorkspace.openApplication doesn't work here (app doesn't start), must use open CLI
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
    menu.addItem(
      NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
    menu.addItem(NSMenuItem.separator())
    menu.addItem(NSMenuItem(title: "Restart", action: #selector(restart), keyEquivalent: "r"))
    menu.addItem(NSMenuItem.separator())
    menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

    statusItem.menu = menu
  }

  private func startDaemon() {
    DaemonRuntime.start()
    print("✓ Kbdcmd daemon started - listening for keyboard shortcuts!")
  }

  @objc private func openSettings() {
    if settingsWindow == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 450, height: 150),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
      )
      window.title = "Kbdcmd Settings"
      window.contentView = NSHostingView(rootView: SettingsView())
      window.center()
      window.isReleasedWhenClosed = false
      settingsWindow = window
    }

    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.makeKeyAndOrderFront(nil)
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

    // Don't trigger system prompt - we show our own custom UI
    let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
    _ = AXIsProcessTrustedWithOptions(options)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
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
    window.level = .floating
    window.center()
    window.isReleasedWhenClosed = false

    permissionWindow = window
    updatePermissionView()
    window.makeKeyAndOrderFront(nil)
    startPermissionPolling()
  }

  private func updatePermissionView() {
    guard let window = permissionWindow else { return }
    let contentView = AccessibilityPermissionView(
      permissionGranted: Binding(
        get: { [weak self] in self?.permissionGranted ?? false },
        set: { [weak self] in self?.permissionGranted = $0 }
      ),
      onOpenSettings: {
        NSWorkspace.shared.open(
          URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
      },
      onQuit: {
        NSApplication.shared.terminate(nil)
      }
    )
    window.contentView = NSHostingView(rootView: contentView)
  }

  private func startPermissionPolling() {
    permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
      guard let self = self else {
        timer.invalidate()
        return
      }
      if AXIsProcessTrusted() {
        timer.invalidate()
        self.permissionTimer = nil
        NSApp.activate(ignoringOtherApps: true)
        self.permissionGranted = true
        self.updatePermissionView()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
          self?.permissionWindow?.close()
          self?.permissionWindow = nil
          self?.setupMenuBar()
          self?.startDaemon()
        }
      }
    }
  }


}
