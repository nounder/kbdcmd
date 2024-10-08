import ApplicationServices
import Cocoa

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

  let appWindows = manager.listWindows().filter {
    $0.app.processIdentifier == frontmostApp.processIdentifier
  }

  if appWindows.count == 0 {
    return
  }

  for (i, window) in appWindows[1...].reversed().enumerated() {
    let ti = axWindows.count - i - 1

    let axWindow = axWindows[ti]

    if axWindow.get(Ax.minimizedAttr) == true {
      continue
    }

    axWindow.raise()
  }
}

func createNewWindow(for pid: pid_t) {
  let app = AXUIElementCreateApplication(pid)

  var menuBar: AnyObject?
  let result = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBar)

  guard result == .success,
    let menuBarElement = menuBar,
    CFGetTypeID(menuBarElement) == AXUIElementGetTypeID()
  else {
    print("Failed to get menu bar. AXError: \(result.rawValue)")
    return
  }

  let menuBarAXElement = menuBarElement as! AXUIElement
  let newWindowCommand = "New Window" as CFString
  let actionResult = AXUIElementPerformAction(menuBarAXElement, newWindowCommand)

  if actionResult == .success {
    print("Successfully created a new window")
  } else {
    print("Failed to create new window. AXError: \(actionResult.rawValue)")
  }
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

func openOrFocusApp(_ appPath: String) -> Int {
  let workspace = NSWorkspace.shared
  let fileManager = FileManager.default

  // Ensure the path exists and is an app bundle
  guard fileManager.fileExists(atPath: appPath),
    appPath.hasSuffix(".app")
  else {
    print("Invalid application path")
    return 404
  }

  let appURL = URL(fileURLWithPath: appPath)

  // Check if the app is already running
  if let runningApp = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleURL == appURL
  }
  ) {
    if !runningApp.isActive {
      runningApp.activate(options: .activateIgnoringOtherApps)
    }

    if runningApp.isActive {
      let windows = WindowManager.main.listWindows(for: runningApp)

      if windows.count == 0 {
        NSWorkspace.shared.openApplication(
          at: runningApp.bundleURL!,
          configuration: NSWorkspace.OpenConfiguration())

        return 201

      } else {
        return 202
      }
    }
  }

  NSWorkspace.shared.openApplication(
    at: appURL,
    configuration: NSWorkspace.OpenConfiguration())

  return 201
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
  let status = openOrFocusApp(appName)

  if status == 201 || status == 202 {
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

func cmdDameon() {
  puts("kbdcmd daemon started")
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
