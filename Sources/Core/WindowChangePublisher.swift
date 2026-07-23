import Cocoa
import Combine
import SwiftUI

struct WindowInfo: Identifiable {
  let id: CGWindowID
  let title: String
  let appName: String
  let appIcon: NSImage?
  let windowNumber: CGWindowID
  let isMinimized: Bool
  let pid: pid_t
  let axWindow: AXUIElement?
  let position: CGPoint?
  let size: CGSize?
  let zIndex: Int?
  let timestamp: Date
}

struct AppWindowGroup: Identifiable {
  let id: String
  let appName: String
  let appIcon: NSImage?
  let windows: [WindowInfo]
  let pid: pid_t
}

class WindowChangePublisher: ObservableObject {
  @Published var windowGroups: [AppWindowGroup] = []

  private var axObservers: [AXObserver] = []
  private var workspaceObservers: [NSObjectProtocol] = []
  private var refreshPending = false
  private let backgroundQueue = DispatchQueue(
    label: "com.kbdcmd.windowPublisher", qos: .userInitiated)

  func startMonitoring() {
    refreshNow()
    setupWorkspaceNotifications()
    setupAccessibilityObservers()
  }

  func stopMonitoring() {
    removeWorkspaceNotifications()
    removeAccessibilityObservers()
  }

