import Foundation
import IOKit.hid

/// Represents a HID input event
public struct HIDEvent {
    public let element: IOHIDElement
    public let value: IOHIDValue
    public let timestamp: UInt64
    public let integerValue: Int

    init(element: IOHIDElement, value: IOHIDValue) {
        self.element = element
        self.value = value
        self.timestamp = IOHIDValueGetTimeStamp(value)
        self.integerValue = IOHIDValueGetIntegerValue(value)
    }
}

/// An async sequence that provides HID events from IOHIDManager
/// This eliminates the need for CFRunLoop and provides a modern Swift async interface
public struct HIDEventStream: AsyncSequence {
    public typealias Element = HIDEvent

    private let deviceMatching: [[String: Any]]

    /// Creates a new HID event async stream
    /// - Parameter deviceMatching: Array of device matching dictionaries
    public init(deviceMatching: [[String: Any]]) {
        self.deviceMatching = deviceMatching
    }

    /// Creates a stream for keyboard devices
    public static func keyboard() -> HIDEventStream {
        let matching = [
            [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard
            ] as [String: Any]
        ]
        return HIDEventStream(deviceMatching: matching)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(deviceMatching: deviceMatching)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let stream: AsyncStream<HIDEvent>
        private var iterator: AsyncStream<HIDEvent>.Iterator
        private let hidManager: IOHIDManager
        private let thread: Thread

        init(deviceMatching: [[String: Any]]) {
            var capturedContinuation: AsyncStream<HIDEvent>.Continuation?

            let stream = AsyncStream<HIDEvent> { continuation in
                capturedContinuation = continuation
            }

            self.stream = stream
            self.iterator = stream.makeAsyncIterator()

            // Create HID manager on a dedicated thread
            var createdHIDManager: IOHIDManager!
            var createdThread: Thread!

            let setupSemaphore = DispatchSemaphore(value: 0)

            createdThread = Thread {
                // Set thread name for debugging
                Thread.current.name = "com.kbdcmd.hid-stream"

                // Create HID manager
                let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
                createdHIDManager = manager

                // Set device matching
                IOHIDManagerSetDeviceMatchingMultiple(manager, deviceMatching as CFArray)

                // Create input value callback
                let inputCallback: IOHIDValueCallback = { context, result, sender, value in
                    guard let context = context else { return }

                    let continuation = Unmanaged<ContinuationWrapper>.fromOpaque(context).takeUnretainedValue()

                    // Get the element
                    let element = IOHIDValueGetElement(value)

                    // Create HID event and yield it
                    let event = HIDEvent(element: element, value: value)
                    continuation.continuation.yield(event)
                }

                // Wrap continuation for C callback
                let wrapper = ContinuationWrapper(continuation: capturedContinuation!)
                let context = Unmanaged.passUnretained(wrapper).toOpaque()

                // Register input value callback
                IOHIDManagerRegisterInputValueCallback(manager, inputCallback, context)

                // Schedule with run loop
                let runLoop = CFRunLoopGetCurrent()
                IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)

                // Open the manager
                let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                if openResult != kIOReturnSuccess {
                    print("Failed to open HID manager: \(openResult)")
                    capturedContinuation?.finish()
                    setupSemaphore.signal()
                    return
                }

                // Signal that setup is complete
                setupSemaphore.signal()

                // Run the run loop on this dedicated thread
                CFRunLoopRun()

                // Cleanup when run loop exits
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
            }

            createdThread.start()

            // Wait for setup to complete
            setupSemaphore.wait()

            self.hidManager = createdHIDManager
            self.thread = createdThread
        }

        public mutating func next() async -> HIDEvent? {
            await iterator.next()
        }

        /// Helper class to wrap continuation for C callback
        private class ContinuationWrapper {
            let continuation: AsyncStream<HIDEvent>.Continuation

            init(continuation: AsyncStream<HIDEvent>.Continuation) {
                self.continuation = continuation
            }
        }
    }
}

// MARK: - HIDEvent Convenience Extensions

extension HIDEvent {
    /// Returns the usage page of the element
    public var usagePage: Int {
        IOHIDElementGetUsagePage(element)
    }

    /// Returns the usage of the element
    public var usage: Int {
        IOHIDElementGetUsage(element)
    }

    /// Returns true if this is a Caps Lock key event
    public var isCapsLock: Bool {
        usagePage == kHIDPage_KeyboardOrKeypad && usage == kHIDUsage_KeyboardCapsLock
    }

    /// Returns true if this is a keyboard event
    public var isKeyboard: Bool {
        usagePage == kHIDPage_KeyboardOrKeypad
    }
}
