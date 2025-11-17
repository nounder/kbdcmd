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

@MainActor
class WindowChangePublisher: ObservableObject {
  @Published var windowGroups: [AppWindowGroup] = []

  // Async tasks for monitoring
  private var workspaceMonitorTask: Task<Void, Never>?
  private var axObserverManager: AXMultiObserverStream?

  func startMonitoring() {
    Task {
      await refresh()
    }
    setupAsyncMonitoring()
  }

  func stopMonitoring() {
    workspaceMonitorTask?.cancel()
    workspaceMonitorTask = nil

    Task {
      await axObserverManager?.removeAllObservers()
      axObserverManager = nil
    }
  }

  private func refresh() async {
    // Perform heavy window querying on background task to avoid blocking main thread
    let groups = await Task.detached(priority: .userInitiated) {
      await self.getWindowGroups()
    }.value

    // Update @Published property on main actor
    self.windowGroups = groups
  }

  private func setupAsyncMonitoring() {
    // Setup workspace notification monitoring
    workspaceMonitorTask = Task { @MainActor in
      let stream = WorkspaceNotificationStream.applicationLifecycle()

      for await event in stream {
        debugLog("Workspace event: \(event.name.rawValue)")

        if event.isApplicationLaunched, let pid = event.processIdentifier {
          // Add AX observer for newly launched app
          await self.addAXObserver(for: pid)
        } else if event.isApplicationTerminated, let pid = event.processIdentifier {
          // Remove AX observer for terminated app
          await axObserverManager?.removeObserver(for: pid)
        }

        // Refresh window list for any workspace event
        await self.refresh()
      }
    }

    // Setup AX observer manager for window events
    Task {
      let manager = AXMultiObserverStream(
        notifications: [
          kAXWindowCreatedNotification as CFString,
          kAXUIElementDestroyedNotification as CFString,
          kAXWindowMiniaturizedNotification as CFString,
          kAXWindowDeminiaturizedNotification as CFString,
          kAXMovedNotification as CFString,
          kAXResizedNotification as CFString,
        ]
      ) { @Sendable [weak self] event in
        guard let self = self else { return }
        debugLog("AX event: \(event.notificationName)")

        // Refresh window list when window events occur
        await self.refresh()
      }

      self.axObserverManager = manager

      // Add observers for all currently running apps
      let runningApps = NSWorkspace.shared.runningApplications
      for app in runningApps where app.activationPolicy == .regular {
        await manager.addObserver(for: app.processIdentifier)
      }
    }
  }

  private func addAXObserver(for pid: pid_t) async {
    await axObserverManager?.addObserver(for: pid)
  }

  private func getWindowGroups() async -> [AppWindowGroup] {
    let runningApps = NSWorkspace.shared.runningApplications

    // Build z-index map asynchronously to avoid blocking
    let zIndexMap = await asyncWindowManager.getZIndexMapping()

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

}
