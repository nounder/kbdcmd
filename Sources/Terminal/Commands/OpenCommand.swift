import AppKit
import ArgumentParser
import Core
import Foundation

struct OpenCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "open",
    abstract: "Open or focus an application"
  )

  @Argument(help: "Application name or path (e.g., Safari or /Applications/Safari.app)")
  var appPath: String

  func run() async throws {
    try Permissions.checkAccessibility()

    let fileManager = FileManager.default

    // Check if it's a path (contains / or .)
    let isPath = appPath.contains("/") || appPath.hasPrefix(".")

    let resolvedPath: String
    if isPath {
      // Treat as a path - resolve relative paths and check existence
      let fullPath =
        appPath.hasPrefix("/")
        ? appPath
        : (fileManager.currentDirectoryPath as NSString).appendingPathComponent(appPath)

      if !fileManager.fileExists(atPath: fullPath) {
        print("No application at \(appPath)")
        return
      }
      resolvedPath = fullPath
    } else {
      // Treat as app name - first check cwd, then search standard locations
      let cwdPath = (fileManager.currentDirectoryPath as NSString).appendingPathComponent(
        appPath.hasSuffix(".app") ? appPath : "\(appPath).app")

      if fileManager.fileExists(atPath: cwdPath) {
        resolvedPath = cwdPath
      } else if let path = ApplicationManager.resolve(appPath) {
        resolvedPath = path
      } else {
        print("Could not find application '\(appPath)'")
        return
      }
    }

    // Validate it's an app bundle
    guard resolvedPath.hasSuffix(".app") else {
      print("Not an application bundle: \(appPath)")
      return
    }

    let appURL = URL(fileURLWithPath: resolvedPath)

    // Check if app is already running
    if let bundle = Bundle(url: appURL),
      let bundleId = bundle.bundleIdentifier,
      let runningApp = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == bundleId
      })
    {
      let axApp = AXUIElementCreateApplication(runningApp.processIdentifier)

      var axValue: AnyObject?
      let result = AXUIElementCopyAttributeValue(
        axApp, kAXWindowsAttribute as CFString, &axValue)

      if result == .success, let axWindows = axValue as? [AXUIElement] {
        // Filter out windows without a valid windowId (e.g., Finder's desktop which is AXScrollArea)
        let realWindows = axWindows.filter { $0.containingWindowId() != nil }
        let hasNonMinimizedWindow = realWindows.contains { $0.get(Ax.minimizedAttr) != true }

        if !hasNonMinimizedWindow {
          // No visible windows - try to create a new window via menu
          if WindowManager.main.createNewWindowViaMenu(for: axApp) {
            runningApp.activate()
          } else {
            // If menu approach failed, activate and re-open the app
            runningApp.activate()
            let config = NSWorkspace.OpenConfiguration()
            try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
          }
          return
        }
      }

      runningApp.activate()
    } else {
      // Launch the app
      let config = NSWorkspace.OpenConfiguration()
      try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
    }
  }
}
