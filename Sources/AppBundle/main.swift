import ApplicationServices
import Cocoa

enum AppOpenResult {
  case invalidPath
  case opened
  case focused
}

func openSystemPreferencesToAccessibility() {
  let url = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
  NSWorkspace.shared.open(url)
}

func checkAccessibilityPermissions() -> Bool {
  if !AXIsProcessTrusted() {
    print("Error: This application doesn't have the required accessibility permissions.")
    print(
      "Please grant accessibility permissions to Terminal (or your development environment) in:"
    )
    print("System Preferences > Security & Privacy > Privacy > Accessibility")
    openSystemPreferencesToAccessibility()

    return false
  }

  return true
}

func simulateKeyPress(keyCode: CGKeyCode, flags: CGEventFlags) {
  guard let source = CGEventSource(stateID: .hidSystemState) else { return }

  guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
  else { return }

  keyDown.flags = flags
  keyUp.flags = flags

  keyDown.post(tap: .cghidEventTap)
  usleep(400)  // Small delay to ensure the event is processed
  keyUp.post(tap: .cghidEventTap)
}

func cycleAppWindows() {
  let manager = WindowManager.main

  guard let frontmostApp = manager.getFrontmostApplication() else {
    print("Cannot get frontmost application")
    return
  }

  let axApp = AXUIElementCreateApplication(frontmostApp.processIdentifier)

  var axValue: AnyObject?
  let result = AXUIElementCopyAttributeValue(
    axApp, kAXWindowsAttribute as CFString, &axValue)

  guard result == .success else {
    print("Could not get Accessability windows")

    return
  }

  let axWindows = axValue as? [AXUIElement]

  guard let axWindows = axWindows else {
    print("Could not get Accessability windows")

    return
  }

  let nonMinimizedWindows = axWindows.filter {
    $0.get(Ax.minimizedAttr) != true
  }

  if nonMinimizedWindows.count <= 1 {
    return
  }

  // Raise the last window to properly cycle through all windows
  // When raised, it becomes the frontmost, creating a rotation effect
  _ = nonMinimizedWindows.last!.raise()
}

func createNewWindowViaMenu(for app: AXUIElement) -> Bool {
  // Get menu bar element
  var menuBar: AnyObject?
  guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBar) == .success,
    CFGetTypeID(menuBar) == AXUIElementGetTypeID()
  else {
    debugLog("Could not get menu bar")
    return false
  }

  let menuBarElement = menuBar as! AXUIElement

  // Get localized "File" menu name from system
  let localizedFileMenu = getLocalizedString(key: "File", tableName: "MenuCommands")
  let localizedNewWindow = getLocalizedString(key: "New Window", tableName: "MenuCommands")

  debugLog("Looking for File menu: '\(localizedFileMenu)', New Window: '\(localizedNewWindow)'")

  // First, find the File menu
  let tree = AXTree(root: menuBarElement)
  var fileMenu: AXUIElement?

  tree.traverse { element, depth in
    guard depth <= 1 else { return .skipChildren }

    let values = element.getAttributes(kAXTitleAttribute)
    if let title = values[0] as? String, title == localizedFileMenu {
      fileMenu = element
      return .stop
    }

    return nil
  }

  guard let fileMenu = fileMenu else {
    debugLog("Could not find File menu")
    return false
  }

  // Now traverse only within the File menu to find New Window
  let fileTree = AXTree(root: fileMenu)
  var foundItem: AXUIElement?

  fileTree.traverse { element, depth in
    // Search by exact "New Window" title to avoid conflicts with other shortcuts
    // (e.g., Mail.app uses Cmd+N for "New Message" instead of "New Window")
    let values = element.getAttributes(kAXTitleAttribute)
    if let itemTitle = values[0] as? String, itemTitle == localizedNewWindow {
      foundItem = element
      return .stop
    }

    return nil
  }

  if let item = foundItem {
    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
  }

  return false
}

func getLocalizedString(key: String, tableName: String) -> String {
  // Try to get system localized string
  // This searches in /System/Library/Frameworks/AppKit.framework/Resources/
  if let bundle = Bundle(identifier: "com.apple.AppKit") {
    let localized = bundle.localizedString(forKey: key, value: nil, table: tableName)
    if localized != key {
      return localized
    }
  }
  return key
}

