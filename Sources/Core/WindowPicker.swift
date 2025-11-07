import ApplicationServices
import Cocoa
import CoreGraphics
import Foundation
import SwiftUI

/// Window information for picker
public struct PickerWindowInfo: Identifiable {
    public let id: CGWindowID
    public let windowId: CGWindowID
    public let pid: pid_t
    public let bounds: CGRect  // In CGWindow space: top-left origin, Y increases downward
    public let title: String?
    public let appName: String?
    public let axElement: AXUIElement?

    public init(
        windowId: CGWindowID,
        pid: pid_t,
        bounds: CGRect,
        title: String?,
        appName: String?,
        axElement: AXUIElement?
    ) {
        self.id = windowId
        self.windowId = windowId
        self.pid = pid
        self.bounds = bounds
        self.title = title
        self.appName = appName
        self.axElement = axElement
    }
}

/// Picker for selecting a window interactively with visual highlighting
public class WindowPicker {
    private var overlayWindow: NSWindow?
    private var highlightState: WindowHighlightState?
    private var selectedWindow: PickerWindowInfo?
    private var completion: ((PickerWindowInfo?) -> Void)?
    private var mouseTrackingTimer: Timer?
    private var allWindows: [PickerWindowInfo] = []

    public init() {}

    /// Shows the window picker overlay and returns the selected window via completion handler
    public func pickWindow(completion: @escaping (PickerWindowInfo?) -> Void) {
        self.completion = completion

        // Collect all windows
        allWindows = collectAllWindows()

        // Create overlay covering all screens
        createOverlay()

        // Start mouse tracking
        startMouseTracking()
    }

    /// Cancels the window picker
    public func cancel() {
        cleanup()
        completion?(nil)
    }

    /// Converts a PickerWindowInfo to an AXUIElement
    public static func getAXWindow(from windowInfo: PickerWindowInfo) -> AXUIElement? {
        if let element = windowInfo.axElement {
            return element
        }

        let axApp = AXUIElementCreateApplication(windowInfo.pid)

        var axValue: AnyObject?
        guard
            AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axValue)
                == .success,
            let axWindows = axValue as? [AXUIElement]
        else {
            return nil
        }

