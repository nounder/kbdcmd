import Cocoa
import SwiftUI

/// Centralized manager for all overlays in the application.
/// Ensures mutual exclusivity and handles ESC key globally.
public class OverlayManager {
    public static let shared = OverlayManager()

    private var activeOverlay: ActiveOverlay?
    private var windowChangePublisher: WindowChangePublisher?

    private enum ActiveOverlay {
        case hint(window: NSWindow, manager: HintManager)
        case keybindingAssignment(window: NSWindow)
        case windowSwitcher(window: NSWindow)
    }

    public var isAnyOverlayVisible: Bool {
        return activeOverlay != nil
    }

    /// Returns true if the active overlay is the window switcher (non-sticky)
    public var isWindowSwitcherVisible: Bool {
        if case .windowSwitcher = activeOverlay {
            return true
        }
        return false
    }

    private init() {}

    // MARK: - Show Methods

    /// Shows the hint overlay for accessibility elements
    public func showHintOverlay() {
        // Hide any existing overlay first
        hideActive()

        // Show loading indicator immediately
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.showHintLoading()
        }

        // Collect elements in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let elements = AXInterface.collectClickableElements()

            DispatchQueue.main.async {
                guard self.activeOverlay != nil else { return }
                self.updateHintOverlayWithElements(elements)
            }
        }
    }

    /// Shows the keybinding assignment overlay for an app
    public func showKeybindingAssignmentOverlay(for appPath: String) {
        hideActive()

        // Cancel any pending window switcher overlay timer
        KeyListener.shared.cancelOverlayShow()

        let appName = (appPath as NSString).lastPathComponent.replacingOccurrences(
            of: ".app", with: "")
        let contentView = KeybindingAssignmentView(
            targetName: appName,
            isWindowMode: false,
            onKeyPress: { [weak self] char in
                Keybindings.shared.assignAppKeybinding(character: char, appPath: appPath)
                self?.hideActive()
            },
            onDismiss: { [weak self] in
                self?.hideActive()
            }
        )

        showOverlayWindow(with: contentView, type: .keybindingAssignment)
    }

    /// Shows the keybinding assignment overlay for a window
    public func showKeybindingAssignmentOverlay(forWindow windowId: CGWindowID, windowTitle: String)
    {
        hideActive()

        // Cancel any pending window switcher overlay timer
        KeyListener.shared.cancelOverlayShow()

        let contentView = KeybindingAssignmentView(
            targetName: windowTitle,
            isWindowMode: true,
            onKeyPress: { [weak self] char in
                Keybindings.shared.assignWindowKeybinding(
                    character: char, windowId: windowId, includeMinimized: true)
                self?.hideActive()
            },
            onDismiss: { [weak self] in
                self?.hideActive()
            }
        )

        showOverlayWindow(with: contentView, type: .keybindingAssignment)
    }

    /// Shows the window switcher overlay
    public func showWindowSwitcherOverlay() {
        guard activeOverlay == nil else {
            // Already showing, bring to front
            if case .windowSwitcher(let window) = activeOverlay {
                window.orderFrontRegardless()
            }
            return
        }

        let publisher = WindowChangePublisher()
        let contentView = WindowSwitcherView(
            publisher: publisher,
            onDismiss: { [weak self] in
                self?.hideActive()
            }
        )
        let hostingView = NSHostingView(rootView: contentView)

        // Get the screen containing the mouse cursor
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen =
            NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main

        guard let screen = targetScreen else { return }
        let screenFrame = screen.visibleFrame

        let windowWidth: CGFloat = 400
        let windowHeight = screenFrame.height
        // Position on the right side of the target screen
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

        activeOverlay = .windowSwitcher(window: window)
        windowChangePublisher = publisher
        publisher.startMonitoring()
    }

    // MARK: - Hide Methods

    /// Hides the currently active overlay
    public func hideActive() {
        guard let overlay = activeOverlay else { return }

        switch overlay {
        case .hint(let window, _):
            window.orderOut(nil)
        case .keybindingAssignment(let window):
            window.orderOut(nil)
        case .windowSwitcher(let window):
            windowChangePublisher?.stopMonitoring()
            windowChangePublisher = nil
            window.orderOut(nil)
        }

        activeOverlay = nil
    }

    // MARK: - Event Interception

    /// Intercepts events for the active overlay
    /// Returns true if the event was handled by an overlay
    public func interceptEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard activeOverlay != nil else { return false }

        // Handle mouse clicks
        if type == .leftMouseDown {
            // Let SwiftUI handle clicks for most overlays
            // They will call onDismiss if clicking outside interactive elements
            return false
        }

        // Handle keyboard events
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            // ESC always closes the active overlay (safety mechanism)
            if keyCode == Key.Named.escape.rawValue {
                hideActive()
                return true
            }

            // Let overlay-specific SwiftUI views handle other keys
            // The views will use NSEvent monitoring or custom input handling
            return false
        }

        return false
    }

    // MARK: - Private Helpers

    private func showHintLoading() {
        let contentView = LoadingOverlayView(onDismiss: { [weak self] in
            self?.hideActive()
        })
        let hostingView = NSHostingView(rootView: contentView)

        let mouseLocation = NSEvent.mouseLocation
        let targetScreen =
            NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main

        guard let screen = targetScreen else { return }

        let window = NSWindow(
            contentRect: screen.frame,
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

        // Store with placeholder manager (will be updated when elements load)
        activeOverlay = .hint(window: window, manager: HintManager(elements: []))
    }

    private func updateHintOverlayWithElements(_ elements: [ClickableElement]) {
        guard case .hint(let window, _) = activeOverlay else { return }

        let manager = HintManager(elements: elements)

        let contentView = HintOverlayView(
            elements: elements,
            windowFrame: window.frame,
            hintManager: manager,
            onElementClick: { [weak self] element in
                self?.clickElement(element)
            },
            onDismiss: { [weak self] in
                self?.hideActive()
            }
        )
        let hostingView = NSHostingView(rootView: contentView)

        window.contentView = hostingView
        activeOverlay = .hint(window: window, manager: manager)
    }

    private func clickElement(_ element: ClickableElement) {
        let success = AXInterface.clickElement(element)
        if success {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.hideActive()
            }
        }
    }

    private func showOverlayWindow<Content: View>(with content: Content, type: OverlayType) {
        let hostingView = NSHostingView(rootView: content)

        // Get the screen containing the mouse cursor
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen =
            NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main

        guard let screen = targetScreen else { return }
        let screenFrame = screen.frame

        let window = NSWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
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
        window.makeKey()

        switch type {
        case .keybindingAssignment:
            activeOverlay = .keybindingAssignment(window: window)
        }
    }

    private enum OverlayType {
        case keybindingAssignment
    }
}
