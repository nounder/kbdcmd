import AppKit
import ApplicationServices
import SwiftUI
import Core

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
    // Check accessibility permissions
    if !AXIsProcessTrusted() {
      showAccessibilityAlert()
      return
    }
    
    setupMenuBar()
    startDaemon()
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
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
      }
    }
    
    NSApplication.shared.terminate(nil)
  }
  
  private func registerDefaultKeybindings() {
    let kb = Keybindings.shared
    
    kb.register([KeyPress(key: .character("L"), flags: .maskCmdRight)]) { _ in
      WindowManager.main.cycleAppWindows()
    }
    
    kb.register([KeyPress(key: .character("D"), flags: .maskCmdRight)]) { _ in
      _ = try? ApplicationManager.openOrFocus("/Applications/Ghostty.app")
    }
    
    kb.register([KeyPress(key: .character("S"), flags: .maskCmdRight)]) { _ in
      _ = try? ApplicationManager.openOrFocus("/Applications/Safari.app")
    }
    
    kb.register([KeyPress(key: .character("O"), flags: .maskAlphaShift)]) { _ in
      HintOverlay.shared.show()
    }
    
    kb.register([KeyPress(key: .character("J"), flags: .maskAlphaShift)]) { _ in
      Scrolling.shared.smoothScroll(-120)
    }
    
    kb.register([KeyPress(key: .character("K"), flags: .maskAlphaShift)]) { _ in
      Scrolling.shared.smoothScroll(120)
    }
    
    kb.register([KeyPress(key: .character("V"), flags: .maskCmdRight)]) { _ in
      _ = try? ApplicationManager.openOrFocus("/Applications/Cursor.app")
    }
    
    kb.register([KeyPress(key: .character("B"), flags: .maskCmdRight)]) { _ in
      _ = try? ApplicationManager.openOrFocus("/Applications/Spotify.app")
    }
    
    kb.register([KeyPress(key: .character("U"), flags: .maskCmdRight)]) { _ in
      _ = try? ApplicationManager.openOrFocus("/System/Applications/Calendar.app")
    }
    
    kb.register([KeyPress(key: .character("C"), flags: .maskCmdRight)]) { _ in
      _ = try? ApplicationManager.openOrFocus("/Applications/Warp.app")
    }
    
    kb.register([KeyPress(key: .character("G"), flags: .maskCmdRight)]) { _ in
      _ = try? ApplicationManager.openOrFocus("/Applications/ChatGPT.app")
    }
    
    kb.register([KeyPress(key: .character("H"), flags: .maskCmdRight)]) { _ in
      _ = try? ApplicationManager.openOrFocus("/Users/rg/Applications/Claude.app")
    }
    
    kb.register([KeyPress(key: .character("J"), flags: .maskCmdRight)]) { _ in
      _ = try? ApplicationManager.openOrFocus("/Users/rg/Applications/Perplexity.app")
    }
    
    kb.register([KeyPress(key: .character("M"), flags: .maskCmdRight)]) { _ in
      _ = try? ApplicationManager.openOrFocus("/System/Applications/Mail.app")
    }
    
    kb.register([KeyPress(key: .character("Z"), flags: .maskCmdRight)]) { _ in
      _ = try? ApplicationManager.openOrFocus("/Applications/Google Chrome Canary.app")
    }
    
    for i in 1...9 {
      kb.register([KeyPress(key: .character(Character("\(i)")), flags: .maskCmdRight)]) { _ in
        try? WindowManager.main.switchToDesktop(number: i)
      }
    }
    
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

