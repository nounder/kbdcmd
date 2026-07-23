import AppKit

public enum WindowFinder {
  public static func isStandardWindow(_ axWindow: AXUIElement) -> Bool {
    guard axWindow.containingWindowId() != nil else { return false }

    if let role = axWindow.get(Ax.roleAttr), role != "AXWindow" {
      return false
    }

    if let subrole = axWindow.get(Ax.subroleAttr),
      ["AXSystemDialog", "AXDialog", "AXUnknown"].contains(subrole)
    {
      return false
    }

    guard let size = axWindow.get(Ax.sizeAttr) else { return false }
    if size.width < 100 || size.height < 100 {
      return false
    }

    return true
  }

  public static func standardWindows(of app: NSRunningApplication) -> [AXUIElement] {
    guard app.activationPolicy == .regular else { return [] }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    guard let axWindows = axApp.get(Ax.windowsAttr) else { return [] }
    return axWindows.filter(isStandardWindow)
  }

  public static func findWindowAndApp(app appFilter: String) -> (
    window: AXUIElement, app: NSRunningApplication
  )? {
    for app in NSWorkspace.shared.runningApplications {
      guard let appName = app.localizedName, app.activationPolicy == .regular else { continue }

      let nameMatches = appName.localizedCaseInsensitiveContains(appFilter)
      let bundleIdMatches =
        app.bundleIdentifier?.localizedCaseInsensitiveContains(appFilter) ?? false
      guard nameMatches || bundleIdMatches else { continue }

      if let window = standardWindows(of: app).first(where: isActivatable) {
        return (window, app)
      }
    }
    return nil
  }

  public static func findWindowAndApp(title titleFilter: String) -> (
    window: AXUIElement, app: NSRunningApplication
  )? {
    for app in NSWorkspace.shared.runningApplications {
      guard app.activationPolicy == .regular else { continue }

      let match = standardWindows(of: app).first {
        !($0.get(Ax.minimizedAttr) ?? false)
          && ($0.get(Ax.titleAttr) ?? "").localizedCaseInsensitiveContains(titleFilter)
      }
      if let window = match {
        return (window, app)
      }
    }
    return nil
  }

  public static func findWindowAndApp(pid: pid_t) -> (
    window: AXUIElement, app: NSRunningApplication
  )? {
    guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
    guard let window = standardWindows(of: app).first(where: isActivatable) else { return nil }
    return (window, app)
  }

  public static func findWindowAndApp(cgid: CGWindowID) -> (
    window: AXUIElement, app: NSRunningApplication
  )? {
    for app in NSWorkspace.shared.runningApplications {
      guard app.activationPolicy == .regular else { continue }

      let axApp = AXUIElementCreateApplication(app.processIdentifier)
      guard let axWindows = axApp.get(Ax.windowsAttr) else { continue }

      if let window = axWindows.first(where: { $0.containingWindowId() == cgid }) {
        return (window, app)
      }
    }
    return nil
  }

  private static func isActivatable(_ window: AXUIElement) -> Bool {
    !(window.get(Ax.minimizedAttr) ?? false) && !(window.get(Ax.titleAttr) ?? "").isEmpty
  }
}
