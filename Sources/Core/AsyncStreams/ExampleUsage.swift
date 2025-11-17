import Foundation
import CoreGraphics

// MARK: - Example: Async Event Monitoring Coordinator

/// Example demonstrating how to coordinate multiple async event streams
/// This replaces the traditional CFRunLoopRun() pattern
class AsyncEventMonitor {
    private var monitoringTask: Task<Void, Never>?

    func start() {
        monitoringTask = Task {
            await runEventLoop()
        }
    }

    func stop() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    private func runEventLoop() async {
        // Use task group to run multiple streams concurrently
        await withTaskGroup(of: Void.self) { group in
            // Stream 1: Monitor keyboard events
            group.addTask {
                await self.monitorKeyboardEvents()
            }

            // Stream 2: Monitor HID events (Caps Lock, etc.)
            group.addTask {
                await self.monitorHIDEvents()
            }

            // Stream 3: Monitor workspace events
            group.addTask {
                await self.monitorWorkspaceEvents()
            }

            // Stream 4: Monitor window changes
            group.addTask {
                await self.monitorWindowEvents()
            }
        }
    }

    // MARK: - Individual Stream Monitors

    private func monitorKeyboardEvents() async {
        let stream = CGEventStream.keyboard()

        for await event in stream {
            switch event.type {
            case .keyDown:
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                debugLog("Key down: \(keyCode)")

            case .keyUp:
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                debugLog("Key up: \(keyCode)")

            case .flagsChanged:
                debugLog("Flags changed: \(event.flags.rawValue)")

            default:
                break
            }
        }
    }

    private func monitorHIDEvents() async {
        let stream = HIDEventStream.keyboard()

        for await event in stream {
            if event.isCapsLock {
                let pressed = event.integerValue != 0
                debugLog("Caps Lock \(pressed ? "pressed" : "released")")
            }
        }
    }

    private func monitorWorkspaceEvents() async {
        let stream = WorkspaceNotificationStream.applicationLifecycle()

        for await event in stream {
            if event.isApplicationLaunched {
                debugLog("App launched: \(event.runningApplication?.localizedName ?? "Unknown")")
            } else if event.isApplicationTerminated {
                debugLog("App terminated: \(event.runningApplication?.localizedName ?? "Unknown")")
            }
        }
    }

    private func monitorWindowEvents() async {
        // Create a multi-observer that monitors all running apps
        let observer = AXMultiObserverStream(
            notifications: [
                kAXWindowCreatedNotification as CFString,
                kAXUIElementDestroyedNotification as CFString,
                kAXFocusedWindowChangedNotification as CFString,
            ]
        ) { event in
            if event.isWindowCreated {
                debugLog("Window created")
            } else if event.isWindowDestroyed {
                debugLog("Window destroyed")
            } else if event.isFocusedWindowChanged {
                debugLog("Focused window changed")
            }
        }

        // Add observers for all running apps
        let apps = NSWorkspace.shared.runningApplications
        for app in apps where app.activationPolicy == .regular {
            await observer.addObserver(for: app.processIdentifier)
        }

        // Keep the observer alive - it handles events via callback
        try? await Task.sleep(for: .seconds(3600))
    }
}

// MARK: - Example: Async Window Manager Usage

func exampleAsyncWindowQueries() async {
    // Get visible windows without blocking
    let visibleWindows = await asyncWindowManager.getVisibleWindows()
    debugLog("Found \(visibleWindows.count) visible windows")

    // Check if a specific window exists
    let windowID: CGWindowID = 12345
    let exists = await asyncWindowManager.windowExists(windowID)
    debugLog("Window \(windowID) exists: \(exists)")

    // Get windows for a specific app
    let pid: pid_t = 1234
    let appWindows = await asyncWindowManager.getWindowsForProcess(pid)
    debugLog("App has \(appWindows.count) windows")

    // Get Z-index mapping
    let zIndexMap = await asyncWindowManager.getZIndexMapping()
    debugLog("Z-index map contains \(zIndexMap.count) entries")
}

// MARK: - Example: Integration with Existing Code

