import Cocoa
import Combine
import SwiftUI

public class WindowSwitcherOverlay: NSObject {
  public static let shared = WindowSwitcherOverlay()

  private var window: NSWindow?
  private var hostingView: NSHostingView<WindowSwitcherView>?
  private let windowChangePublisher = WindowChangePublisher()

  public var isVisible: Bool {
    return window != nil
  }

  private override init() {
    super.init()
  }

  public func show() {
    guard window == nil else {
      window?.orderFrontRegardless()
      return
    }

    let contentView = WindowSwitcherView(publisher: windowChangePublisher)
    let hostingView = NSHostingView(rootView: contentView)

    guard let screen = NSScreen.main else { return }
    let screenFrame = screen.visibleFrame

    let windowWidth: CGFloat = 400
    let windowHeight = screenFrame.height
    let windowX = screenFrame.maxX - windowWidth
    let windowY = screenFrame.minY

    let window = NSWindow(
      contentRect: NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    window.contentView = hostingView
    window.backgroundColor = .clear
    window.isOpaque = false
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.ignoresMouseEvents = false
    window.orderFrontRegardless()

    self.window = window
    self.hostingView = hostingView

    startObservingWindowChanges()
  }

  public func hide() {
    stopObservingWindowChanges()
    window?.orderOut(nil)
    window = nil
    hostingView = nil
  }

  private func startObservingWindowChanges() {
    windowChangePublisher.startMonitoring()
  }

  private func stopObservingWindowChanges() {
    windowChangePublisher.stopMonitoring()
  }

  static func focusWindow(_ windowInfo: WindowInfo) {
    guard let axWindow = windowInfo.axWindow else { return }

    let app = NSRunningApplication(processIdentifier: windowInfo.pid)
    app?.activate(options: .activateIgnoringOtherApps)

    if windowInfo.isMinimized {
      axWindow.set(Ax.minimizedAttr, false)
    }

    _ = axWindow.raise()

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      WindowSwitcherOverlay.shared.hide()
    }
  }

  static func focusApp(pid: pid_t) {
    let app = NSRunningApplication(processIdentifier: pid)
    app?.activate(options: .activateIgnoringOtherApps)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      WindowSwitcherOverlay.shared.hide()
    }
  }

  public static func getFrontmostAppPath() -> String? {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
          let bundleURL = frontmostApp.bundleURL else {
      return nil
    }
    return bundleURL.path
  }
}

struct WindowSwitcherView: View {
  @ObservedObject var publisher: WindowChangePublisher
  @State private var hoveredAppName: String?
  @State private var hoveredWindowId: CGWindowID?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Open Windows")
          .font(.title2)
          .fontWeight(.bold)
          .foregroundColor(.white)
          .padding(.bottom, 8)

        // Show all apps with keybinding assignments (even if not running)
        ForEach(getAllAppsWithKeybindings(), id: \.appPath) { appEntry in
          appSectionView(for: appEntry)
        }

