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

@available(macOS 15.0, *)
@MainActor
class WindowChangePublisher: ObservableObject {
  @Published var windowGroups: [AppWindowGroup] = []

  private var monitoringTask: Task<Void, Never>?
  private var workspaceObservers: [NSObjectProtocol] = []

  func startMonitoring() {
    Task {
      await refresh()
    }
    setupWorkspaceNotifications()
    setupAccessibilityObservers()
  }

  func stopMonitoring() {
    monitoringTask?.cancel()
    removeWorkspaceNotifications()
  }

  private func refresh() async {
    // Perform heavy window querying on background task to avoid blocking main thread
    let groups = await getWindowGroups()

    // Update @Published property (already on main actor)
    self.windowGroups = groups
  }

  private func setupWorkspaceNotifications() {
    let notifications: [NSNotification.Name] = [
      NSWorkspace.didActivateApplicationNotification,
      NSWorkspace.didLaunchApplicationNotification,
      NSWorkspace.didTerminateApplicationNotification,
    ]

    for name in notifications {
      let observer = NotificationCenter.default.addObserver(
        forName: name,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          await self?.refresh()
        }
      }
      workspaceObservers.append(observer)
    }
  }

  private func removeWorkspaceNotifications() {
    for observer in workspaceObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    workspaceObservers.removeAll()
  }

  private func setupAccessibilityObservers() {
    monitoringTask?.cancel()

    monitoringTask = Task { @MainActor [weak self] in
      guard let self = self else { return }

      let runningApps = NSWorkspace.shared.runningApplications

      // Create array of AsyncStreams for each app
      await withTaskGroup(of: Void.self) { group in
        for app in runningApps {
          guard app.activationPolicy == .regular else { continue }

          group.addTask { @MainActor [weak self] in
            let notifications = [
              kAXWindowCreatedNotification as String,
              kAXUIElementDestroyedNotification as String,
              kAXWindowMiniaturizedNotification as String,
              kAXWindowDeminiaturizedNotification as String,
              kAXMovedNotification as String,
              kAXResizedNotification as String,
            ]

            let stream = AsyncStreamUtils.axObserverStream(
              pid: app.processIdentifier,
              notifications: notifications
            )

            for await _ in stream {
              await self?.refresh()
            }
          }
        }
      }
    }
  }

  private func getWindowGroups() async -> [AppWindowGroup] {
    let runningApps = NSWorkspace.shared.runningApplications

    // Build z-index map from CGWindowListCopyWindowInfo (returns windows in front-to-back order)
    let zIndexMap = await buildZIndexMap()

    var groupedWindows: [String: [WindowInfo]] = [:]

    for app in runningApps {
      guard let appName = app.localizedName,
        app.activationPolicy == .regular
      else {
        continue
      }

      let appIcon = app.icon
      let axApp = AXUIElementCreateApplication(app.processIdentifier)

      let axWindows = await AsyncWindowAPI.axWindowList(axApp)

      guard !axWindows.isEmpty else {
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

  private func buildZIndexMap() async -> [CGWindowID: Int] {
    var zIndexMap: [CGWindowID: Int] = [:]

    let windowList = await AsyncWindowAPI.windowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements])

    // Windows are returned in front-to-back order, so index 0 is topmost
    for (index, windowDict) in windowList.enumerated() {
      if let windowId = windowDict[kCGWindowNumber as String] as? CGWindowID {
        zIndexMap[windowId] = index
      }
    }

    return zIndexMap
  }
}
