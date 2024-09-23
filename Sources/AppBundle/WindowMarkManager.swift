import ApplicationServices
import Cocoa
import CoreGraphics
import Foundation
import SwiftUI

class WindowMarkManager: ObservableObject {
  static let shared = WindowMarkManager()
  private let marksFilePath = "/tmp/kbdcmd-marks.json"
  @Published private var marks: [CGWindowID: String] = [:]

  private init() {
    loadMarks()
  }

  func markWindow() {
    guard let targetWindow = self.getForegroundWindow() else {
      print("No foreground window found")
      return
    }

    print("Marking window: \"\(targetWindow.title)\" (Application: \(targetWindow.appName))")

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let controller = NSHostingController(
      rootView: MarkInputView(
        onMark: { mark in
          self.setMark(mark, for: targetWindow.windowID)

          app.stop(nil)
        },
        onClose: {
          app.stop(nil)
        }))

    let markWindow = NSWindow(contentViewController: controller)
    markWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    markWindow.title = "Mark Window"
    markWindow.makeKeyAndOrderFront(nil)
    markWindow.center()

    app.activate(ignoringOtherApps: true)
    app.run()
    app.setActivationPolicy(.regular)
  }

  func focusMarkedWindow(mark: String) {
    guard let windowID = marks.first(where: { $0.value == mark })?.key else {
      print("No window marked with '\(mark)'")
      return
    }

    focusWindow(withID: windowID)
  }

  private func setMark(_ mark: String, for window: CGWindowID) {
    marks[window] = mark
    saveMarks()
    showConfirmation(mark: mark)
    focusWindow(withID: window)
  }

