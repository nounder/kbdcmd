#include <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>
#include <CoreFoundation/CoreFoundation.h>

void checkAccessibilityPermissions() {
    if (!AXIsProcessTrusted()) {
        printf(
            "Error: This application doesn't have the required accessibility "
            "permissions.\n");
        printf("Please grant accessibility permissions to Terminal (or your "
               "development environment) in:\n");
        printf("System Preferences > Security & Privacy > Privacy > "
               "Accessibility\n");
        exit(1);
    }
}

void simulateKeyPress(CGKeyCode keyCode, bool commandKey) {
    CGEventSourceRef source =
        CGEventSourceCreate(kCGEventSourceStateHIDSystemState);

    CGEventRef keyDown = CGEventCreateKeyboardEvent(source, keyCode, true);
    CGEventRef keyUp = CGEventCreateKeyboardEvent(source, keyCode, false);

    if (commandKey) {
        CGEventSetFlags(keyDown, kCGEventFlagMaskCommand);
        CGEventSetFlags(keyUp, kCGEventFlagMaskCommand);
    }

    CGEventPost(kCGHIDEventTap, keyDown);
    usleep(1000); // Small delay to ensure the event is processed
    CGEventPost(kCGHIDEventTap, keyUp);

    CFRelease(keyDown);
    CFRelease(keyUp);
    CFRelease(source);
}

void cycle_windows(pid_t pid) {
    simulateKeyPress(kVK_ANSI_Grave, true);
    printf("Simulated Cmd + ` key press to cycle windows\n");
}

pid_t get_focused_app_pid() {
    pid_t focusedPID = 0;
    ProcessSerialNumber psn = {0, kNoProcess};
    OSErr err = GetFrontProcess(&psn);

    if (err == noErr) {
        err = GetProcessPID(&psn, &focusedPID);
        if (err == noErr) {
            return focusedPID;
        }
    }

    // Return 0 if we failed to get the PID
    return 0;
}

/**
 * Create new window for application with the given PID
 */
void create_new_window(pid_t pid) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (app == NULL) {
        printf("Failed to create accessibility element for application\n");
        return;
    }

    AXUIElementRef button = NULL;
    AXError result = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute,
                                                   (CFTypeRef *)&button);
    if (result != kAXErrorSuccess) {
        printf("Failed to get menu bar. AXError: %d\n", result);
        CFRelease(app);
        return;
    }

    CFStringRef newWindowCommand = CFSTR("New Window");
    result = AXUIElementPerformAction(button, newWindowCommand);
    if (result != kAXErrorSuccess) {
        printf("Failed to create new window. AXError: %d\n", result);
    } else {
        printf("Successfully created a new window\n");
    }

    CFRelease(button);
    CFRelease(app);
}

void open_or_focus_app(const char *appName) {
    checkAccessibilityPermissions();

    CFStringRef appNameStr =
        CFStringCreateWithCString(NULL, appName, kCFStringEncodingUTF8);
    CFURLRef appURL = CFURLCreateWithFileSystemPath(NULL, appNameStr,
                                                    kCFURLPOSIXPathStyle, true);

    LSLaunchURLSpec launchSpec = {0};
    launchSpec.appURL = appURL;
    launchSpec.launchFlags = kLSLaunchDefaults;

    OSStatus status;
    FSRef outFSRef;
    status = LSOpenFromURLSpec(&launchSpec, &outFSRef);

    printf("DEBUG: LSOpenFromURLSpec status: %d\n", (int)status);

    ProcessSerialNumber psn = {0, kNoProcess};
    pid_t targetPID = 0;
    Boolean appFound = false;

    while (GetNextProcess(&psn) == noErr) {
        CFStringRef processName;
        if (CopyProcessName(&psn, &processName) == noErr) {
            if (CFStringCompare(processName, appNameStr, 0) ==
                kCFCompareEqualTo) {
                GetProcessPID(&psn, &targetPID);
                appFound = true;
                CFRelease(processName);
                break;
            }
            CFRelease(processName);
        }
    }

    printf("DEBUG: App found: %s, PID: %d\n", appFound ? "Yes" : "No",
           (int)targetPID);

    if (appFound) {
        pid_t frontPID = get_focused_app_pid();
        printf("DEBUG: Front app PID: %d\n", (int)frontPID);

        AXUIElementRef app = AXUIElementCreateApplication(targetPID);
        if (app != NULL) {
            CFArrayRef windows;
            AXError result = AXUIElementCopyAttributeValue(
                app, kAXWindowsAttribute, (CFTypeRef *)&windows);
            if (result == kAXErrorSuccess) {
                CFIndex windowCount = CFArrayGetCount(windows);
                printf("DEBUG: Window count: %ld\n", windowCount);

                if (windowCount == 0) {
                    printf("DEBUG: Creating new window\n");
                    create_new_window(targetPID);
                } else if (frontPID != targetPID) {
                    printf("DEBUG: Bringing app to front\n");
                    SetFrontProcessWithOptions(&psn,
                                               kSetFrontProcessFrontWindowOnly);
                } else {
                    printf("DEBUG: Cycling windows\n");
                    cycle_windows(targetPID);
                }
                CFRelease(windows);
            } else {
                printf("Failed to get windows. AXError: %d\n", result);
            }
            CFRelease(app);
        }
        printf("Action completed for the application.\n");
    } else {
        printf("Failed to find or launch the application.\n");
    }

    CFRelease(appNameStr);
    CFRelease(appURL);
}

int main(int argc, const char *argv[]) {
    if (argc > 1) {
        if (strcmp(argv[1], "open_or_focus") == 0 && argc > 2) {
            open_or_focus_app(argv[2]);
        } else if (strcmp(argv[1], "get_focused_pid") == 0) {
            pid_t focusedPID = get_focused_app_pid();
            if (focusedPID != 0) {
                printf("Focused app PID: %d\n", focusedPID);
            } else {
                printf("Failed to get focused app PID.\n");
            }
        } else if (strcmp(argv[1], "cycle_windows") == 0) {
            pid_t focusedPID = get_focused_app_pid();
            if (focusedPID != 0) {
                cycle_windows(focusedPID);
            } else {
                printf("Failed to get focused app PID.\n");
            }
        } else {
            printf("Invalid function or missing arguments.");
        }
    } else {
        printf("No function provided.");
    }
    return 0;
}
