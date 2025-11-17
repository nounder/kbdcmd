import Foundation
import ApplicationServices
import Cocoa

/// Utility class for bridging CFRunLoop-based APIs to modern Swift AsyncStream
@available(macOS 15.0, *)
final class AsyncStreamUtils {

    // MARK: - CGEvent Stream

    /// Creates an AsyncStream that emits CGEvents from an event tap
    /// - Parameters:
    ///   - tap: The location where to insert the event tap
    ///   - place: Where to insert the new event tap
    ///   - options: Event tap options
    ///   - eventsOfInterest: Mask of events to monitor
    /// - Returns: AsyncStream of CGEvent and proxy pairs
    static func eventTapStream(
        tap: CGEventTapLocation = .cgSessionEventTap,
        place: CGEventTapPlacement = .headInsertEventTap,
        options: CGEventTapOptions = .defaultTap,
        eventsOfInterest: CGEventMask
    ) -> AsyncStream<(event: CGEvent, proxy: CGEventTapProxy)> {
        AsyncStream { continuation in
            // Store the event tap reference for cleanup
            var eventTap: CFMachPort?
            var runLoopSource: CFRunLoopSource?
            var runLoop: CFRunLoop?

            // Create a dedicated thread for the run loop
            let thread = Thread {
                // Capture the run loop for this thread
                runLoop = CFRunLoopGetCurrent()

                // Create the event tap
                let callback: CGEventTapCallBack = { proxy, type, event, refcon in
                    guard let continuation = refcon?.assumingMemoryBound(to: AsyncStream<(event: CGEvent, proxy: CGEventTapProxy)>.Continuation.self).pointee else {
                        return Unmanaged.passUnretained(event)
                    }

                    // Handle tap disable events
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let tap = eventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                        return Unmanaged.passUnretained(event)
                    }

                    // Yield the event to the stream
                    continuation.yield((event: event, proxy: proxy))

                    return Unmanaged.passUnretained(event)
                }

                // Create heap-allocated continuation reference for the callback
                let continuationPtr = UnsafeMutablePointer<AsyncStream<(event: CGEvent, proxy: CGEventTapProxy)>.Continuation>.allocate(capacity: 1)
                continuationPtr.initialize(to: continuation)

                eventTap = CGEvent.tapCreate(
                    tap: tap,
                    place: place,
                    options: options,
                    eventsOfInterest: eventsOfInterest,
                    callback: callback,
                    userInfo: continuationPtr
                )

                guard let eventTap = eventTap else {
                    continuation.finish()
                    continuationPtr.deinitialize(count: 1)
                    continuationPtr.deallocate()
                    return
                }

                runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
                guard let runLoopSource = runLoopSource else {
                    continuation.finish()
                    continuationPtr.deinitialize(count: 1)
                    continuationPtr.deallocate()
                    return
                }

                CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
                CGEvent.tapEnable(tap: eventTap, enable: true)

                // Run the run loop (this blocks the thread)
                CFRunLoopRun()

                // Cleanup
                continuationPtr.deinitialize(count: 1)
                continuationPtr.deallocate()
            }

            thread.start()

            // Setup termination handler
            continuation.onTermination = { @Sendable _ in
                // Stop the run loop and cleanup
                if let runLoop = runLoop {
                    CFRunLoopStop(runLoop)
                }

                if let eventTap = eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: false)
                }

