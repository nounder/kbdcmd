import AppKit
import ArgumentParser
import Core
import Foundation

struct DaemonCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "daemon",
    abstract: "Start the keyboard command daemon"
  )

  func run() throws {
    try Permissions.checkAccessibility()

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    print("kbdcmd daemon started")
    registerDefaultKeybindings()
    _ = KeyListener.shared
    app.run()
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
    // Using both shift flags to allow either left or right shift
    kb.register(
      [KeyPress(key: .character("`"), flags: [.maskCmdRight, .maskShiftLeft, .maskShiftRight])]
    ) { _ in
      if let windowId = WindowManager.main.getFrontmostWindow() {
        let windowTitle = WindowManager.main.getWindowTitle(windowId: windowId) ?? "Window"
        KeybindingAssignmentOverlay.shared.show(forWindow: windowId, windowTitle: windowTitle)
      }
    }

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

    // Character-only sequences (replacing snippet manager)
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