        return axWindows.first(where: { $0.containingWindowId() == windowInfo.windowId })
    }

    // MARK: - Private Methods

    private func collectAllWindows() -> [PickerWindowInfo] {
        let windowsInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)

        var windows: [PickerWindowInfo] = []

        guard let windowList = windowsInfo as? [[String: Any]] else {
            return windows
        }

        for windowDict in windowList {
            guard let id = windowDict[kCGWindowNumber as String] as? CGWindowID,
                let pid = windowDict[kCGWindowOwnerPID as String] as? pid_t,
                let boundsDict = windowDict[kCGWindowBounds as String] as? NSDictionary,
                let x = boundsDict["X"] as? Double,
                let y = boundsDict["Y"] as? Double,
                let width = boundsDict["Width"] as? Double,
                let height = boundsDict["Height"] as? Double,
                let app = NSRunningApplication(processIdentifier: pid)
            else {
                continue
            }

            // Skip system windows
            if app.bundleIdentifier == "com.apple.WindowManager" {
                continue
            }

            // Skip very small windows (likely overlays or utility windows)
            // Use same threshold as WindowChangePublisher
            if width < 100 || height < 100 {
                continue
            }

            // Skip semi-transparent windows (likely overlays)
            if let alpha = windowDict[kCGWindowAlpha as String] as? Double,
                alpha < 0.9
            {
                continue
            }

            // Skip windows with layer > 0 (non-standard windows, overlays)
            if let layer = windowDict[kCGWindowLayer as String] as? Int,
                layer > 0
            {
                continue
            }

            // Store bounds in CGWindow coordinate space (top-left origin, Y increases downward)
            // This matches how HintOverlay stores element.frame
            let bounds = CGRect(x: x, y: y, width: width, height: height)

            // Get window metadata from accessibility API
            let metadata = getWindowMetadata(windowId: id, pid: pid)

            // Skip windows that don't pass accessibility filters (overlays, dialogs, etc.)
            guard let axElement = metadata.element else {
                continue
            }

            let title = metadata.title
            let appName = app.localizedName

            // Check if window is minimized
            var minimizedValue: AnyObject?
            let isMinimized =
                AXUIElementCopyAttributeValue(
                    axElement, kAXMinimizedAttribute as CFString, &minimizedValue) == .success
                && (minimizedValue as? Bool) == true

            // Skip windows with empty titles that aren't minimized (likely overlays)
            if title == nil && !isMinimized {
                continue
            }

            windows.append(
                PickerWindowInfo(
                    windowId: id,
                    pid: pid,
                    bounds: bounds,
                    title: title,
                    appName: appName,
                    axElement: metadata.element
                ))
        }

        return windows
    }

    private func getWindowMetadata(windowId: CGWindowID, pid: pid_t)
        -> (title: String?, element: AXUIElement?)
    {
        let axApp = AXUIElementCreateApplication(pid)

        var axValue: AnyObject?
        guard
            AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axValue)
                == .success,
            let axWindows = axValue as? [AXUIElement]
        else {
            return (nil, nil)
        }

        guard let targetWindow = axWindows.first(where: { $0.containingWindowId() == windowId })
        else {
            return (nil, nil)
        }

        // Filter out non-interactive windows (following WindowChangePublisher pattern)
        var subroleValue: AnyObject?
        if AXUIElementCopyAttributeValue(
            targetWindow, kAXSubroleAttribute as CFString, &subroleValue) == .success,
            let subrole = subroleValue as? String
        {
            let excludedSubroles = [
                "AXSystemDialog",
                "AXDialog",
                "AXUnknown",
            ]
            if excludedSubroles.contains(subrole) {
                return (nil, nil)
            }
        }

        // Only include standard windows
        var roleValue: AnyObject?
        if AXUIElementCopyAttributeValue(targetWindow, kAXRoleAttribute as CFString, &roleValue)
            == .success,
            let role = roleValue as? String,
            role != "AXWindow"
        {
            return (nil, nil)
        }

        var titleValue: AnyObject?
        if AXUIElementCopyAttributeValue(targetWindow, kAXTitleAttribute as CFString, &titleValue)
            == .success,
            let title = titleValue as? String,
            !title.isEmpty
        {
            return (title, targetWindow)
        }

        return (nil, targetWindow)
    }

    private func createOverlay() {
        // Create overlay covering all screens in NSScreen space (bottom-left origin)
        var minX = CGFloat.infinity
        var minY = CGFloat.infinity
        var maxX = -CGFloat.infinity
        var maxY = -CGFloat.infinity

        for screen in NSScreen.screens {
            let frame = screen.frame
            minX = min(minX, frame.minX)
            minY = min(minY, frame.minY)
            maxX = max(maxX, frame.maxX)
            maxY = max(maxY, frame.maxY)
        }

        let combinedFrame = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        let window = NSWindow(
            contentRect: combinedFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        let state = WindowHighlightState()
        let highlightView = WindowHighlightView(
            windows: allWindows,
            overlayFrame: combinedFrame,
            state: state,
            onWindowClick: { [weak self] (windowInfo: PickerWindowInfo) in
                self?.selectWindow(windowInfo)
            },
            onCancel: { [weak self] in
                self?.cancel()
            }
        )

        let hostingView = NSHostingView(rootView: highlightView)
        window.contentView = hostingView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = false
        window.orderFrontRegardless()

        self.overlayWindow = window
        self.highlightState = state
    }

    private func startMouseTracking() {
        mouseTrackingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
            [weak self] _ in
            self?.updateHighlight()
        }
    }

    private func updateHighlight() {
        // NSEvent.mouseLocation returns coordinates in NSScreen space (bottom-left origin)
        let mouseLocationBottomLeft = NSEvent.mouseLocation

        // Get primary screen height for coordinate conversion
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080

        // Convert mouse location from bottom-left to top-left origin (CGWindow space)
        let mouseLocationTopLeft = CGPoint(
            x: mouseLocationBottomLeft.x,
            y: primaryScreenHeight - mouseLocationBottomLeft.y
        )

        // Find window under cursor (window bounds are in CGWindow space - top-left origin)
        let windowUnderCursor = allWindows.first { window in
            window.bounds.contains(mouseLocationTopLeft)
        }

        DispatchQueue.main.async { [weak self] in
            self?.highlightState?.highlightedWindowId = windowUnderCursor?.windowId
        }
    }

    private func selectWindow(_ windowInfo: PickerWindowInfo) {
        cleanup()
        completion?(windowInfo)
    }

    private func cleanup() {
        mouseTrackingTimer?.invalidate()
        mouseTrackingTimer = nil
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        highlightState = nil
    }
}

