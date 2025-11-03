import ArgumentParser
import Foundation

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

    // CapsLock + J/K for scrolling
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

    // Right Command + Number keybindings (desktop switching)
    kb.register([KeyPress(key: .character("1"), flags: .maskCmdRight)]) { _ in
      try? WindowManager.main.switchToDesktop(number: 1)
    }

    kb.register([KeyPress(key: .character("2"), flags: .maskCmdRight)]) { _ in
      try? WindowManager.main.switchToDesktop(number: 2)
    }

    kb.register([KeyPress(key: .character("3"), flags: .maskCmdRight)]) { _ in
      try? WindowManager.main.switchToDesktop(number: 3)
    }

    kb.register([KeyPress(key: .character("4"), flags: .maskCmdRight)]) { _ in
      try? WindowManager.main.switchToDesktop(number: 4)
    }

    kb.register([KeyPress(key: .character("5"), flags: .maskCmdRight)]) { _ in
      try? WindowManager.main.switchToDesktop(number: 5)
    }

    kb.register([KeyPress(key: .character("6"), flags: .maskCmdRight)]) { _ in
      try? WindowManager.main.switchToDesktop(number: 6)
    }

    kb.register([KeyPress(key: .character("7"), flags: .maskCmdRight)]) { _ in
      try? WindowManager.main.switchToDesktop(number: 7)
    }

    kb.register([KeyPress(key: .character("8"), flags: .maskCmdRight)]) { _ in
      try? WindowManager.main.switchToDesktop(number: 8)
    }

    kb.register([KeyPress(key: .character("9"), flags: .maskCmdRight)]) { _ in
      try? WindowManager.main.switchToDesktop(number: 9)
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
