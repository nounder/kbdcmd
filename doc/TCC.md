# macOS TCC (Transparency, Consent, and Control)

Documentation on how macOS handles accessibility permissions and common issues.

## Overview

TCC is macOS's framework for controlling application access to sensitive resources like accessibility, camera, microphone, and full disk access. TCC stores permissions in SQLite databases and uses code signing to validate app identity.

## How macOS Validates App Identity

macOS uses multi-factor validation:

### Primary: Code Signing Requirement (csreq)

The `csreq` field in TCC.db contains a binary blob encoding requirements like:

```
identifier "com.example.app" and anchor apple generic and
certificate leaf[subject.OU] = TEAM_ID
```

This requires:
- **Bundle identifier match**: The app's CFBundleIdentifier
- **Certificate chain validation**: Signed by Apple or valid Developer ID
- **Team ID verification**: The developer's organizational unit

### Secondary: Bundle ID and Path

- **client**: The bundle identifier or absolute path
- **client_type**: Integer indicating bundle ID (0) or path (1)

## The Stale Signature Problem

### What Happens When Permission is Granted

TCC creates a row in the `access` table:

```sql
service = 'kTCCServiceAccessibility'
client = 'com.example.app'
client_type = 0          -- bundle ID
auth_value = 2           -- allowed (0=denied, 1=unknown, 2=allowed, 3=limited)
auth_reason = 3          -- user set
csreq = [binary blob]    -- designated requirement captured at grant time
```

### What Happens When App is Rebuilt

When an app is rebuilt with a different signature (common during development):

1. The TCC database entry remains unchanged
2. `auth_value` still shows 2 (allowed)
3. The stored `csreq` still contains the OLD signature
4. When the app tries to use accessibility APIs, TCC validates against stored `csreq`
5. **Validation fails** - new signature doesn't match old csreq
6. Access denied despite permission appearing granted in System Settings

### Why Toggling OFF/ON Doesn't Work

| Action | auth_value | csreq |
|--------|------------|-------|
| Toggle OFF | 0 | Unchanged (stale) |
| Toggle ON | 2 | Unchanged (stale) |
| Remove + Re-add | 2 | **Fresh blob from current signature** |

Toggling only changes `auth_value`. The `csreq` blob is never refreshed - it still contains the old signature requirement.

### Why Remove + Re-add Works

When removing via minus button and re-adding via file picker:

1. **Remove**: TCC entry is deleted
2. **Re-add via file picker**: macOS creates a completely new database entry with a fresh `csreq` extracted from the current app bundle

This is the only way to refresh the csreq without using command-line tools.

## Solutions

### For Users: Manual Fix

1. Open System Settings > Privacy & Security > Accessibility
2. Find the app and click the minus (-) button to remove it
3. Restart the app (it will prompt for permission again)

### For Developers: tccutil

Reset permission for a specific bundle ID (forces fresh prompt on next launch):

```bash
tccutil reset Accessibility com.example.app
```

Note: This works on user-level TCC.db without sudo.

### For Developers: Consistent Signing

Prevent the issue by using stable code signing:

- Sign development builds with Apple Development certificate (not ad-hoc)
- Don't mix ad-hoc and Developer ID signing for the same bundle ID
- Use the same signing identity consistently

### Programmatic Detection

Detect the broken state by attempting an actual accessibility API call:

```swift
if AXIsProcessTrusted() {
    // Try a real API call to verify it actually works
    let systemWide = AXUIElementCreateSystemWide()
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(
        systemWide,
        kAXFocusedApplicationAttribute as CFString,
        &value
    )
    if error != .success {
        // Permission is stale - guide user to remove and re-add
    }
}
```

## References

- [Apple Developer Forums - macOS TCC Accessibility permission](https://developer.apple.com/forums/thread/703188)
- [Rainforest QA - A deep dive into macOS TCC.db](https://www.rainforestqa.com/blog/macos-tcc-db-deep-dive)
- [The Eclectic Light Company - TCC database woes](https://eclecticlight.co/2023/02/09/should-you-reset-its-database-or-delete-it-the-woes-of-tcc/)