        // Show running apps without keybindings
        ForEach(publisher.windowGroups.filter { group in
          !hasKeybinding(for: group)
        }) { group in
          runningAppView(for: group)
        }
      }
      .padding(20)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color.black.opacity(0.85))
        .shadow(color: .black.opacity(0.5), radius: 20, x: -5, y: 0)
    )
    .padding(8)
  }

  struct AppEntry {
    let appPath: String
    let appName: String
    let keybinding: Character
    let group: AppWindowGroup?
    let icon: NSImage?
  }

  private func getAllAppsWithKeybindings() -> [AppEntry] {
    let keybindings = Keybindings.shared.getAppKeybindings()
    
    return keybindings.map { letter, appPath in
      let appName = (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
      let group = publisher.windowGroups.first { $0.appName == appName }
      
      // Load icon even if app is not running
      let icon: NSImage? = {
        if let group = group, let groupIcon = group.appIcon {
          return groupIcon
        }
        // App not running, try to load icon from bundle path
        return NSWorkspace.shared.icon(forFile: appPath)
      }()
      
      return AppEntry(
        appPath: appPath,
        appName: appName,
        keybinding: letter,
        group: group,
        icon: icon
      )
    }.sorted { $0.keybinding < $1.keybinding }
  }

  private func hasKeybinding(for group: AppWindowGroup) -> Bool {
    let keybindings = Keybindings.shared.getAppKeybindings()
    return keybindings.values.contains { appPath in
      let appName = (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
      return appName == group.appName
    }
  }

  private func appSectionView(for appEntry: AppEntry) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Button(action: {
        if let group = appEntry.group {
          WindowSwitcherOverlay.focusApp(pid: group.pid)
        } else {
          // App is not running, try to open it
          _ = try? ApplicationManager.openOrFocus(appEntry.appPath)
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            WindowSwitcherOverlay.shared.hide()
          }
        }
      }) {
        HStack(spacing: 8) {
          if let icon = appEntry.icon {
            Image(nsImage: icon)
              .resizable()
              .frame(width: 24, height: 24)
          } else {
            // Show placeholder icon if we couldn't load the icon
            Image(systemName: "app")
              .resizable()
              .frame(width: 24, height: 24)
              .foregroundColor(.white.opacity(0.5))
          }

          Text(appEntry.appName)
            .font(.headline)
            .foregroundColor(appEntry.group != nil ? .white : .white.opacity(0.6))

          Spacer()

          KeyboardKeyView(letter: String(appEntry.keybinding))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(hoveredAppName == appEntry.appName ? Color.white.opacity(0.2) : Color.clear)
        )
      }
      .buttonStyle(PlainButtonStyle())
      .onHover { isHovered in
        hoveredAppName = isHovered ? appEntry.appName : nil
      }
      .padding(.bottom, 4)

      if let group = appEntry.group {
        ForEach(group.windows) { window in
          windowView(for: window)
        }
      }
    }
    .padding(.bottom, 8)
  }

  private func runningAppView(for group: AppWindowGroup) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Button(action: {
        WindowSwitcherOverlay.focusApp(pid: group.pid)
      }) {
        HStack(spacing: 8) {
          if let icon = group.appIcon {
            Image(nsImage: icon)
              .resizable()
              .frame(width: 24, height: 24)
          }

          Text(group.appName)
            .font(.headline)
            .foregroundColor(.white)

          Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(hoveredAppName == group.appName ? Color.white.opacity(0.2) : Color.clear)
        )
      }
      .buttonStyle(PlainButtonStyle())
      .onHover { isHovered in
        hoveredAppName = isHovered ? group.appName : nil
      }
      .padding(.bottom, 4)

      ForEach(group.windows) { window in
        windowView(for: window)
      }
    }
    .padding(.bottom, 8)
  }

  private func windowView(for window: WindowInfo) -> some View {
    Button(action: {
      WindowSwitcherOverlay.focusWindow(window)
    }) {
      HStack(spacing: 8) {
        Circle()
          .fill(window.isMinimized ? Color.yellow.opacity(0.7) : Color.white.opacity(0.5))
          .frame(width: 6, height: 6)

        Text(window.title)
          .font(.body)
          .foregroundColor(window.isMinimized ? .white.opacity(0.6) : .white.opacity(0.9))
          .lineLimit(2)

        if window.isMinimized {
          Text("(minimized)")
            .font(.caption)
            .foregroundColor(.yellow.opacity(0.8))
            .italic()
        }

        Spacer()

        // Show keybinding if this window has one
        if let keybinding = Keybindings.shared.getKeybindingForWindow(window.windowNumber) {
          KeyboardKeyView(letter: String(keybinding))
        }
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 8)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(hoveredWindowId == window.id ? Color.white.opacity(0.15) : Color.clear)
      )
    }
    .buttonStyle(PlainButtonStyle())
    .onHover { isHovered in
      hoveredWindowId = isHovered ? window.id : nil
    }
    .padding(.leading, 24)
  }
}

struct KeyboardKeyView: View {
  let letter: String

  var body: some View {
    Text(letter.uppercased())
      .font(.system(size: 12, weight: .semibold, design: .monospaced))
      .foregroundColor(.white)
      .frame(width: 24, height: 24)
      .background(
        RoundedRectangle(cornerRadius: 4)
          .fill(
            LinearGradient(
              gradient: Gradient(colors: [
                Color(white: 0.3),
                Color(white: 0.2)
              ]),
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .overlay(
            RoundedRectangle(cornerRadius: 4)
              .stroke(Color.white.opacity(0.2), lineWidth: 1)
          )
          .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 2)
      )
  }
}

