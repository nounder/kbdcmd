import ApplicationServices
import Cocoa
import Foundation

public enum ApplicationOpenResult {
  case invalidPath
  case opened
  case focused
}

public struct ApplicationManager {
  public static func resolve(_ appName: String) -> String? {
    let fileManager = FileManager.default

    let normalizedName = appName.hasSuffix(".app") ? appName : "\(appName).app"

    let searchPaths = [
      "/Applications",
      fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
    ]

    for searchPath in searchPaths {
      let appPath = (searchPath as NSString).appendingPathComponent(normalizedName)

      guard fileManager.fileExists(atPath: appPath) else {
        continue
      }
      let appURL = URL(fileURLWithPath: appPath)

      // Check if it's a valid bundle and has an executable
      guard let bundle = Bundle(url: appURL),
        bundle.bundleIdentifier != nil,
        let executablePath = bundle.executablePath,
        fileManager.isExecutableFile(atPath: executablePath)
      else {
        continue
      }

      return appPath
    }

    return nil
  }

  public static func openOrFocus(_ appPath: String, ignoreMinimized: Bool = true) throws
    -> ApplicationOpenResult
  {
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
          // Filter out windows without a valid windowId (e.g., Finder's desktop which is AXScrollArea)
          // These are not real user-facing windows
          let realWindows = axWindows.filter { $0.containingWindowId() != nil }
          
          let hasNonMinimizedWindow = realWindows.contains { $0.get(Ax.minimizedAttr) != true }

          if !hasNonMinimizedWindow {
            // Try to create a new window via menu first without activating
            // This prevents focusing windows in other workspaces before the new window is created
            if WindowManager.main.createNewWindowViaMenu(for: axApp) {
              // Activate after creating the window to focus the newly created window
              runningApp.activate()
              return .opened
            }
            // If menu approach failed (no File > New Window), activate and re-open the app
            // This handles apps like Calendar that don't have File > New Window
            // Calling openApplication on an already-running app shows its window
            runningApp.activate()
            NSWorkspace.shared.openApplication(
              at: appURL,
              configuration: NSWorkspace.OpenConfiguration())
            return .opened
          }
        }

        // If app is already frontmost and has multiple windows, cycle through them
        // Filter out non-real windows (like Finder's desktop)
        let realWindows = axWindows.filter { $0.containingWindowId() != nil }
        
        if isAlreadyFrontmost && realWindows.count > 1 {
          let nonMinimizedWindows = realWindows.filter {
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
        runningApp.activate()
        return .focused
      }

      runningApp.activate()
      return .focused
    }

    NSWorkspace.shared.openApplication(
      at: appURL,
      configuration: NSWorkspace.OpenConfiguration())

    return .opened
  }
}
