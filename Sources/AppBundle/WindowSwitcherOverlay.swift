import SwiftUI
import Cocoa
import Combine

class WindowSwitcherOverlay: NSObject {
  static let shared = WindowSwitcherOverlay()
  
  private var window: NSWindow?
  private var hostingView: NSHostingView<WindowSwitcherView>?
  private let windowChangePublisher = WindowChangePublisher()
  
  private override init() {
    super.init()
  }
  
  func show() {
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
  
  func hide() {
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
    
    axWindow.raise()
    
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
        
        ForEach(publisher.windowGroups) { group in
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
          .padding(.bottom, 8)
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
}
