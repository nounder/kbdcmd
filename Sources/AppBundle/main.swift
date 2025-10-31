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

func getMenuBarItems(for app: AXUIElement) -> [AXUIElement]? {
  var menuBar: AnyObject?
  guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBar) == .success,
        CFGetTypeID(menuBar) == AXUIElementGetTypeID() else {
    return nil
  }
  
  let menuBarElement = menuBar as! AXUIElement
  return collectMenuItems(from: menuBarElement, maxDepth: 2)
}

func collectMenuItems(from element: AXUIElement, maxDepth: Int, currentDepth: Int = 0) -> [AXUIElement] {
  var result: [AXUIElement] = []
  
  guard currentDepth < maxDepth else {
    return result
  }
  
  var children: AnyObject?
  guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
        let childElements = children as? [AXUIElement] else {
    return result
  }
  
  for child in childElements {
    result.append(child)
    result.append(contentsOf: collectMenuItems(from: child, maxDepth: maxDepth, currentDepth: currentDepth + 1))
  }
  
  return result
}

func hasKeyboardShortcut(_ menuItem: AXUIElement, character: String, exactModifiers: Int) -> Bool {
  var cmdChar: AnyObject?
  var cmdMods: AnyObject?
  
  guard AXUIElementCopyAttributeValue(menuItem, kAXMenuItemCmdCharAttribute as CFString, &cmdChar) == .success,
        let cmdCharString = cmdChar as? String,
        cmdCharString.lowercased() == character.lowercased() else {
    return false
  }
  
  guard AXUIElementCopyAttributeValue(menuItem, kAXMenuItemCmdModifiersAttribute as CFString, &cmdMods) == .success,
        let itemModifiers = cmdMods as? Int else {
    return false
  }
  
  // Get title for debugging
  var title: AnyObject?
  let titleStr = AXUIElementCopyAttributeValue(menuItem, kAXTitleAttribute as CFString, &title) == .success ? (title as? String ?? "unknown") : "unknown"
  print("Menu item: '\(titleStr)', char: '\(cmdCharString)', modifiers: \(itemModifiers), expected: \(exactModifiers)")
  
  // Must match exactly - no extra modifiers allowed
  // Cmd only = 1, Cmd+Shift = 3, Cmd+Option = 5, Cmd+Control = 9
  // We need strict equality to avoid matching Cmd+Shift+N when looking for Cmd+N
  return itemModifiers == exactModifiers
}

func createNewWindowViaMenu(for app: AXUIElement) -> Bool {
  guard let menuItems = getMenuBarItems(for: app) else {
    print("DEBUG: Could not get menu items")
    return false
  }
  
  print("DEBUG: Got \(menuItems.count) menu items")
  
  // Get localized "File" menu name from system
  let localizedFileMenu = getLocalizedString(key: "File", tableName: "MenuCommands")
  let localizedNewWindow = getLocalizedString(key: "New Window", tableName: "MenuCommands")
  
  print("DEBUG: Looking for File menu: '\(localizedFileMenu)', New Window: '\(localizedNewWindow)'")
  
  for menuItem in menuItems {
    // First try: Look for Cmd+N keyboard shortcut (most reliable, language-independent)
    // Note: modifiers value 0 means Cmd only, 1 means Cmd+Shift
    // We want ONLY Cmd (value = 0), not Cmd+Shift (value = 1)
    if hasKeyboardShortcut(menuItem, character: "n", exactModifiers: 0) {
      print("DEBUG: Found matching shortcut, performing action")
      return AXUIElementPerformAction(menuItem, kAXPressAction as CFString) == .success
    }
    
    // Second try: Check if this is in File menu and has exact "New Window" title
    var itemTitle: AnyObject?
    if AXUIElementCopyAttributeValue(menuItem, kAXTitleAttribute as CFString, &itemTitle) == .success,
       let itemTitleString = itemTitle as? String,
       itemTitleString == localizedNewWindow {
      var parent: AnyObject?
      if AXUIElementCopyAttributeValue(menuItem, kAXParentAttribute as CFString, &parent) == .success,
         CFGetTypeID(parent) == AXUIElementGetTypeID() {
        let parentElement = parent as! AXUIElement
        var parentTitle: AnyObject?
        if AXUIElementCopyAttributeValue(parentElement, kAXTitleAttribute as CFString, &parentTitle) == .success,
           let parentTitleString = parentTitle as? String,
           parentTitleString == localizedFileMenu {
          return AXUIElementPerformAction(menuItem, kAXPressAction as CFString) == .success
        }
      }
    }
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
