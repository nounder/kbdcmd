import Foundation
import CoreGraphics
import IOKit.hid

/// Async coordinator that manages all event streams without blocking run loops
/// This replaces the CFRunLoopRun() pattern with modern Swift concurrency
public actor AsyncKeyListenerCoordinator {
    private var cgEventTask: Task<Void, Never>?
    private var hidEventTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?

    private var isRunning = false

    /// Starts all event monitoring tasks
    public func start() async {
        guard !isRunning else {
            debugLog("AsyncKeyListenerCoordinator already running")
            return
        }

        isRunning = true
        debugLog("Starting AsyncKeyListenerCoordinator...")

        // Start CGEvent monitoring
        startCGEventMonitoring()

        // Start HID event monitoring
        startHIDEventMonitoring()

        // Start notification monitoring
        startNotificationMonitoring()

        debugLog("AsyncKeyListenerCoordinator started successfully")
    }

    /// Stops all event monitoring tasks
    public func stop() {
        debugLog("Stopping AsyncKeyListenerCoordinator...")

        cgEventTask?.cancel()
        hidEventTask?.cancel()
        notificationTask?.cancel()

        cgEventTask = nil
        hidEventTask = nil
        notificationTask = nil

        isRunning = false

        debugLog("AsyncKeyListenerCoordinator stopped")
    }

    // MARK: - CGEvent Monitoring

    private func startCGEventMonitoring() {
        cgEventTask = Task {
            let eventMask = (1 << CGEventType.keyDown.rawValue) |
                           (1 << CGEventType.keyUp.rawValue) |
                           (1 << CGEventType.flagsChanged.rawValue) |
                           (1 << CGEventType.leftMouseDown.rawValue)

            let stream = CGEventStream(
                eventMask: CGEventMask(eventMask),
                location: .cgSessionEventTap,
                placement: .headInsertEventTap,
                options: .defaultTap
            )

            debugLog("CGEvent stream started")

            for await event in stream {
                // Handle event on main thread since KeyListener expects that
                await MainActor.run {
                    _ = KeyListener.handleEvent(
                        proxy: CGEventTapProxy(bitPattern: 0)!,
                        type: event.type,
                        event: event
                    )
                }
            }

            debugLog("CGEvent stream ended")
        }
    }

    // MARK: - HID Event Monitoring

    private func startHIDEventMonitoring() {
        hidEventTask = Task {
            let stream = HIDEventStream.keyboard()

            debugLog("HID event stream started")

            for await hidEvent in stream {
                // Forward to KeyListener's HID monitor callback if needed
                // For now, this is handled by the existing KeyboardHIDMonitor in KeyListener
                debugLog("HID event: page=\(hidEvent.usagePage), usage=\(hidEvent.usage), value=\(hidEvent.integerValue)")
            }

            debugLog("HID event stream ended")
        }
    }

    // MARK: - Notification Monitoring

    private func startNotificationMonitoring() {
        notificationTask = Task {
            let stream = DistributedNotificationStream(
                notificationNames: [
                    Notification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String)
                ]
            )

            debugLog("Notification stream started")

            for await notification in stream {
                // Forward to KeyListener for keyboard layout changes
                await MainActor.run {
                    KeyListener.shared.handleKeyboardInputSourceChanged(notification)
                }
            }

            debugLog("Notification stream ended")
        }
    }
}

// MARK: - KeyListener Extensions for Async Support

extension KeyListener {
    /// Handle keyboard input source changed notification from async stream
    @MainActor
    func handleKeyboardInputSourceChanged(_ notification: Notification) {
        debugLog("Keyboard input source changed (async), rebuilding key code cache")
        keyCodeToKey = buildKeyCodeCache()
        debugLog("Key code cache rebuilt (async)")
    }

    /// Async start method that doesn't block
    /// This should be called instead of the old start() method which calls CFRunLoopRun()
    public func startAsync() async {
        let coordinator = AsyncKeyListenerCoordinator()
        await coordinator.start()

        // Keep the coordinator alive by storing it
        // In practice, this would be stored as a property of KeyListener
        // For now, we keep a reference in a task that waits indefinitely
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Never resume - this keeps the task alive until cancelled
            // In production, you'd store the coordinator and cancel it when needed
        }
    }
}