                if let runLoopSource = runLoopSource, let runLoop = runLoop {
                    CFRunLoopRemoveSource(runLoop, runLoopSource, .commonModes)
                }
            }
        }
    }

    // MARK: - AXObserver Stream

    /// Creates an AsyncStream that emits AXObserver notifications
    /// - Parameters:
    ///   - pid: Process ID to observe
    ///   - notifications: Array of notification names to observe
    ///   - element: The AXUIElement to observe (defaults to application element)
    /// - Returns: AsyncStream of notification events
    static func axObserverStream(
        pid: pid_t,
        notifications: [String],
        element: AXUIElement? = nil
    ) -> AsyncStream<(notification: String, element: AXUIElement)> {
        AsyncStream { continuation in
            var observer: AXObserver?
            var runLoop: CFRunLoop?

            // Create a dedicated thread for the run loop
            let thread = Thread {
                runLoop = CFRunLoopGetCurrent()

                // Create the observer
                let callback: AXObserverCallback = { observer, element, notification, refcon in
                    guard let continuation = refcon?.assumingMemoryBound(to: AsyncStream<(notification: String, element: AXUIElement)>.Continuation.self).pointee else {
                        return
                    }

                    let notificationName = notification as String
                    continuation.yield((notification: notificationName, element: element))
                }

                // Create heap-allocated continuation reference
                let continuationPtr = UnsafeMutablePointer<AsyncStream<(notification: String, element: AXUIElement)>.Continuation>.allocate(capacity: 1)
                continuationPtr.initialize(to: continuation)

                var newObserver: AXObserver?
                let result = AXObserverCreate(pid, callback, &newObserver)

                guard result == .success, let newObserver = newObserver else {
                    continuation.finish()
                    continuationPtr.deinitialize(count: 1)
                    continuationPtr.deallocate()
                    return
                }

                observer = newObserver

                // Determine the element to observe
                let observedElement = element ?? AXUIElementCreateApplication(pid)

                // Add notifications
                for notification in notifications {
                    AXObserverAddNotification(
                        newObserver,
                        observedElement,
                        notification as CFString,
                        continuationPtr
                    )
                }

                // Add observer to run loop
                CFRunLoopAddSource(
                    CFRunLoopGetCurrent(),
                    AXObserverGetRunLoopSource(newObserver),
                    .defaultMode
                )

                // Run the run loop
                CFRunLoopRun()

                // Cleanup
                continuationPtr.deinitialize(count: 1)
                continuationPtr.deallocate()
            }

            thread.start()

            // Setup termination handler
            continuation.onTermination = { @Sendable _ in
                if let runLoop = runLoop {
                    CFRunLoopStop(runLoop)
                }

                if let observer = observer, let runLoop = runLoop {
                    CFRunLoopRemoveSource(
                        runLoop,
                        AXObserverGetRunLoopSource(observer),
                        .defaultMode
                    )
                }
            }
        }
    }

    // MARK: - IOHIDManager Stream

    /// Creates an AsyncStream that emits IOHIDManager input events
    /// - Parameters:
    ///   - matching: Device matching criteria
    /// - Returns: AsyncStream of HID input values
    static func hidManagerStream(
        matching: [[String: Any]]
    ) -> AsyncStream<(device: IOHIDDevice, value: IOHIDValue)> {
        AsyncStream { continuation in
            var manager: IOHIDManager?
            var runLoop: CFRunLoop?

            // Create a dedicated thread for the run loop
            let thread = Thread {
                runLoop = CFRunLoopGetCurrent()

                let newManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
                manager = newManager

                IOHIDManagerSetDeviceMatchingMultiple(newManager, matching as CFArray)

                // Create heap-allocated continuation reference
                let continuationPtr = UnsafeMutablePointer<AsyncStream<(device: IOHIDDevice, value: IOHIDValue)>.Continuation>.allocate(capacity: 1)
                continuationPtr.initialize(to: continuation)

                // Set input value callback
                IOHIDManagerRegisterInputValueCallback(newManager, { context, result, sender, value in
                    guard let continuation = context?.assumingMemoryBound(to: AsyncStream<(device: IOHIDDevice, value: IOHIDValue)>.Continuation.self).pointee else {
                        return
                    }

                    let device = IOHIDValueGetElement(value)
                    let hidDevice = IOHIDElementGetDevice(device)
                    continuation.yield((device: hidDevice, value: value))
                }, continuationPtr)

                // Schedule with run loop
                IOHIDManagerScheduleWithRunLoop(newManager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue as CFString)

                // Open the manager
                let result = IOHIDManagerOpen(newManager, IOOptionBits(kIOHIDOptionsTypeNone))
                guard result == kIOReturnSuccess else {
                    continuation.finish()
                    continuationPtr.deinitialize(count: 1)
                    continuationPtr.deallocate()
                    return
                }

                // Run the run loop
                CFRunLoopRun()

                // Cleanup
                continuationPtr.deinitialize(count: 1)
                continuationPtr.deallocate()
            }

            thread.start()

            // Setup termination handler
            continuation.onTermination = { @Sendable _ in
                if let manager = manager {
                    IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                }

                if let manager = manager, let runLoop = runLoop {
                    IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue as CFString)
                }

                if let runLoop = runLoop {
                    CFRunLoopStop(runLoop)
                }
            }
        }
    }

    // MARK: - Window List Stream

    /// Creates an AsyncStream that emits window list updates
    /// - Parameters:
    ///   - options: Window list options
    ///   - relativeToWindow: Window ID to get windows relative to
    ///   - pollInterval: How often to poll for changes (in seconds)
    /// - Returns: AsyncStream of window lists
    static func windowListStream(
        options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements],
        relativeToWindow: CGWindowID = kCGNullWindowID,
        pollInterval: TimeInterval = 0.5
    ) -> AsyncStream<[[String: Any]]> {
        AsyncStream { continuation in
            let task = Task {
                var previousWindowList: [[String: Any]] = []

                while !Task.isCancelled {
                    // Perform window list query on background thread
                    let windowList = await Task.detached {
                        guard let windowsInfo = CGWindowListCopyWindowInfo(options, relativeToWindow) as? [[String: Any]] else {
                            return []
                        }
                        return windowsInfo
                    }.value

                    // Only yield if the list has changed
                    if !windowListsEqual(previousWindowList, windowList) {
                        continuation.yield(windowList)
                        previousWindowList = windowList
                    }

                    // Wait before next poll
                    try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                }

                continuation.finish()
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Screen Change Stream

    /// Creates an AsyncStream that emits screen configuration changes
    /// - Returns: AsyncStream of screen arrays
    static func screenChangeStream() -> AsyncStream<[NSScreen]> {
        AsyncStream { continuation in
            let center = NotificationCenter.default

            let observer = center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { _ in
                continuation.yield(NSScreen.screens)
            }

            // Yield initial state
            continuation.yield(NSScreen.screens)

            continuation.onTermination = { @Sendable _ in
                center.removeObserver(observer)
            }
        }
    }

    // MARK: - Workspace Notification Stream

    /// Creates an AsyncStream that emits NSWorkspace notifications
    /// - Parameter notificationName: The notification to observe
    /// - Returns: AsyncStream of notifications
    static func workspaceNotificationStream(
        _ notificationName: NSNotification.Name
    ) -> AsyncStream<Notification> {
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter

            let observer = center.addObserver(
                forName: notificationName,
                object: nil,
                queue: .main
            ) { notification in
                continuation.yield(notification)
            }

            continuation.onTermination = { @Sendable _ in
                center.removeObserver(observer)
            }
        }
    }

    // MARK: - Helper Methods

    private static func windowListsEqual(_ list1: [[String: Any]], _ list2: [[String: Any]]) -> Bool {
        guard list1.count == list2.count else { return false }

        for (window1, window2) in zip(list1, list2) {
            let id1 = window1[kCGWindowNumber as String] as? Int
            let id2 = window2[kCGWindowNumber as String] as? Int

            if id1 != id2 {
                return false
            }
        }

        return true
    }
}
