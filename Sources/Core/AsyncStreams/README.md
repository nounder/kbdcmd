# Async Streams Migration Guide

This directory contains modern Swift async/await wrappers for Core Foundation and Core Graphics APIs that traditionally require CFRunLoop.

## Overview

The async stream infrastructure eliminates the need for blocking `CFRunLoopRun()` calls by:

1. **Shared Run Loop Thread**: All CF/CG event sources share a single dedicated thread with run loop
2. **Async Sequences**: All events are delivered via Swift AsyncSequence protocol
3. **No Blocking**: Code can process events using `for await` loops without blocking the main thread
4. **Concurrent Processing**: Multiple streams can run in parallel using structured concurrency
5. **Efficient**: One shared thread handles all CF-based event sources (CGEvent, IOHIDManager, AXObserver)

## Available Streams

### CGEventStream

Provides CGEvents from event taps without requiring CFRunLoop on the caller's thread.

```swift
// Monitor keyboard events
let stream = CGEventStream.keyboard()

for await event in stream {
    print("Key event: \(event.type)")
}
```

**Key Features:**
- Runs event tap on dedicated background thread
- Automatically manages run loop lifecycle
- Supports custom event masks and tap locations

### HIDEventStream

Provides low-level HID events from IOHIDManager.

```swift
// Monitor keyboard HID events
let stream = HIDEventStream.keyboard()

for await event in stream {
    if event.isCapsLock {
        print("Caps Lock: \(event.integerValue)")
    }
}
```

**Key Features:**
- Dedicated thread for HID manager
- Device-level event monitoring
- Useful for tracking physical key states

### AXObserverStream

Provides accessibility notifications without CFRunLoop scheduling.

```swift
// Monitor window events for a specific app
let stream = AXObserverStream.windowLifecycle(pid: appPID)

for await event in stream {
    if event.isWindowCreated {
        print("Window created")
    }
}
```

**Multi-Application Monitoring:**

```swift
let manager = AXMultiObserverStream(
    notifications: [kAXWindowCreatedNotification as CFString]
) { event in
    print("Window event from any app: \(event.notificationName)")
}

await manager.addObserver(for: pid1)
await manager.addObserver(for: pid2)
```

**Key Features:**
- Per-process observers on dedicated threads
- Automatic cleanup on stream termination
- Convenient multi-app management with AXMultiObserverStream

### WorkspaceNotificationStream

Provides NSWorkspace notifications as an async stream.

```swift
// Monitor application lifecycle
let stream = WorkspaceNotificationStream.applicationLifecycle()

for await event in stream {
    if event.isApplicationLaunched {
        print("App launched: \(event.runningApplication?.localizedName ?? "Unknown")")
    }
}
```

**Key Features:**
- Automatic observer registration and cleanup
- Main thread delivery for UI updates
- Type-safe event handling

### DistributedNotificationStream

Provides distributed notifications as an async stream.

```swift
// Monitor keyboard layout changes
let stream = DistributedNotificationStream(
    notificationNames: [
        Notification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String)
    ]
)

for await notification in stream {
    print("Keyboard layout changed")
}
```

### AsyncCGWindowManager

Async wrapper for window queries to avoid blocking.

```swift
// Get window list asynchronously
let windows = await asyncWindowManager.getVisibleWindows()

// Check if window exists without blocking
let exists = await asyncWindowManager.windowExists(windowID)

// Get Z-index mapping
let zIndexMap = await asyncWindowManager.getZIndexMapping()
```

**Key Features:**
- All operations run on background queue
- Non-blocking window server queries
- Actor-isolated for thread safety

## Migration Patterns

### Before: Blocking Run Loop

```swift
// Old pattern - blocks the thread
func start() {
    setupEventTap()
    CFRunLoopRun()  // Blocks forever!
}
```

### After: Async Streams