// MARK: - SwiftUI View for Window Highlighting

private final class WindowHighlightState: ObservableObject {
    @Published var highlightedWindowId: CGWindowID?
}

private struct WindowHighlightView: View {
    let windows: [PickerWindowInfo]
    let overlayFrame: CGRect  // In NSScreen space (bottom-left origin)
    @ObservedObject var state: WindowHighlightState
    let onWindowClick: (PickerWindowInfo) -> Void
    let onCancel: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Semi-transparent background
                Color.black.opacity(0.3)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        // Only cancel if no window was clicked
                        // Check if click is on any window
                        let primaryScreenHeight =
                            NSScreen.screens.first?.frame.height ?? overlayFrame.height
                        let windowTopYInTopLeft = primaryScreenHeight - overlayFrame.maxY

                        var clickedWindow: PickerWindowInfo?
                        for window in windows {
                            let viewX = window.bounds.minX - overlayFrame.minX
                            let viewY = window.bounds.minY - windowTopYInTopLeft
                            let windowRect = CGRect(
                                x: viewX, y: viewY, width: window.bounds.width,
                                height: window.bounds.height)

                            if windowRect.contains(location) {
                                clickedWindow = window
                                break
                            }
                        }

                        if let window = clickedWindow {
                            onWindowClick(window)
                        } else {
                            onCancel()
                        }
                    }

                // Highlight borders for each window
                ForEach(windows) { window in
                    if state.highlightedWindowId == window.windowId {
                        WindowHighlightBorder(
                            window: window,
                            overlayFrame: overlayFrame,
                            geometrySize: geometry.size
                        )
                    }
                }

                // Instructions
                VStack {
                    Spacer()
                    Text("Click a window to select it, or click outside to cancel")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.black.opacity(0.7))
                        )
                        .padding(.bottom, 50)
                }
            }
        }
        .edgesIgnoringSafeArea(.all)
    }
}

private struct WindowHighlightBorder: View {
    let window: PickerWindowInfo
    let overlayFrame: CGRect  // In NSScreen space (bottom-left origin)
    let geometrySize: CGSize

    var body: some View {
        // COORDINATE SYSTEM CONVERSION (following HintOverlay pattern):
        // - window.bounds: CGWindow space (top-left origin, Y increases downward)
        // - overlayFrame: NSScreen space (bottom-left origin)
        // - SwiftUI view: Window-relative coordinates (top-left origin)

        // Get the primary screen height for coordinate system conversion
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? overlayFrame.height

        // Convert overlay window's top edge from bottom-left to top-left origin
        let windowTopYInTopLeft = primaryScreenHeight - overlayFrame.maxY

        // Convert window position to overlay-relative coordinates
        let viewX = window.bounds.minX - overlayFrame.minX
        let viewY = window.bounds.minY - windowTopYInTopLeft

        let width = window.bounds.width
        let height = window.bounds.height

        // Use .position() for absolute positioning within the geometry
        // .position() sets the CENTER of the view at the given coordinates
        let posX = viewX + width / 2
        let posY = viewY + height / 2

        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.blue, lineWidth: 4)
            .shadow(color: .blue.opacity(0.5), radius: 10)
            .frame(width: width, height: height)
            .position(x: posX, y: posY)
            .overlay(
                // Window info label
                VStack(alignment: .leading, spacing: 4) {
                    if let appName = window.appName {
                        Text(appName)
                            .font(.headline)
                            .foregroundColor(.white)
                    }
                    if let title = window.title, !title.isEmpty {
                        Text(title)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(2)
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.blue.opacity(0.9))
                )
                .position(x: viewX + 8, y: viewY + 8),
                alignment: .topLeading
            )
    }
}
