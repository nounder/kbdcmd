import ApplicationServices
import Cocoa
import Foundation

enum ApplicationOpenResult {
  case invalidPath
  case opened
  case focused
}

struct ApplicationManager {
  static func openOrFocus(_ appPath: String, ignoreMinimized: Bool = true) throws
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
          let hasNonMinimizedWindow = axWindows.contains { $0.get(Ax.minimizedAttr) != true }

          if !hasNonMinimizedWindow {
            // Activate the app first to ensure any new window will be frontmost
            runningApp.activate(options: .activateIgnoringOtherApps)

            // First try to create a new window via menu (if File > New Window exists)
            if WindowManager.main.createNewWindowViaMenu(for: axApp) {
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
}
