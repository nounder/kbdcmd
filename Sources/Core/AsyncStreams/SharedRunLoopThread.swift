import Foundation

/// Singleton shared run loop thread for all CF-based event sources
/// This is more efficient than creating separate threads for each event source
public final class SharedRunLoopThread {
    public static let shared = SharedRunLoopThread()

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let setupSemaphore = DispatchSemaphore(value: 0)

    private init() {}

    /// Starts the shared run loop thread if not already started
    public func start() {
        guard thread == nil else {
            debugLog("SharedRunLoopThread already running")
            return
        }

        let newThread = Thread { [weak self] in
            guard let self = self else { return }

            // Set thread name for debugging
            Thread.current.name = "com.kbdcmd.shared-runloop"

            // Store the run loop
            self.runLoop = CFRunLoopGetCurrent()

            // Signal that setup is complete
            self.setupSemaphore.signal()

            debugLog("SharedRunLoopThread started")

            // Run the run loop
            CFRunLoopRun()

            debugLog("SharedRunLoopThread stopped")
        }

        newThread.start()
        self.thread = newThread

        // Wait for run loop to be ready
        setupSemaphore.wait()
    }

    /// Gets the shared run loop (starts thread if needed)
    public func getRunLoop() -> CFRunLoop {
        start()
        return runLoop!
    }

    /// Stops the shared run loop thread
    public func stop() {
        guard let runLoop = runLoop else { return }

        CFRunLoopStop(runLoop)

        self.thread = nil
        self.runLoop = nil

        debugLog("SharedRunLoopThread stopped")
    }

    /// Performs a block on the run loop thread
    public func perform(_ block: @escaping () -> Void) {
        guard let runLoop = runLoop else {
            start()
            perform(block)
            return
        }

        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            block()
        }
        CFRunLoopWakeUp(runLoop)
    }
}
