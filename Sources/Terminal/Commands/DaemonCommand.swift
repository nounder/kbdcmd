import ArgumentParser
import Foundation
import Core

struct DaemonCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "daemon",
    abstract: "Start the keyboard command daemon"
  )

  func run() throws {
    try Permissions.checkAccessibility()

    print("kbdcmd daemon started")
    registerDefaultKeybindings()
    KeyListener.shared.start()
  }

  private func registerDefaultKeybindings() {
    let kb = Keybindings.shared

    // Right Command + ` to assign keybinding for frontmost app
    kb.register([KeyPress(key: .character("`"), flags: .maskCmdRight)]) { _ in
      if let appPath = WindowSwitcherOverlay.getFrontmostAppPath() {
        KeybindingAssignmentOverlay.shared.show(for: appPath)
      }
    }

    kb.register([KeyPress(key: .character("O"), flags: .maskAlphaShift)]) { _ in
      HintOverlay.shared.show()
    }

    kb.register([KeyPress(key: .character("/"), flags: .maskCmdRight)]) { _ in
      HintOverlay.shared.show()
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
