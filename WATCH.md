# Detecting Navigation/Content Load Completion on macOS

This document covers approaches for detecting when UI content has finished loading after navigation using the macOS Accessibility API.

## Available AX Notifications

The most relevant notifications for detecting content changes:

| Notification | Description |
|-------------|-------------|
| `kAXElementBusyChangedNotification` | Fires when an element's busy state changes (best for browsers) |
| `kAXLayoutChangedNotification` | Fires when UI structure changes |
| `kAXValueChangedNotification` | Fires when element value changes |
| `kAXCreatedNotification` | Fires when new elements are created |
| `kAXUIElementDestroyedNotification` | Fires when elements are removed |
| `kAXTitleChangedNotification` | Fires when window/element title changes |
| `kAXSelectedChildrenChangedNotification` | Fires when selection changes |
| `kAXRowCountChangedNotification` | Fires when table row count changes |

## Approaches by App Type

### Web Browsers (Safari, Chrome)

Browsers expose loading state through the `AXBusy` attribute on `AXWebArea` elements.

```bash
# Poll AXBusy attribute on web content area
# When AXBusy transitions from true to false, page has loaded
```

Can also watch for:
- `kAXElementBusyChangedNotification` on the web area
- `kAXTitleChangedNotification` on the window (title changes when page loads)

### Native Apps (Music, Apple TV, etc.)

Native apps do **not** expose `AXBusy`. Content loads asynchronously without a single "done" signal.

**Option 1: Wait for specific element**
```bash
# After navigation, poll until expected element appears
while ! kbdcmd walker --app Music | grep -q 'description="Album Name"'; do
  sleep 0.3
done
```

**Option 2: Stabilization polling**
```bash
# Wait until accessibility tree stops changing
prev=""
stable=0
while [ $stable -lt 3 ]; do
  curr=$(kbdcmd walker --app Music --max-depth 3 2>/dev/null | md5)
  if [ "$curr" = "$prev" ]; then
    stable=$((stable + 1))
  else
    stable=0
    prev="$curr"
  fi
  sleep 0.2
done
```

**Option 3: Watch for element count to stabilize**
```bash
# Wait until number of interactive elements stabilizes
prev=0
while true; do
  count=$(kbdcmd walker --app Music --action | grep -c 'action:AXPress')
  [ "$count" -eq "$prev" ] && [ "$count" -gt 0 ] && break
  prev="$count"
  sleep 0.3
done
```

## Using AXObserver (Programmatic)

For real-time notification-based detection:

```swift
import ApplicationServices

// Create observer for target app
var observer: AXObserver?
AXObserverCreate(pid, { (observer, element, notification, refcon) in
    print("Notification: \(notification)")
}, &observer)

// Register for notifications
let app = AXUIElementCreateApplication(pid)
AXObserverAddNotification(observer!, app, kAXLayoutChangedNotification as CFString, nil)

// Critical: add to run loop
CFRunLoopAddSource(
    CFRunLoopGetCurrent(),
    AXObserverGetRunLoopSource(observer!),
    .commonModes
)
```

Key notifications to watch:
- `kAXLayoutChangedNotification` - structure changes
- `kAXCreatedNotification` - new elements
- `kAXValueChangedNotification` - content updates

## Practical Recommendations

1. **For browsers**: Use `AXBusy` attribute polling or `kAXElementBusyChangedNotification`

2. **For native apps**: Use stabilization pattern with timeout
   - Wait fixed time (0.5-1s) for initial load
   - Then poll until tree stabilizes or expected element appears

3. **For automation scripts**: Combine approaches
   ```bash
   # Click, wait initial load, verify content
   kbdcmd perform --click -- 500,400
   sleep 1
   kbdcmd walker --app AppName | grep -q "Expected Content" || sleep 1
   ```

## Key Insight

Native macOS apps don't have a "page load" concept like browsers. Content loads in chunks (images, metadata, etc.) and the accessibility tree keeps evolving. There is no universal "loading complete" signal - you must detect stability or presence of expected elements.

## References

- [AXObserverAddNotification - Apple Developer](https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification)
- [kAXValueChangedNotification - Apple Developer](https://developer.apple.com/documentation/applicationservices/kaxvaluechangednotification)
- [Hammerspoon hs.axuielement.observer](https://www.hammerspoon.org/docs/hs.axuielement.observer.html)
- [Accessibility for AppKit - Apple Developer](https://developer.apple.com/documentation/appkit/accessibility-for-appkit)
