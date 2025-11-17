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

@available(macOS 15.0, *)
public class WindowManager {
  public static let main = WindowManager()

  func getFrontmostApplication() async -> NSRunningApplication? {
    await AsyncWindowAPI.frontmostApplication()
  }

  func listWindows(for targetApp: NSRunningApplication? = nil) async -> [Window] {
    let windowsInfo = await AsyncWindowAPI.windowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements])

    var windows: [Window] = []

    for window in windowsInfo {
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

  public func cycleAppWindows() async {
    guard let frontmostApp = await getFrontmostApplication() else {
      print("Cannot get frontmost application")
      return
    }

    let axApp = AXUIElementCreateApplication(frontmostApp.processIdentifier)

    let axWindows = await AsyncWindowAPI.axWindowList(axApp)

    guard !axWindows.isEmpty else {
      print("Could not get Accessibility windows")
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
    await AsyncWindowAPI.activateWindow(nonMinimizedWindows.last!)
  }

  func createNewWindowViaMenu(for app: AXUIElement) -> Bool {
    // Get menu bar element
    var menuBar: AnyObject?
    guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBar) == .success,
      CFGetTypeID(menuBar) == AXUIElementGetTypeID()
    else {
      return false
    }

    let menuBarElement = menuBar as! AXUIElement

    // Get localized "File" menu name from system
    let localizedFileMenu = getLocalizedString(key: "File", tableName: "MenuCommands")

    // Determine which "New Window" menu item to look for
    // For Finder, we need to look for "New Finder Window" instead of just "New Window"
    var appIdentifier: String?
    var pid: pid_t = 0
    if AXUIElementGetPid(app, &pid) == .success,
      let runningApp = NSRunningApplication(processIdentifier: pid)
    {
      appIdentifier = runningApp.bundleIdentifier
    }

    let localizedNewWindow: String
    if appIdentifier == "com.apple.finder" {
      localizedNewWindow = getLocalizedString(key: "New Finder Window", tableName: "MenuCommands")
    } else {
      localizedNewWindow = getLocalizedString(key: "New Window", tableName: "MenuCommands")
    }

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
      return false
    }

    // Now traverse only within the File menu to find the appropriate New Window menu item
    let fileTree = AXTree(root: fileMenu)
    var foundItem: AXUIElement?

    fileTree.traverse { element, depth in
      // Search by exact menu title (e.g., "New Window" or similar)
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

  public func windowExists(windowId: CGWindowID) async -> Bool {
    let windowList = await AsyncWindowAPI.windowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements])

    return windowList.contains(where: {
      ($0[kCGWindowNumber as String] as? CGWindowID) == windowId
    })
  }

  public func windowExists(windowId: CGWindowID, appPath: String) async -> Bool {
    let windowList = await AsyncWindowAPI.windowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements])

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

  public func activateWindow(windowId: CGWindowID, includeMinimized: Bool = false) async -> Bool {
    debugLog("Activating window \(windowId), includeMinimized: \(includeMinimized)")

    // Get all windows from all apps
    let windowList = await AsyncWindowAPI.windowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements])

    // Find the window and get its pid
    guard let windowDict = windowList.first(where: {
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
    let axWindows = await AsyncWindowAPI.axWindowList(axApp)

    guard !axWindows.isEmpty else {
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
    await AsyncWindowAPI.activateWindow(targetWindow)

    // Activate the app
    debugLog("Activating app")
    await AsyncWindowAPI.activateApplication(app)

    debugLog("Window activation successful")
    return true
  }

  public func getFrontmostWindow() async -> CGWindowID? {
    guard let frontmostApp = await getFrontmostApplication() else {
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

  public func getWindowTitle(windowId: CGWindowID) async -> String? {
    let windowList = await AsyncWindowAPI.windowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements])

    guard let windowDict = windowList.first(where: {
        ($0[kCGWindowNumber as String] as? CGWindowID) == windowId
      }),
      let pid = windowDict[kCGWindowOwnerPID as String] as? pid_t
    else {
      return nil
    }

    let axApp = AXUIElementCreateApplication(pid)

    let axWindows = await AsyncWindowAPI.axWindowList(axApp)
    guard let targetWindow = axWindows.first(where: { $0.containingWindowId() == windowId })
    else {
      return nil
    }

    return targetWindow.get(Ax.titleAttr) ?? "Untitled"
  }

  /// Gets the path to the frontmost application
  public func getFrontmostAppPath() async -> String? {
    guard let frontmostApp = await AsyncWindowAPI.frontmostApplication(),
      let bundleURL = frontmostApp.bundleURL
    else {
      return nil
    }
    return bundleURL.path
  }

  /// Focuses a window and optionally hides the active overlay
  func focusWindow(_ windowInfo: WindowInfo, hideOverlay: Bool = true) async {
    guard let axWindow = windowInfo.axWindow else { return }

    if let app = NSRunningApplication(processIdentifier: windowInfo.pid) {
      await AsyncWindowAPI.activateApplication(app)
    }

    if windowInfo.isMinimized {
      axWindow.set(Ax.minimizedAttr, false)
    }

    await AsyncWindowAPI.activateWindow(axWindow)

    if hideOverlay {
      await Task.sleep(100_000_000) // 0.1 seconds
      await MainActor.run {
        OverlayManager.shared.hideActive()
      }
    }
  }

  /// Focuses an application and optionally hides the active overlay
  public func focusApp(pid: pid_t, hideOverlay: Bool = true) async {
    if let app = NSRunningApplication(processIdentifier: pid) {
      await AsyncWindowAPI.activateApplication(app)
    }

    if hideOverlay {
      await Task.sleep(100_000_000) // 0.1 seconds
      await MainActor.run {
        OverlayManager.shared.hideActive()
      }
    }
  }
}
