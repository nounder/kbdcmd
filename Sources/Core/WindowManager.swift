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

    let includeMinimized = UserDefaults.standard.bool(forKey: "includeMinimizedWindows")

    let windowsToCycle: [AXUIElement]
    if includeMinimized {
      windowsToCycle = axWindows
    } else {
      windowsToCycle = axWindows.filter {
        $0.get(Ax.minimizedAttr) != true
      }
    }

    if windowsToCycle.count <= 1 {
      return
    }

    let targetWindow = windowsToCycle.last!

    // Unminimize if needed
    if targetWindow.get(Ax.minimizedAttr) == true {
      targetWindow.set(Ax.minimizedAttr, false)
    }

    // Raise the last window to properly cycle through all windows
    // When raised, it becomes the frontmost, creating a rotation effect
    _ = targetWindow.raise()
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

      if let title = element.get(Ax.titleAttr), title == localizedFileMenu {
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
      if let itemTitle = element.get(Ax.titleAttr), itemTitle == localizedNewWindow {
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

  // MARK: - Window Move/Resize

  public enum Direction {
    case up, down, left, right
  }

  /// Returns the screen bounds that contain the given point, or the main screen bounds if not found
  private func screenBoundsContaining(point: CGPoint) -> CGRect {
    // Convert from Quartz coordinates (top-left origin) to screen coordinates
    guard let primaryScreen = NSScreen.screens.first else {
      return CGRect(x: 0, y: 0, width: 1920, height: 1080)
    }

    let primaryHeight = primaryScreen.frame.height

    for screen in NSScreen.screens {
      // NSScreen uses bottom-left origin, Quartz uses top-left
      // Convert screen frame to Quartz coordinates
      let screenFrame = screen.frame
      let quartzY = primaryHeight - screenFrame.maxY
      let quartzFrame = CGRect(
        x: screenFrame.minX,
        y: quartzY,
        width: screenFrame.width,
        height: screenFrame.height
      )

      if quartzFrame.contains(point) {
        // Return the visible frame (excludes menu bar and dock) in Quartz coordinates
        let visibleFrame = screen.visibleFrame
        let visibleQuartzY = primaryHeight - visibleFrame.maxY
        return CGRect(
          x: visibleFrame.minX,
          y: visibleQuartzY,
          width: visibleFrame.width,
          height: visibleFrame.height
        )
      }
    }

    // Fallback to primary screen's visible frame
    let visibleFrame = primaryScreen.visibleFrame
    let visibleQuartzY = primaryHeight - visibleFrame.maxY
    return CGRect(
      x: visibleFrame.minX,
      y: visibleQuartzY,
      width: visibleFrame.width,
      height: visibleFrame.height
    )
  }

  /// Moves the frontmost window in the given direction by the specified step (default 60px)
  /// Returns true if the window was moved, false if it couldn't be moved (at screen edge)
  @discardableResult
  public func moveFrontmostWindow(direction: Direction, step: CGFloat = 60) -> Bool {
    guard let frontmostApp = getFrontmostApplication() else {
      return false
    }

    let axApp = AXUIElementCreateApplication(frontmostApp.processIdentifier)
    guard let focusedWindow = axApp.get(Ax.focusedWindowAttr) else {
      return false
    }

    guard let currentPosition = focusedWindow.get(Ax.topLeftCornerAttr),
          let currentSize = focusedWindow.get(Ax.sizeAttr) else {
      return false
    }

    let screenBounds = screenBoundsContaining(point: currentPosition)

    var newPosition = currentPosition

    switch direction {
    case .up:
      newPosition.y -= step
    case .down:
      newPosition.y += step
    case .left:
      newPosition.x -= step
    case .right:
      newPosition.x += step
    }

    // Clamp to screen bounds
    // Left edge
    if newPosition.x < screenBounds.minX {
      newPosition.x = screenBounds.minX
    }
    // Right edge: window's right edge shouldn't exceed screen's right edge
    if newPosition.x + currentSize.width > screenBounds.maxX {
      newPosition.x = screenBounds.maxX - currentSize.width
    }
    // Top edge
    if newPosition.y < screenBounds.minY {
      newPosition.y = screenBounds.minY
    }
    // Bottom edge: window's bottom edge shouldn't exceed screen's bottom edge
    if newPosition.y + currentSize.height > screenBounds.maxY {
      newPosition.y = screenBounds.maxY - currentSize.height
    }

    // If position hasn't changed (already at edge), return false
    if newPosition.x == currentPosition.x && newPosition.y == currentPosition.y {
      return false
    }

    return focusedWindow.set(Ax.topLeftCornerAttr, newPosition)
  }

  /// Resizes the frontmost window in the given direction by the specified step (default 60px)
  /// Positive direction (right/down) increases size, negative direction (left/up) decreases size
  /// Returns true if the window was resized, false if it couldn't be resized (at screen edge or minimum size)
  @discardableResult
  public func resizeFrontmostWindow(direction: Direction, step: CGFloat = 60) -> Bool {
    guard let frontmostApp = getFrontmostApplication() else {
      return false
    }

    let axApp = AXUIElementCreateApplication(frontmostApp.processIdentifier)
    guard let focusedWindow = axApp.get(Ax.focusedWindowAttr) else {
      return false
    }

    guard let currentPosition = focusedWindow.get(Ax.topLeftCornerAttr),
          var currentSize = focusedWindow.get(Ax.sizeAttr) else {
      return false
    }

    let screenBounds = screenBoundsContaining(point: currentPosition)
    let minSize: CGFloat = 100  // Minimum window dimension

    switch direction {
    case .right:
      // Increase width
      let maxWidth = screenBounds.maxX - currentPosition.x
      currentSize.width = min(currentSize.width + step, maxWidth)
    case .left:
      // Decrease width
      currentSize.width = max(currentSize.width - step, minSize)
    case .down:
      // Increase height
      let maxHeight = screenBounds.maxY - currentPosition.y
      currentSize.height = min(currentSize.height + step, maxHeight)
    case .up:
      // Decrease height
      currentSize.height = max(currentSize.height - step, minSize)
    }

    return focusedWindow.set(Ax.sizeAttr, currentSize)
  }
}
