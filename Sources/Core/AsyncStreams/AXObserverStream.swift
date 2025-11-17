import Foundation
import ApplicationServices

/// Represents an accessibility notification event
public struct AXNotificationEvent {
    public let observer: AXObserver
    public let element: AXUIElement
    public let notification: CFString
    public let userInfo: CFDictionary?

    init(observer: AXObserver, element: AXUIElement, notification: CFString, userInfo: CFDictionary? = nil) {
        self.observer = observer
        self.element = element
        self.notification = notification
        self.userInfo = userInfo
    }
}

/// An async sequence that provides accessibility notifications from AXObserver
/// This eliminates the need for CFRunLoop and provides a modern Swift async interface
public struct AXObserverStream: AsyncSequence {
    public typealias Element = AXNotificationEvent

    private let pid: pid_t
    private let notifications: [CFString]

    /// Creates a new AXObserver async stream for a specific application
    /// - Parameters:
    ///   - pid: Process ID of the application to observe
    ///   - notifications: Array of notification names to observe
    public init(pid: pid_t, notifications: [CFString]) {
        self.pid = pid
        self.notifications = notifications
    }

    /// Creates a stream for window lifecycle notifications
    public static func windowLifecycle(pid: pid_t) -> AXObserverStream {
        AXObserverStream(pid: pid, notifications: [
            kAXWindowCreatedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString,
            kAXWindowMiniaturizedNotification as CFString,
            kAXWindowDeminiaturizedNotification as CFString,
            kAXWindowMovedNotification as CFString,
            kAXWindowResizedNotification as CFString,
            kAXFocusedWindowChangedNotification as CFString
        ])
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(pid: pid, notifications: notifications)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let stream: AsyncStream<AXNotificationEvent>
        private var iterator: AsyncStream<AXNotificationEvent>.Iterator
        private let observer: AXObserver?
        private let wrapper: ContinuationWrapper

        init(pid: pid_t, notifications: [CFString]) {
            var capturedContinuation: AsyncStream<AXNotificationEvent>.Continuation?

            let stream = AsyncStream<AXNotificationEvent> { continuation in
                capturedContinuation = continuation
            }

            self.stream = stream
            self.iterator = stream.makeAsyncIterator()

            // Create AX observer callback
            let callback: AXObserverCallback = { observer, element, notification, refcon in
                guard let refcon = refcon else { return }

                let continuation = Unmanaged<ContinuationWrapper>.fromOpaque(refcon).takeUnretainedValue()

                // Create event and yield it
                let event = AXNotificationEvent(
                    observer: observer,
                    element: element,
                    notification: notification,
                    userInfo: nil
                )
                continuation.continuation.yield(event)
            }

            // Wrap continuation for C callback
            let wrapper = ContinuationWrapper(continuation: capturedContinuation!)
            self.wrapper = wrapper
            let refcon = Unmanaged.passUnretained(wrapper).toOpaque()

            var createdObserver: AXObserver?

            // Use the shared run loop thread instead of creating a new one
            let setupSemaphore = DispatchSemaphore(value: 0)

            SharedRunLoopThread.shared.perform {
                // Create the observer
                var observer: AXObserver?
                let result = AXObserverCreate(pid, callback, &observer)

                guard result == .success, let observer = observer else {
                    print("Failed to create AX observer for pid \(pid): \(result.rawValue)")
                    capturedContinuation?.finish()
                    setupSemaphore.signal()
                    return
                }

                createdObserver = observer

                // Get the application element
                let app = AXUIElementCreateApplication(pid)

                // Add notifications
                for notification in notifications {
                    let addResult = AXObserverAddNotification(observer, app, notification, refcon)
                    if addResult != .success {
                        print("Failed to add notification \(notification) for pid \(pid): \(addResult.rawValue)")
                    }
                }

                // Get run loop source and add to shared run loop
                guard let runLoopSource = AXObserverGetRunLoopSource(observer) else {
                    print("Failed to get run loop source for observer")
                    capturedContinuation?.finish()
                    setupSemaphore.signal()
                    return
                }

                let runLoop = SharedRunLoopThread.shared.getRunLoop()
                CFRunLoopAddSource(runLoop, runLoopSource, .defaultMode)

                debugLog("AXObserverStream: Observer for pid \(pid) created and added to shared run loop")

                // Signal that setup is complete
                setupSemaphore.signal()
            }

            // Wait for setup to complete
            setupSemaphore.wait()

            self.observer = createdObserver
        }

        public mutating func next() async -> AXNotificationEvent? {
            await iterator.next()
        }

        /// Helper class to wrap continuation for C callback
        private class ContinuationWrapper {
            let continuation: AsyncStream<AXNotificationEvent>.Continuation

            init(continuation: AsyncStream<AXNotificationEvent>.Continuation) {
                self.continuation = continuation
            }
        }
    }
}

// MARK: - Convenience Extensions

extension AXNotificationEvent {
    /// Returns the notification name as a String
    public var notificationName: String {
        notification as String
    }

    /// Returns true if this is a window created notification
    public var isWindowCreated: Bool {
        notification == kAXWindowCreatedNotification as CFString
    }

    /// Returns true if this is a window destroyed notification
    public var isWindowDestroyed: Bool {
        notification == kAXUIElementDestroyedNotification as CFString
    }

    /// Returns true if this is a window minimized notification
    public var isWindowMinimized: Bool {
        notification == kAXWindowMiniaturizedNotification as CFString
    }

    /// Returns true if this is a window deminimized notification
    public var isWindowDeminimized: Bool {
        notification == kAXWindowDeminiaturizedNotification as CFString
    }

    /// Returns true if this is a window moved notification
    public var isWindowMoved: Bool {
        notification == kAXWindowMovedNotification as CFString
    }

    /// Returns true if this is a window resized notification
    public var isWindowResized: Bool {
        notification == kAXWindowResizedNotification as CFString
    }

    /// Returns true if this is a focused window changed notification
    public var isFocusedWindowChanged: Bool {
        notification == kAXFocusedWindowChangedNotification as CFString
    }
}

// MARK: - Multi-Application Observer

/// Manages multiple AXObserver streams for different applications
public actor AXMultiObserverStream {
    private var observers: [pid_t: Task<Void, Never>] = [:]
    private let notifications: [CFString]
    private let eventHandler: @Sendable (AXNotificationEvent) async -> Void

    public init(
        notifications: [CFString],
        eventHandler: @escaping @Sendable (AXNotificationEvent) async -> Void
    ) {
        self.notifications = notifications
        self.eventHandler = eventHandler
    }

    /// Adds an observer for a specific process
    public func addObserver(for pid: pid_t) {
        // Don't add if already observing
        guard observers[pid] == nil else { return }

        let task = Task {
            let stream = AXObserverStream(pid: pid, notifications: notifications)
            for await event in stream {
                await eventHandler(event)
            }
        }

        observers[pid] = task
    }

    /// Removes an observer for a specific process
    public func removeObserver(for pid: pid_t) {
        observers[pid]?.cancel()
        observers[pid] = nil
    }

    /// Removes all observers
    public func removeAllObservers() {
        for task in observers.values {
            task.cancel()
        }
        observers.removeAll()
    }
}
