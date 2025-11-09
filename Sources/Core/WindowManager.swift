import ApplicationServices
import Cocoa
import CoreGraphics
import Foundation

struct Window {
  var number: CGWindowID
  var pid: pid_t
  var app: NSRunningApplication
}

enum DesktopError: Error {
  case invalidDesktopNumber
}

public class WindowManager {
  public static let main = WindowManager()

  func getFrontmostApplication() -> NSRunningApplication? {
    return NSWorkspace.shared.frontmostApplication
  }

  func listWindows(for targetApp: NSRunningApplication? = nil) -> [Window] {
    let windowsInfo = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)

    var windows: [Window] = []

    for window in Array<NSDictionary>.fromCFArray(records: windowsInfo) ?? [] {
      guard let id = window[kCGWindowNumber as String] as? CGWindowID,
        let pid = window[kCGWindowOwnerPID as String] as? pid_t,
        let bounds = window[kCGWindowBounds] as? NSDictionary,
        let width = bounds["Width"] as? Double,
        let height = bounds["Height"] as? Double,
        let app = NSRunningApplication(processIdentifier: pid)
      else {
        continue
      }

      if targetApp != nil {
        if app.bundleIdentifier != targetApp!.bundleIdentifier {
          continue
        }
      }

      if app.bundleIdentifier == "com.apple.WindowManager" {
        continue
      }

      if width < 60 || height < 60 {
        continue
      }

      let window = Window(number: id, pid: pid, app: app)

      windows.append(window)
    }

    return windows
  }

  public func cycleAppWindows() {
    guard let frontmostApp = getFrontmostApplication() else {
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

  public func switchToDesktop(number: Int) throws {
    guard (1...9).contains(number) else {
      throw DesktopError.invalidDesktopNumber
    }

    // Simulate pressing the number key for the desired desktop
    let desktopKeyCode = CGKeyCode(0x12 + (number - 1))  // 0x12 is '1' key
    KeyboardSimulator.simulateKeyPress(keyCode: desktopKeyCode, flags: .maskControl)

    print("Switched to desktop \(number)")
  }

  private func getLocalizedString(key: String, tableName: String) -> String {
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

  public func windowExists(windowId: CGWindowID) -> Bool {
    let windowsInfo = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    
    guard let windowList = windowsInfo as? [[String: Any]] else {
      return false
    }
    
    return windowList.contains(where: {
      ($0[kCGWindowNumber as String] as? CGWindowID) == windowId
    })
  }

  public func windowExists(windowId: CGWindowID, appPath: String) -> Bool {
    let windowsInfo = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    
    guard let windowList = windowsInfo as? [[String: Any]] else {
      return false
    }
    
    return windowList.contains(where: { windowDict in
      guard let windowNumber = windowDict[kCGWindowNumber as String] as? CGWindowID,
            let pid = windowDict[kCGWindowOwnerPID as String] as? pid_t,
            let app = NSRunningApplication(processIdentifier: pid),
            let bundleURL = app.bundleURL
      else {
        return false
      }
      
      return windowNumber == windowId && bundleURL.path == appPath
    })
  }

  public func activateWindow(windowId: CGWindowID, includeMinimized: Bool = false) -> Bool {
    debugLog("Activating window \(windowId), includeMinimized: \(includeMinimized)")

    // Get all windows from all apps
    let windowsInfo = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)

    // Find the window and get its pid
    guard let windowList = windowsInfo as? [[String: Any]],
      let windowDict = windowList.first(where: {
        ($0[kCGWindowNumber as String] as? CGWindowID) == windowId
      }),
      let pid = windowDict[kCGWindowOwnerPID as String] as? pid_t,
      let app = NSRunningApplication(processIdentifier: pid)
    else {
      debugLog("Failed to find window \(windowId) in window list")
      return false
    }

    debugLog("Found window, pid: \(pid)")

    // Get AX element for the app
    let axApp = AXUIElementCreateApplication(pid)

    // Get all windows
    var axValue: AnyObject?
    guard
      AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axValue)
        == .success,
      let axWindows = axValue as? [AXUIElement]
    else {
      debugLog("Failed to get AX windows for pid \(pid)")
      return false
    }

    debugLog("Got \(axWindows.count) AX windows")

    // Find the specific window by CGWindowID
    guard
      let targetWindow = axWindows.first(where: {
        $0.containingWindowId() == windowId
      })
    else {
      debugLog("Failed to find window \(windowId) in AX windows")
      return false
    }

    // Check if window is minimized
    let isMinimized = targetWindow.get(Ax.minimizedAttr) == true
    debugLog("Window isMinimized: \(isMinimized)")

    // If includeMinimized is false and window is minimized, don't activate
    if !includeMinimized && isMinimized {
      debugLog("Skipping minimized window (includeMinimized=false)")
      return false
    }

    // De-minimize if needed (only if includeMinimized is true)
    if isMinimized && includeMinimized {
      debugLog("De-minimizing window")
      targetWindow.set(Ax.minimizedAttr, false)
    }

    // Raise window to front
    debugLog("Raising window to front")
    _ = targetWindow.raise()

    // Activate the app
    debugLog("Activating app")
    app.activate()

    debugLog("Window activation successful")
    return true
  }

  public func getFrontmostWindow() -> CGWindowID? {
    guard let frontmostApp = getFrontmostApplication() else {
      return nil
    }

    let axApp = AXUIElementCreateApplication(frontmostApp.processIdentifier)

    guard let focusedWindow = axApp.get(Ax.focusedWindowAttr),
      let windowId = focusedWindow.containingWindowId()
    else {
      return nil
    }

    return windowId
  }

  public func getWindowTitle(windowId: CGWindowID) -> String? {
    let windowsInfo = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)

    guard let windowList = windowsInfo as? [[String: Any]],
      let windowDict = windowList.first(where: {
        ($0[kCGWindowNumber as String] as? CGWindowID) == windowId
      }),
      let pid = windowDict[kCGWindowOwnerPID as String] as? pid_t
    else {
      return nil
    }

    let axApp = AXUIElementCreateApplication(pid)

    var axValue: AnyObject?
    guard
      AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axValue)
        == .success,
      let axWindows = axValue as? [AXUIElement],
      let targetWindow = axWindows.first(where: { $0.containingWindowId() == windowId })
    else {
      return nil
    }

    return targetWindow.get(Ax.titleAttr) ?? "Untitled"
  }

  /// Gets the path to the frontmost application
  public func getFrontmostAppPath() -> String? {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
      let bundleURL = frontmostApp.bundleURL
    else {
      return nil
    }
    return bundleURL.path
  }

  /// Focuses a window and optionally hides the active overlay
  func focusWindow(_ windowInfo: WindowInfo, hideOverlay: Bool = true) {
    guard let axWindow = windowInfo.axWindow else { return }

    let app = NSRunningApplication(processIdentifier: windowInfo.pid)
    app?.activate()

    if windowInfo.isMinimized {
      axWindow.set(Ax.minimizedAttr, false)
    }

    _ = axWindow.raise()

    if hideOverlay {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        OverlayManager.shared.hideActive()
      }
    }
  }

  /// Focuses an application and optionally hides the active overlay
  public func focusApp(pid: pid_t, hideOverlay: Bool = true) {
    let app = NSRunningApplication(processIdentifier: pid)
    app?.activate()

    if hideOverlay {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        OverlayManager.shared.hideActive()
      }
    }
  }
}