func switchToDesktop(number: Int) {
  guard (1...9).contains(number) else {
    print("Error: Invalid desktop number. Must be between 1 and 9.")
    return
  }

  // Simulate pressing the number key for the desired desktop
  let desktopKeyCode = CGKeyCode(0x12 + (number - 1))  // 0x12 is '1' key
  simulateKeyPress(keyCode: desktopKeyCode, flags: .maskControl)

  print("Switched to desktop \(number)")
}

func openOrFocusApp(_ appPath: String, ignoreMinimized: Bool = true) -> AppOpenResult {
  let fileManager = FileManager.default

  // Validate app path exists and is an application bundle
  guard fileManager.fileExists(atPath: appPath),
    appPath.hasSuffix(".app")
  else {
    print("Invalid application path")
    return .invalidPath
  }

  let appURL = URL(fileURLWithPath: appPath)

  guard let bundle = Bundle(url: appURL),
    let bundleId = bundle.bundleIdentifier
  else {
    NSWorkspace.shared.openApplication(
      at: appURL,
      configuration: NSWorkspace.OpenConfiguration())
    return .opened
  }

  if let runningApp = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleIdentifier == bundleId
  }
  ) {
    let isAlreadyFrontmost = runningApp.isActive
    let axApp = AXUIElementCreateApplication(runningApp.processIdentifier)

    var axValue: AnyObject?
    let result = AXUIElementCopyAttributeValue(
      axApp, kAXWindowsAttribute as CFString, &axValue)

    if result == .success, let axWindows = axValue as? [AXUIElement] {
      // When ignoreMinimized is true, check if all windows are minimized and create a new window if so
      if ignoreMinimized {
        let hasNonMinimizedWindow = axWindows.contains { $0.get(Ax.minimizedAttr) != true }

        if !hasNonMinimizedWindow {
          // Activate the app first to ensure any new window will be frontmost
          runningApp.activate(options: .activateIgnoringOtherApps)

          // First try to create a new window via menu (if File > New Window exists)
          if createNewWindowViaMenu(for: axApp) {
            return .opened
          }
          // If menu approach failed (no File > New Window), re-open the app
          // This handles apps like Calendar that don't have File > New Window
          // Calling openApplication on an already-running app shows its window
          NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: NSWorkspace.OpenConfiguration())
          return .opened
        }
      }

      // If app is already frontmost and has multiple windows, cycle through them
      if isAlreadyFrontmost && axWindows.count > 1 {
        let nonMinimizedWindows = axWindows.filter {
          $0.get(Ax.minimizedAttr) != true
        }

        if nonMinimizedWindows.count > 1 {
          // Raise the last window to properly cycle through all windows
          // When raised, it becomes the frontmost, creating a rotation effect
          _ = nonMinimizedWindows.last!.raise()
          return .focused
        }
      }
    } else {
      // If we can't get windows info, just activate the app
      runningApp.activate(options: .activateIgnoringOtherApps)
      return .focused
    }

    runningApp.activate(options: .activateIgnoringOtherApps)
    return .focused
  }

  NSWorkspace.shared.openApplication(
    at: appURL,
    configuration: NSWorkspace.OpenConfiguration())

  return .opened
}

func launchApp(at url: URL) {
  NSWorkspace.shared.openApplication(
    at: url,
    configuration: NSWorkspace.OpenConfiguration())
}

func cmdCycleWindows() {
  cycleAppWindows()
}

func cmdOpen(_ appName: String) {
  _ = openOrFocusApp(appName)
}

func cmdOpenCycle(_ appName: String) {
  let result = openOrFocusApp(appName)

  if result == .opened {
    cycleAppWindows()
  }
}

func cmdSwitchDesktop(_ desktopNumber: String) {
  guard let number = Int(desktopNumber) else {
    print("Error: Please specify a valid desktop number")
    return
  }
  _ = switchToDesktop(number: number)
}