  private func refresh() {
    guard !refreshPending else { return }
    refreshPending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self = self else { return }
      self.refreshPending = false
      self.refreshNow()
    }
  }

  private func refreshNow() {
    // Perform heavy window querying on background queue to avoid blocking main thread
    backgroundQueue.async { [weak self] in
      guard let self = self else { return }

      // Heavy work: query all apps, accessibility API, and window info
      let groups = self.getWindowGroups()

      // Update @Published property on main thread for UI binding
      DispatchQueue.main.async {
        self.windowGroups = groups
      }
    }
  }

  private func setupWorkspaceNotifications() {
    let notifications: [NSNotification.Name] = [
      NSWorkspace.didActivateApplicationNotification,
      NSWorkspace.didLaunchApplicationNotification,
      NSWorkspace.didTerminateApplicationNotification,
    ]

    for name in notifications {
      let observer = NSWorkspace.shared.notificationCenter.addObserver(
        forName: name,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        if name == NSWorkspace.didLaunchApplicationNotification,
          let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        {
          self?.addAccessibilityObserver(for: app)
        }
        self?.refresh()
      }
      workspaceObservers.append(observer)
    }
  }

  private func removeWorkspaceNotifications() {
    for observer in workspaceObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    workspaceObservers.removeAll()
  }

  private func setupAccessibilityObservers() {
    for app in NSWorkspace.shared.runningApplications {
      addAccessibilityObserver(for: app)
    }
  }

  private func addAccessibilityObserver(for app: NSRunningApplication) {
    guard app.activationPolicy == .regular else { return }

    var observer: AXObserver?
    let result = AXObserverCreate(
      app.processIdentifier,
      { (observer, element, notification, refcon) in
        let publisher = Unmanaged<WindowChangePublisher>.fromOpaque(refcon!).takeUnretainedValue()
        publisher.refresh()
      },
      &observer
    )

    guard result == .success, let observer = observer else {
      return
    }

    let appElement = AXUIElementCreateApplication(app.processIdentifier)

    let notifications = [
      kAXWindowCreatedNotification,
      kAXUIElementDestroyedNotification,
      kAXWindowMiniaturizedNotification,
      kAXWindowDeminiaturizedNotification,
    ]

    for notification in notifications {
      AXObserverAddNotification(
        observer,
        appElement,
        notification as CFString,
        Unmanaged.passUnretained(self).toOpaque()
      )
    }

    CFRunLoopAddSource(
      CFRunLoopGetCurrent(),
      AXObserverGetRunLoopSource(observer),
      .defaultMode
    )

    axObservers.append(observer)
  }

  private func removeAccessibilityObservers() {
    for observer in axObservers {
      CFRunLoopRemoveSource(
        CFRunLoopGetCurrent(),
        AXObserverGetRunLoopSource(observer),
        .defaultMode
      )
    }
    axObservers.removeAll()
  }

  private func getWindowGroups() -> [AppWindowGroup] {
    let runningApps = NSWorkspace.shared.runningApplications

    // Build z-index map from CGWindowListCopyWindowInfo (returns windows in front-to-back order)
    let zIndexMap = buildZIndexMap()

    var groupedWindows: [String: [WindowInfo]] = [:]

    for app in runningApps {
      guard let appName = app.localizedName,
        app.activationPolicy == .regular
      else {
        continue
      }

      let appIcon = app.icon
      let axApp = AXUIElementCreateApplication(app.processIdentifier)

      var axValue: AnyObject?
      let result = AXUIElementCopyAttributeValue(
        axApp, kAXWindowsAttribute as CFString, &axValue)

      guard result == .success, let axWindows = axValue as? [AXUIElement] else {
        continue
      }

      for axWindow in axWindows {
        guard let windowId = axWindow.containingWindowId() else {
          continue
        }

        // Filter out non-interactive windows
        let subrole = axWindow.get(Ax.subroleAttr)

        // Skip utility windows, system dialogs, and other non-standard windows
        if let subrole = subrole {
          let excludedSubroles = [
            "AXSystemDialog",
            "AXDialog",
            "AXUnknown",
          ]
          if excludedSubroles.contains(subrole) {
            continue
          }
        }

        // Get window role
        let role = axWindow.get(Ax.roleAttr)

        // Only include standard windows
        if let role = role, role != "AXWindow" {
          continue
        }

        // Get position and size
        let position = axWindow.get(Ax.topLeftCornerAttr)
        let size = axWindow.get(Ax.sizeAttr)

        // Check if window has a size (filter out invisible windows)
        guard let size = size else {
          continue
        }

        // Filter out very small windows (likely overlays or utility windows)
        if size.width < 100 || size.height < 100 {
          continue
        }

        let windowTitle = axWindow.get(Ax.titleAttr) ?? "Window \(windowId)"
        let isMinimized = axWindow.get(Ax.minimizedAttr) ?? false

        // Skip windows with empty titles that aren't minimized (likely overlays)
        // but keep minimized windows even if they have empty titles
        if windowTitle.isEmpty && !isMinimized {
          continue
        }

        let windowInfo = WindowInfo(
          id: windowId,
          title: windowTitle.isEmpty ? "Untitled" : windowTitle,
          appName: appName,
          appIcon: appIcon,
          windowNumber: windowId,
          isMinimized: isMinimized,
          pid: app.processIdentifier,
          axWindow: axWindow,
          position: position,
          size: size,
          zIndex: zIndexMap[windowId],
          timestamp: Date()
        )

        if groupedWindows[appName] == nil {
          groupedWindows[appName] = []
        }
        groupedWindows[appName]?.append(windowInfo)
      }
    }

    return groupedWindows.map { appName, windows in
      AppWindowGroup(
        id: appName,
        appName: appName,
        appIcon: windows.first?.appIcon,
        windows: windows.sorted {
          if $0.isMinimized != $1.isMinimized {
            return !$0.isMinimized
          }
          if let z0 = $0.zIndex, let z1 = $1.zIndex {
            return z0 < z1
          }
          return $0.title < $1.title
        },
        pid: windows.first?.pid ?? 0
      )
    }.sorted { $0.appName < $1.appName }
  }

  private func buildZIndexMap() -> [CGWindowID: Int] {
    var zIndexMap: [CGWindowID: Int] = [:]

    let windowsInfo = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)

    guard let windowList = windowsInfo as? [[String: Any]] else {
      return zIndexMap
    }

    // Windows are returned in front-to-back order, so index 0 is topmost
    for (index, windowDict) in windowList.enumerated() {
      if let windowId = windowDict[kCGWindowNumber as String] as? CGWindowID {
        zIndexMap[windowId] = index
      }
    }

    return zIndexMap
  }
}