  private func loadMarks() {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: marksFilePath)),
      let loadedMarks = try? JSONDecoder().decode([CGWindowID: String].self, from: data)
    else {
      return
    }
    marks = loadedMarks
  }

  private func saveMarks() {
    guard let data = try? JSONEncoder().encode(marks) else { return }
    try? data.write(to: URL(fileURLWithPath: marksFilePath))
  }

  private func getForegroundWindow() -> (
    windowID: CGWindowID, ownerPID: pid_t, title: String, appName: String
  )? {
    // Try multiple methods to get the foreground window
    return getForegroundWindowUsingWorkspace() ?? getForegroundWindowUsingWindowList()
  }

  func getForegroundWindowUsingWorkspace() -> (
    windowID: CGWindowID, ownerPID: pid_t, title: String, appName: String
  )? {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
      print("No frontmost application found using NSWorkspace")
      return nil
    }

    let pid = frontmostApp.processIdentifier
    let appName = frontmostApp.localizedName ?? ""

    // Get window info for this application
    return getWindowInfoForPID(pid, appName: appName)
  }

  func getWindowsUsingWindowNumbers() {
    if let windowNumbers = NSWindow.windowNumbers(options: [.allSpaces, .allApplications]) {
      let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
      let windowListInfo =
        CGWindowListCopyWindowInfo(options, kCGNullWindowID) as NSArray? as? [[String: Any]]
        ?? []

      for windowInfo in windowListInfo {
        if let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
          let title = windowInfo[kCGWindowName as String] as? String,
          let appName = windowInfo[kCGWindowOwnerName as String] as? String,
          let pid = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
          let windowLayer = windowInfo[kCGWindowLayer as String] as? Int
        {
          print("Window Info:")
          print("  Window ID: \(windowID)")
          print("  Title: \(title.isEmpty ? "N/A" : title)")  // Print "N/A" if title is empty
          print("  App Name: \(appName.isEmpty ? "N/A" : appName)")  // Print "N/A" if appName is empty
          print("  Owner PID: \(pid)")  // PID can be -1, so no need for empty check
          print("  Window Layer: \(windowLayer)")  // Layer can be -1, so no need for empty check
        }
      }
    }
  }

  private func getForegroundWindowUsingWindowList() -> (
    windowID: CGWindowID, ownerPID: pid_t, title: String, appName: String
  )? {
    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
    let windowListInfo =
      CGWindowListCopyWindowInfo(options, kCGNullWindowID) as NSArray? as? [[String: Any]]
      ?? []

    for windowInfo in windowListInfo {
      let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID ?? 0
      let title = windowInfo[kCGWindowName as String] as? String ?? "N/A"
      let appName = windowInfo[kCGWindowOwnerName as String] as? String ?? "N/A"
      let pid = windowInfo[kCGWindowOwnerPID as String] as? pid_t ?? -1
      let windowLayer = windowInfo[kCGWindowLayer as String] as? Int ?? -1

      print("Window Info:")
      print("  Window ID: \(windowID)")
      print("  Title: \(title)")
      print("  App Name: \(appName)")
      print("  Owner PID: \(pid)")
      print("  Window Layer: \(windowLayer)")

      if let windowLayer = windowInfo[kCGWindowLayer as String] as? Int,
        windowLayer == 0,
        let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
        let pid = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
        let title = windowInfo[kCGWindowName as String] as? String,
        let appName = windowInfo[kCGWindowOwnerName as String] as? String
      {
        return (windowID, pid, title, appName)
      }
    }

    print("No foreground window found using window list")
    return nil
  }

  private func getWindowInfoForPID(_ pid: pid_t, appName: String) -> (
    windowID: CGWindowID, ownerPID: pid_t, title: String, appName: String
  )? {
    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
    let windowListInfo =
      CGWindowListCopyWindowInfo(options, kCGNullWindowID) as NSArray? as? [[String: Any]]
      ?? []

    for windowInfo in windowListInfo {
      if let windowPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
        windowPID == pid,
        let windowLayer = windowInfo[kCGWindowLayer as String] as? Int,
        windowLayer == 0,
        let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
        let title = windowInfo[kCGWindowName as String] as? String
      {
        return (windowID, pid, title, appName)
      }
    }

    print("No matching window found for PID: \(pid)")
    return nil
  }

  private func focusWindow(withID windowID: CGWindowID) {
    let windowList = CGWindowListCreateDescriptionFromArray([windowID] as CFArray) as NSArray?
    guard let windowInfo = windowList?.firstObject as? [CFString: Any],
      let pidNumber = windowInfo[kCGWindowOwnerPID] as? NSNumber,
      let app = NSRunningApplication(processIdentifier: pidNumber.int32Value)
    else {
      print("Failed to get window information or associated application")
      return
    }
    app.activate(options: .activateIgnoringOtherApps)
  }

  private func showConfirmation(mark: String) {
    let controller = NSHostingController(rootView: ConfirmationView(mark: mark))
    let confirmationWindow = NSWindow(contentViewController: controller)
    confirmationWindow.styleMask = [.borderless]
    confirmationWindow.backgroundColor = .clear
    confirmationWindow.isOpaque = false
    confirmationWindow.level = .floating
    confirmationWindow.makeKeyAndOrderFront(nil)
    confirmationWindow.center()

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      confirmationWindow.close()
    }
  }

  // MARK: - Accessibility API Method

  /// Retrieves the frontmost application using Accessibility APIs.
  func getFrontmostAppUsingAccessibility() -> NSRunningApplication? {
    print("ismain", Thread.isMainThread)
    let systemWideElement = AXUIElementCreateSystemWide()
    var frontApp: AnyObject?
    let result = AXUIElementCopyAttributeValue(
      systemWideElement, kAXFocusedApplicationAttribute as CFString, &frontApp)

    print(result.rawValue)

    guard result == .success else {
      print("Failed to retrieve front app using Accessibility APIs.")
      return nil
    }

    var pid: pid_t = 0
    AXUIElementGetPid(frontApp as! AXUIElement, &pid)

    return NSRunningApplication(processIdentifier: pid)
  }

  // MARK: - Core Graphics Window Services Method

  /// Retrieves the frontmost application using Core Graphics Window Services.
  func getFrontmostAppUsingCGWindow() -> NSRunningApplication? {
    let options = CGWindowListOption(
      arrayLiteral: .optionOnScreenOnly, .optionIncludingWindow)
    guard
      let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as NSArray?
        as? [[String: Any]]
    else {
      print("Failed to retrieve window list using Core Graphics.")
      return nil
    }

    // Iterate through windows to find the topmost window (usually layer 0)
    for (index, window) in windowList.enumerated() {
      for (key, value) in window {
        print("CGWindow [\(index)]: \(key): \(value)")
      }
      if let windowLayer = window[kCGWindowLayer as String] as? Int, windowLayer == 0,
        let pid = window[kCGWindowOwnerPID as String] as? pid_t
      {
        return NSRunningApplication(processIdentifier: pid)
      }
    }

    print("No frontmost application found using Core Graphics.")
    return nil
  }

  // MARK: - AppleScript Integration Method

  /// Retrieves the frontmost application using AppleScript.
  func getFrontmostAppUsingAppleScript() -> NSRunningApplication? {
    let script = """
      tell application "System Events"
          set frontApp to name of first application process whose frontmost is true
      end tell
      frontApp
      """

    var error: NSDictionary?
    if let appleScript = NSAppleScript(source: script),
      let output = appleScript.executeAndReturnError(&error).stringValue
    {
      print("AppleScript output: \(output)")
      // TODO: This probly doesn't work
      return NSRunningApplication.runningApplications(withBundleIdentifier: output).first
    } else {
      if let error = error {
        print("AppleScript error: \(error)")
      }
      return nil
    }
  }

}

struct MarkInputView: View {
  @State private var mark: String = ""
  @FocusState private var isInputFocused: Bool
  let onMark: (String) -> Void
  let onClose: () -> Void

  var body: some View {
    VStack {
      Text("Enter a single character mark:")
      TextField("Mark", text: $mark)
        .textFieldStyle(RoundedBorderTextFieldStyle())
        .frame(width: 50)
        .focused($isInputFocused)
        .onChange(of: mark) { newValue in
          if newValue.count == 1 {
            onMark(newValue)
          }
        }
    }
    .padding()
    .frame(width: 250, height: 100)
    .onAppear {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self.isInputFocused = true
      }
    }
    .onDisappear {
      onClose()
    }
  }
}

struct ConfirmationView: View {
  let mark: String

  var body: some View {
    Text("Marked as \(mark)")
      .padding()
      .background(Color.black.opacity(0.7))
      .foregroundColor(.white)
      .cornerRadius(10)
  }
}