```swift
// New pattern - concurrent event processing
func start() async {
    await withTaskGroup(of: Void.self) { group in
        // Monitor CGEvents
        group.addTask {
            for await event in CGEventStream.keyboard() {
                await self.handleEvent(event)
            }
        }

        // Monitor HID events
        group.addTask {
            for await event in HIDEventStream.keyboard() {
                await self.handleHIDEvent(event)
            }
        }

        // Monitor workspace notifications
        group.addTask {
            for await event in WorkspaceNotificationStream.applicationLifecycle() {
                await self.handleWorkspaceEvent(event)
            }
        }
    }
}
```

### Threading Model

```
┌─────────────────┐
│   Main Thread   │  ← Your application code (async/await)
│   (non-blocking)│
└────────┬────────┘
         │
         │  AsyncStream events flow up
         │
         ├──────────┬──────────┬──────────┐
         │          │          │          │
    ┌────▼─────┐┌──▼────┐┌────▼────┐┌────▼────┐
    │ CGEvent  ││  HID  ││   AX    ││   AX    │
    │ Stream   ││Stream ││Observer ││Observer │
    │          ││       ││  (app1) ││  (app2) │
    └────┬─────┘└───┬───┘└────┬────┘└────┬────┘
         │          │         │          │
         └──────────┴─────────┴──────────┘
                    │
         ┌──────────▼──────────┐
         │  SHARED RUN LOOP    │  ← Single dedicated thread
         │      THREAD         │     for all CF-based sources
         │                     │
         │  - CFRunLoop        │
         │  - CGEvent source   │
         │  - HID source       │
         │  - AX sources       │
         └─────────────────────┘
```

**Benefits:**
- **Single thread** for all CF/CG run loop sources (efficient!)
- Multiple CFRunLoopSource objects can share one run loop
- Your code uses modern async/await (no run loop blocking)
- Events flow through type-safe async sequences
- Automatic thread management and cleanup
- Minimal overhead - no thread per stream

## Performance Considerations

1. **Shared Thread**: All CF-based streams share one run loop thread (efficient - no thread overhead per stream!)
2. **Event Batching**: Consider debouncing high-frequency events
3. **Backpressure**: AsyncStream automatically handles backpressure
4. **QoS**: Background queues use appropriate Quality of Service levels
5. **Scalability**: You can create many streams without thread proliferation

## Error Handling

Streams handle errors gracefully:
- Failed setup completes the stream with no events
- Errors are logged for debugging
- Streams can be recreated if needed

## Best Practices

1. **Store Stream Tasks**: Keep references to prevent premature cancellation

```swift
class MyMonitor {
    private var eventTask: Task<Void, Never>?

    func start() {
        eventTask = Task {
            for await event in CGEventStream.keyboard() {
                await handleEvent(event)
            }
        }
    }

    func stop() {
        eventTask?.cancel()
    }
}
```

2. **Use Actors for State**: Protect shared state with actors

```swift
actor EventProcessor {
    private var eventCount = 0

    func process(_ event: CGEvent) {
        eventCount += 1
    }
}
```

3. **Structured Concurrency**: Use task groups for multiple streams

```swift
await withTaskGroup(of: Void.self) { group in
    group.addTask { /* stream 1 */ }
    group.addTask { /* stream 2 */ }
}
```

## Migration Checklist

- [ ] Replace `CFRunLoopRun()` with async stream loops
- [ ] Move event taps to `CGEventStream`
- [ ] Move HID monitoring to `HIDEventStream`
- [ ] Move AX observers to `AXObserverStream`
- [ ] Move workspace notifications to `WorkspaceNotificationStream`
- [ ] Replace synchronous `CGWindowListCopyWindowInfo` with `AsyncCGWindowManager`
- [ ] Update tests to use async/await
- [ ] Remove manual run loop management code
- [ ] Add proper task cancellation in cleanup

## Compatibility

All async streams are compatible with:
- macOS 10.15+ (async/await requirement)
- SwiftUI and Combine (via @MainActor)
- Existing CF/CG APIs (wraps them internally)

The streams internally use CF run loops on dedicated threads, so they maintain full compatibility with Core Foundation and Core Graphics APIs while providing a modern Swift interface.