/// Example showing how to integrate async streams with existing callback-based code
class LegacyIntegration {
    private var eventTask: Task<Void, Never>?
    private var eventHandler: ((CGEvent) -> Void)?

    func setEventHandler(_ handler: @escaping (CGEvent) -> Void) {
        self.eventHandler = handler
    }

    func start() {
        eventTask = Task {
            let stream = CGEventStream.keyboard()

            for await event in stream {
                // Bridge async stream to callback
                if let handler = await MainActor.run(body: { self.eventHandler }) {
                    await MainActor.run {
                        handler(event)
                    }
                }
            }
        }
    }

    func stop() {
        eventTask?.cancel()
    }
}

// MARK: - Example: Selective Event Filtering

/// Example showing how to filter and process only relevant events
actor EventFilter {
    private var lastEventTime: Date = Date()

    func shouldProcess(_ event: CGEvent) -> Bool {
        let now = Date()

        // Debounce: Only process events 100ms apart
        guard now.timeIntervalSince(lastEventTime) > 0.1 else {
            return false
        }

        lastEventTime = now
        return true
    }
}

func exampleEventFiltering() async {
    let filter = EventFilter()
    let stream = CGEventStream.keyboard()

    for await event in stream {
        // Only process events that pass the filter
        guard await filter.shouldProcess(event) else {
            continue
        }

        // Process the event
        debugLog("Processing filtered event")
    }
}

// MARK: - Example: Error Recovery

/// Example showing how to handle stream failures with automatic restart
func exampleErrorRecovery() async {
    var retryCount = 0
    let maxRetries = 3

    while retryCount < maxRetries {
        do {
            let stream = CGEventStream.keyboard()

            for await event in stream {
                // Process event
                debugLog("Event: \(event.type)")
            }

            // Stream ended normally
            break
        } catch {
            debugLog("Stream error: \(error)")
            retryCount += 1

            // Wait before retry with exponential backoff
            try? await Task.sleep(for: .seconds(Double(retryCount) * 2))
        }
    }
}

// MARK: - Example: Cancellation Handling

/// Example showing proper cancellation handling
class CancellableMonitor {
    private var task: Task<Void, Never>?

    func start() {
        task = Task {
            await withTaskCancellationHandler {
                // Main work
                let stream = CGEventStream.keyboard()
                for await event in stream {
                    // Check for cancellation periodically
                    if Task.isCancelled {
                        debugLog("Monitor cancelled")
                        break
                    }

                    // Process event
                    debugLog("Event: \(event.type)")
                }
            } onCancel: {
                // Cleanup on cancellation
                debugLog("Performing cleanup on cancellation")
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

// MARK: - Example: Main Entry Point Pattern

/// Example of how to structure the main entry point for a daemon using async streams
@main
struct AsyncDaemonExample {
    static func main() async {
        debugLog("Starting async daemon...")

        // Run the event monitor indefinitely
        let monitor = AsyncEventMonitor()
        monitor.start()

        // Keep running until interrupted
        try? await Task.sleep(for: .seconds(.infinity))
    }
}

// MARK: - Performance Comparison

/*
 Traditional Pattern (Blocking):
 ─────────────────────────────────
 Thread 1 (Main):
   ├─ Setup event tap
   ├─ CFRunLoopRun() ← BLOCKS FOREVER
   └─ (never reaches here)

 Limitations:
 - Thread is completely blocked
 - Can't do other async work
 - Hard to coordinate multiple event sources
 - Manual thread management required


 Async Stream Pattern (Non-Blocking):
 ─────────────────────────────────────
 Thread 1 (Main):
   ├─ Task.start()
   ├─ Continue with other work
   └─ Await when needed

 Thread 2 (CGEvent):
   ├─ Run loop for event tap
   └─ Yields events to stream

 Thread 3 (HID):
   ├─ Run loop for HID manager
   └─ Yields events to stream

 Benefits:
 - Main thread never blocks
 - Easy concurrent processing
 - Automatic thread management
 - Structured concurrency
 - Composable event streams
 */
