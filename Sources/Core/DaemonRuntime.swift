import Foundation

public enum DaemonRuntime {
  public static func start() {
    registerDefaultKeybindings()
    _ = KeyListener.shared
    if DictationSettings.enabled {
      DictationController.shared.activate()
    }
  }

  private static func registerDefaultKeybindings() {
    let kb = Keybindings.shared

    kb.register([KeyPress(key: .character("`"), flags: .maskCmdRight)]) { _ in
      if let appPath = WindowManager.main.getFrontmostAppPath() {
        KeybindingAssignmentOverlay.shared.show(for: appPath)
      }
    }

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

    kb.register([KeyPress(key: .character("J"), flags: .maskAlphaShift)]) { _ in
      Scrolling.shared.smoothScroll(-120)
    }

    kb.register([KeyPress(key: .character("K"), flags: .maskAlphaShift)]) { _ in
      Scrolling.shared.smoothScroll(120)
    }

    let seqTdf = [
      KeyPress(key: .character("t")),
      KeyPress(key: .character("d")),
      KeyPress(key: .character("f")),
    ]
    kb.register(seqTdf) { seq in
      let df = DateFormatter()
      df.dateFormat = "yyyy-MM-dd"
      Snippets.expandSnippet(for: seq, insert: df.string(from: Date()))
    }

    let seqTds = [
      KeyPress(key: .character("t")),
      KeyPress(key: .character("d")),
      KeyPress(key: .character("s")),
    ]
    kb.register(seqTds) { seq in
      let df = DateFormatter()
      df.dateFormat = "yyMMdd"
      Snippets.expandSnippet(for: seq, insert: df.string(from: Date()))
    }

    kb.register([KeyPress(key: .named(.upArrow), flags: .maskAlphaShift)]) { _ in
      WindowManager.main.moveFrontmostWindow(direction: .up)
    }
    kb.register([KeyPress(key: .named(.downArrow), flags: .maskAlphaShift)]) { _ in
      WindowManager.main.moveFrontmostWindow(direction: .down)
    }
    kb.register([KeyPress(key: .named(.leftArrow), flags: .maskAlphaShift)]) { _ in
      WindowManager.main.moveFrontmostWindow(direction: .left)
    }
    kb.register([KeyPress(key: .named(.rightArrow), flags: .maskAlphaShift)]) { _ in
      WindowManager.main.moveFrontmostWindow(direction: .right)
    }

    kb.register(
      [KeyPress(key: .named(.rightArrow), flags: [.maskAlphaShift, .maskShiftLeft, .maskShiftRight])]
    ) { _ in
      WindowManager.main.resizeFrontmostWindow(direction: .right)
    }
    kb.register(
      [KeyPress(key: .named(.leftArrow), flags: [.maskAlphaShift, .maskShiftLeft, .maskShiftRight])]
    ) { _ in
      WindowManager.main.resizeFrontmostWindow(direction: .left)
    }
    kb.register(
      [KeyPress(key: .named(.downArrow), flags: [.maskAlphaShift, .maskShiftLeft, .maskShiftRight])]
    ) { _ in
      WindowManager.main.resizeFrontmostWindow(direction: .down)
    }
    kb.register(
      [KeyPress(key: .named(.upArrow), flags: [.maskAlphaShift, .maskShiftLeft, .maskShiftRight])]
    ) { _ in
      WindowManager.main.resizeFrontmostWindow(direction: .up)
    }
  }
}
