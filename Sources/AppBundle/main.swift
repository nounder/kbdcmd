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

  for axWindow in nonMinimizedWindows[1...].reversed() {
    axWindow.raise()
  }
}

func createNewWindowViaMenu(for app: AXUIElement) -> Bool {
  var menuBar: AnyObject?
  guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBar) == .success,
        CFGetTypeID(menuBar) == AXUIElementGetTypeID() else {
    return false
  }
  
  let menuBarElement = menuBar as! AXUIElement
  
  var children: AnyObject?
  guard AXUIElementCopyAttributeValue(menuBarElement, kAXChildrenAttribute as CFString, &children) == .success,
        let menuBarItems = children as? [AXUIElement] else {
    return false
  }
  
  for menuBarItem in menuBarItems {
    var title: AnyObject?
    guard AXUIElementCopyAttributeValue(menuBarItem, kAXTitleAttribute as CFString, &title) == .success,
          let titleString = title as? String,
          titleString == "File" else {
      continue
    }
    
    var menuChildren: AnyObject?
    guard AXUIElementCopyAttributeValue(menuBarItem, kAXChildrenAttribute as CFString, &menuChildren) == .success,
          let menus = menuChildren as? [AXUIElement],
          let fileMenu = menus.first else {
      continue
    }
    
    var menuItems: AnyObject?
    guard AXUIElementCopyAttributeValue(fileMenu, kAXChildrenAttribute as CFString, &menuItems) == .success,
          let items = menuItems as? [AXUIElement] else {
      continue
    }
    
    for item in items {
      var itemTitle: AnyObject?
      guard AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &itemTitle) == .success,
            let itemTitleString = itemTitle as? String,
            itemTitleString.contains("New Window") else {
        continue
      }
      
      return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }
    
    break
  }
  
  return false
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
        let bundleId = bundle.bundleIdentifier else {
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
          runningApp.activate(options: .activateIgnoringOtherApps)
          if createNewWindowViaMenu(for: axApp) {
            return .opened
          }
          return .opened
        }
      }
      
      // If app is already frontmost and has multiple windows, cycle through them
      if isAlreadyFrontmost && axWindows.count > 1 {
        let manager = WindowManager.main
        let appWindows = manager.listWindows().filter {
          $0.app.processIdentifier == runningApp.processIdentifier
        }
        
        if appWindows.count > 1 {
          for (i, _) in appWindows[1...].reversed().enumerated() {
            let ti = axWindows.count - i - 1
            let axWindow = axWindows[ti]
            
            if axWindow.get(Ax.minimizedAttr) == true {
              continue
            }
            
            axWindow.raise()
          }
          return .focused
        }
      }
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

  if result == .opened || result == .focused {
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