func registerDefaultKeybindings() {
  let kb = Keybindings.shared

  // Right Command + Letter keybindings (single-key sequences)
  kb.register([KeyPress(key: .character("L"), flags: .maskCmdRight)]) { _ in
    cycleAppWindows()
  }

  kb.register([KeyPress(key: .character("D"), flags: .maskCmdRight)]) { _ in
    cmdOpenCycle("/Applications/Ghostty.app")
  }

  kb.register([KeyPress(key: .character("S"), flags: .maskCmdRight)]) { _ in
    cmdOpenCycle("/Applications/Safari.app")
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
    cmdOpenCycle("/Applications/Cursor.app")
  }

  kb.register([KeyPress(key: .character("B"), flags: .maskCmdRight)]) { _ in
    cmdOpenCycle("/Applications/Spotify.app")
  }

  kb.register([KeyPress(key: .character("C"), flags: .maskCmdRight)]) { _ in
    cmdOpenCycle("/System/Applications/Calendar.app")
  }

  kb.register([KeyPress(key: .character("G"), flags: .maskCmdRight)]) { _ in
    cmdOpenCycle("/Applications/ChatGPT.app")
  }

  kb.register([KeyPress(key: .character("H"), flags: .maskCmdRight)]) { _ in
    cmdOpenCycle("/Users/rg/Applications/Claude.app")
  }

  kb.register([KeyPress(key: .character("J"), flags: .maskCmdRight)]) { _ in
    cmdOpenCycle("/Users/rg/Applications/Perplexity.app")
  }

  kb.register([KeyPress(key: .character("M"), flags: .maskCmdRight)]) { _ in
    cmdOpenCycle("/System/Applications/Mail.app")
  }

  kb.register([KeyPress(key: .character("Z"), flags: .maskCmdRight)]) { _ in
    cmdOpenCycle("/Applications/Google Chrome Canary.app")
  }

  // Right Command + Number keybindings (desktop switching)
  kb.register([KeyPress(key: .character("1"), flags: .maskCmdRight)]) { _ in
    switchToDesktop(number: 1)
  }

  kb.register([KeyPress(key: .character("2"), flags: .maskCmdRight)]) { _ in
    switchToDesktop(number: 2)
  }

  kb.register([KeyPress(key: .character("3"), flags: .maskCmdRight)]) { _ in
    switchToDesktop(number: 3)
  }

  kb.register([KeyPress(key: .character("4"), flags: .maskCmdRight)]) { _ in
    switchToDesktop(number: 4)
  }

  kb.register([KeyPress(key: .character("5"), flags: .maskCmdRight)]) { _ in
    switchToDesktop(number: 5)
  }

  kb.register([KeyPress(key: .character("6"), flags: .maskCmdRight)]) { _ in
    switchToDesktop(number: 6)
  }

  kb.register([KeyPress(key: .character("7"), flags: .maskCmdRight)]) { _ in
    switchToDesktop(number: 7)
  }

  kb.register([KeyPress(key: .character("8"), flags: .maskCmdRight)]) { _ in
    switchToDesktop(number: 8)
  }

  kb.register([KeyPress(key: .character("9"), flags: .maskCmdRight)]) { _ in
    switchToDesktop(number: 9)
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

func cmdDameon() {
  puts("kbdcmd daemon started")
  registerDefaultKeybindings()
  KeyListener.shared.start()
}

func cmdMarkWindow() {
  WindowMarkManager.shared.markWindow()
}

func cmdFocusMark(_ mark: String) {
  WindowMarkManager.shared.focusMarkedWindow(mark: mark)
}

func executeCommand(_ args: [String]) -> Int {
  let commands: [String: ([String]) -> Void] = [
    "open": { cmdOpen($0[2]) },
    "cycle": { _ in cmdCycleWindows() },
    "open-cycle": { cmdOpenCycle($0[2]) },
    "switch-desktop": { cmdSwitchDesktop($0[2]) },
    "daemon": { _ in cmdDameon() },
    "mark-window": { _ in cmdMarkWindow() },
    "focus-mark": { cmdFocusMark($0[2]) },
  ]

  guard args.count > 1, let command = commands[args[1]] else {
    print("Available commands: \(commands.keys.joined(separator: " "))")
    return 1
  }

  if !checkAccessibilityPermissions() {
    exit(1)
  }
  command(args)
  return 0
}

let args = CommandLine.arguments
exit(Int32(executeCommand(args)))
