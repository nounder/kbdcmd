import ApplicationServices
import Cocoa
import CoreGraphics

struct Window {
  var number: CGWindowID
  var pid: pid_t
  var app: NSRunningApplication
}

class WindowManager {
  static let main = WindowManager()

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

}
