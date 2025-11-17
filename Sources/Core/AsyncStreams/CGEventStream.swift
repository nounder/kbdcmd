import Foundation
import CoreGraphics

/// An async sequence that provides CGEvents from an event tap
/// This eliminates the need for CFRunLoop and provides a modern Swift async interface
public struct CGEventStream: AsyncSequence {
    public typealias Element = CGEvent

    private let eventMask: CGEventMask
    private let tapLocation: CGEventTapLocation
    private let tapPlacement: CGEventTapPlacement
    private let options: CGEventTapOptions

    /// Creates a new CGEvent async stream
    /// - Parameters:
    ///   - eventMask: Mask of event types to monitor
    ///   - location: Where to tap events (default: .cghidEventTap)
    ///   - placement: Where to place the tap (default: .headInsertEventTap)
    ///   - options: Tap options (default: .defaultTap)
    public init(
        eventMask: CGEventMask,
        location: CGEventTapLocation = .cghidEventTap,
        placement: CGEventTapPlacement = .headInsertEventTap,
        options: CGEventTapOptions = .defaultTap
    ) {
        self.eventMask = eventMask
        self.tapLocation = location
        self.tapPlacement = placement
        self.options = options
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            eventMask: eventMask,
            tapLocation: tapLocation,
            tapPlacement: tapPlacement,
            options: options
        )
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let continuation: AsyncStream<CGEvent>.Continuation
        private let stream: AsyncStream<CGEvent>
        private var iterator: AsyncStream<CGEvent>.Iterator
        private let eventTap: CFMachPort?
        private let runLoopSource: CFRunLoopSource?
        private let wrapper: ContinuationWrapper

        init(
            eventMask: CGEventMask,
            tapLocation: CGEventTapLocation,
            tapPlacement: CGEventTapPlacement,
            options: CGEventTapOptions
        ) {
            var capturedContinuation: AsyncStream<CGEvent>.Continuation?

            let stream = AsyncStream<CGEvent> { continuation in
                capturedContinuation = continuation
            }

            self.stream = stream
            self.iterator = stream.makeAsyncIterator()
            self.continuation = capturedContinuation!

            // Create event tap callback
            let callback: CGEventTapCallBack = { _, _, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }

                let continuation = Unmanaged<ContinuationWrapper>.fromOpaque(refcon).takeUnretainedValue()

                // Yield the event to the async stream
                continuation.continuation.yield(event)

                return Unmanaged.passUnretained(event)
            }

            // Wrap continuation so we can pass it to C callback
            let wrapper = ContinuationWrapper(continuation: capturedContinuation!)
            self.wrapper = wrapper
            let refcon = Unmanaged.passUnretained(wrapper).toOpaque()

            var createdEventTap: CFMachPort?
            var createdRunLoopSource: CFRunLoopSource?

            // Use the shared run loop thread instead of creating a new one
            let setupSemaphore = DispatchSemaphore(value: 0)

            SharedRunLoopThread.shared.perform {
                // Create the event tap
                guard let eventTap = CGEvent.tapCreate(
                    tap: tapLocation,
                    place: tapPlacement,
                    options: options,
                    eventsOfInterest: eventMask,
                    callback: callback,
                    userInfo: refcon
                ) else {
                    print("Failed to create event tap. Accessibility permissions may be required.")
                    capturedContinuation?.finish()
                    setupSemaphore.signal()
                    return
                }

                createdEventTap = eventTap

                // Create run loop source and add to shared run loop
                guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
                    print("Failed to create run loop source")
                    capturedContinuation?.finish()
                    setupSemaphore.signal()
                    return
                }

                createdRunLoopSource = runLoopSource

                let runLoop = SharedRunLoopThread.shared.getRunLoop()
                CFRunLoopAddSource(runLoop, runLoopSource, .defaultMode)

                // Enable the event tap
                CGEvent.tapEnable(tap: eventTap, enable: true)

                debugLog("CGEventStream: Event tap created and added to shared run loop")

                // Signal that setup is complete
                setupSemaphore.signal()
            }

            // Wait for setup to complete
            setupSemaphore.wait()

            self.eventTap = createdEventTap
            self.runLoopSource = createdRunLoopSource
        }

        public mutating func next() async -> CGEvent? {
            await iterator.next()
        }

        /// Helper class to wrap continuation for C callback
        private class ContinuationWrapper {
            let continuation: AsyncStream<CGEvent>.Continuation

            init(continuation: AsyncStream<CGEvent>.Continuation) {
                self.continuation = continuation
            }
        }
    }
}

// MARK: - Convenience Extensions

extension CGEventStream {
    /// Creates a stream for keyboard events (keyDown, keyUp, flagsChanged)
    public static func keyboard() -> CGEventStream {
        let mask = (1 << CGEventType.keyDown.rawValue) |
                   (1 << CGEventType.keyUp.rawValue) |
                   (1 << CGEventType.flagsChanged.rawValue)

        return CGEventStream(eventMask: CGEventMask(mask))
    }

    /// Creates a stream for mouse events
    public static func mouse() -> CGEventStream {
        let mask = (1 << CGEventType.leftMouseDown.rawValue) |
                   (1 << CGEventType.leftMouseUp.rawValue) |
                   (1 << CGEventType.rightMouseDown.rawValue) |
                   (1 << CGEventType.rightMouseUp.rawValue) |
                   (1 << CGEventType.mouseMoved.rawValue)

        return CGEventStream(eventMask: CGEventMask(mask))
    }

    /// Creates a stream for both keyboard and mouse events
    public static func keyboardAndMouse() -> CGEventStream {
        let mask = (1 << CGEventType.keyDown.rawValue) |
                   (1 << CGEventType.keyUp.rawValue) |
                   (1 << CGEventType.flagsChanged.rawValue) |
                   (1 << CGEventType.leftMouseDown.rawValue) |
                   (1 << CGEventType.leftMouseUp.rawValue) |
                   (1 << CGEventType.rightMouseDown.rawValue) |
                   (1 << CGEventType.rightMouseUp.rawValue)

        return CGEventStream(eventMask: CGEventMask(mask))
    }
}
