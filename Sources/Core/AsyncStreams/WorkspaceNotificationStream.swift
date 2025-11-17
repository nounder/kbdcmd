import Foundation
import AppKit

/// Represents a workspace notification event
public struct WorkspaceNotificationEvent {
    public let notification: Notification
    public let name: Notification.Name

    init(notification: Notification) {
        self.notification = notification
        self.name = notification.name
    }

    /// Returns the running application if available
    public var runningApplication: NSRunningApplication? {
        notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    /// Returns the process identifier if available
    public var processIdentifier: pid_t? {
        runningApplication?.processIdentifier
    }
}

/// An async sequence that provides NSWorkspace notifications
/// This provides a modern Swift async interface for workspace events
public struct WorkspaceNotificationStream: AsyncSequence {
    public typealias Element = WorkspaceNotificationEvent

    private let notificationNames: [Notification.Name]
    private let workspace: NSWorkspace

    /// Creates a new workspace notification stream
    /// - Parameters:
    ///   - notificationNames: Array of notification names to observe
    ///   - workspace: The workspace to observe (defaults to shared workspace)
    public init(
        notificationNames: [Notification.Name],
        workspace: NSWorkspace = .shared
    ) {
        self.notificationNames = notificationNames
        self.workspace = workspace
    }

    /// Creates a stream for application lifecycle events
    public static func applicationLifecycle(workspace: NSWorkspace = .shared) -> WorkspaceNotificationStream {
        WorkspaceNotificationStream(
            notificationNames: [
                NSWorkspace.didLaunchApplicationNotification,
                NSWorkspace.didTerminateApplicationNotification,
                NSWorkspace.didActivateApplicationNotification,
                NSWorkspace.didDeactivateApplicationNotification
            ],
            workspace: workspace
        )
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(notificationNames: notificationNames, workspace: workspace)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let stream: AsyncStream<WorkspaceNotificationEvent>
        private var iterator: AsyncStream<WorkspaceNotificationEvent>.Iterator
        private var observers: [NSObjectProtocol] = []

        init(notificationNames: [Notification.Name], workspace: NSWorkspace) {
            var capturedContinuation: AsyncStream<WorkspaceNotificationEvent>.Continuation?
            var capturedObservers: [NSObjectProtocol] = []

            let stream = AsyncStream<WorkspaceNotificationEvent> { continuation in
                capturedContinuation = continuation

                let notificationCenter = workspace.notificationCenter

                // Subscribe to each notification
                for name in notificationNames {
                    let observer = notificationCenter.addObserver(
                        forName: name,
                        object: workspace,
                        queue: .main
                    ) { notification in
                        let event = WorkspaceNotificationEvent(notification: notification)
                        continuation.yield(event)
                    }
                    capturedObservers.append(observer)
                }

                continuation.onTermination = { @Sendable _ in
                    // Clean up observers when stream terminates
                    for observer in capturedObservers {
                        notificationCenter.removeObserver(observer)
                    }
                }
            }

            self.stream = stream
            self.iterator = stream.makeAsyncIterator()
            self.observers = capturedObservers
        }

        public mutating func next() async -> WorkspaceNotificationEvent? {
            await iterator.next()
        }
    }
}

// MARK: - DistributedNotificationCenter Support

/// An async sequence that provides NSDistributedNotificationCenter notifications
public struct DistributedNotificationStream: AsyncSequence {
    public typealias Element = Notification

    private let notificationNames: [Notification.Name]
    private let center: DistributedNotificationCenter

    /// Creates a new distributed notification stream
    /// - Parameters:
    ///   - notificationNames: Array of notification names to observe
    ///   - center: The notification center to observe (defaults to default center)
    public init(
        notificationNames: [Notification.Name],
        center: DistributedNotificationCenter = .default()
    ) {
        self.notificationNames = notificationNames
        self.center = center
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(notificationNames: notificationNames, center: center)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let stream: AsyncStream<Notification>
        private var iterator: AsyncStream<Notification>.Iterator
        private var observers: [NSObjectProtocol] = []

        init(notificationNames: [Notification.Name], center: DistributedNotificationCenter) {
            var capturedObservers: [NSObjectProtocol] = []

            let stream = AsyncStream<Notification> { continuation in
                // Subscribe to each notification
                for name in notificationNames {
                    let observer = center.addObserver(
                        forName: name,
                        object: nil,
                        queue: .main
                    ) { notification in
                        continuation.yield(notification)
                    }
                    capturedObservers.append(observer)
                }

                continuation.onTermination = { @Sendable _ in
                    // Clean up observers when stream terminates
                    for observer in capturedObservers {
                        center.removeObserver(observer)
                    }
                }
            }

            self.stream = stream
            self.iterator = stream.makeAsyncIterator()
            self.observers = capturedObservers
        }

        public mutating func next() async -> Notification? {
            await iterator.next()
        }
    }
}

// MARK: - Convenience Extensions

extension WorkspaceNotificationEvent {
    /// Returns true if this is an application launched event
    public var isApplicationLaunched: Bool {
        name == NSWorkspace.didLaunchApplicationNotification
    }

    /// Returns true if this is an application terminated event
    public var isApplicationTerminated: Bool {
        name == NSWorkspace.didTerminateApplicationNotification
    }

    /// Returns true if this is an application activated event
    public var isApplicationActivated: Bool {
        name == NSWorkspace.didActivateApplicationNotification
    }

    /// Returns true if this is an application deactivated event
    public var isApplicationDeactivated: Bool {
        name == NSWorkspace.didDeactivateApplicationNotification
    }
}
