#include <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <unistd.h>

/**
 * Check if the application has the required accessibility permissions.
 * If not, quit.
 */
void CheckAccessibilityPermissions() {
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

/**
 * Simulate a key press.
 */
void SimulateKeyPress(CGKeyCode keyCode, CGEventFlags flags) {
    CGEventSourceRef source =
        CGEventSourceCreate(kCGEventSourceStateHIDSystemState);

    CGEventRef keyDown = CGEventCreateKeyboardEvent(source, keyCode, true);
    CGEventRef keyUp = CGEventCreateKeyboardEvent(source, keyCode, false);

    CGEventSetFlags(keyDown, flags);
    CGEventSetFlags(keyUp, flags);

    CGEventPost(kCGHIDEventTap, keyDown);
    usleep(1000); // Small delay to ensure the event is processed
    CGEventPost(kCGHIDEventTap, keyUp);

    CFRelease(keyDown);
    CFRelease(keyUp);
    CFRelease(source);
}

/**
 * Cycle through windows of currently open application.
 * This is equivalent to Cmd + ` key press on default macOS configuration.
 */
void CycleAppWindows() {
    SimulateKeyPress(kVK_ANSI_Grave, kCGEventFlagMaskCommand);
    printf("Simulated Cmd + ` key press to cycle windows\n");
}

/**
 * Get the PID of the currently focused application.
 */
pid_t GetFocusedAppId() {
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
 * Create new window for application with the given PID.
 */
void CreateNewWindow(pid_t pid) {
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

/**
 * Open or focus the application with the given name.
 * If the application is already open, it will be brought to the front.
 * Otherwise, it will be started.
 *
 * Returns status code:
 * 201: app opened
 * 202: app focused
 * 404: app not found
 * 500: failed
 */
int OpenOrFocusApp(const char *argv[]) {
    int statusCode = 500;

    CheckAccessibilityPermissions();
    const char *appName = argv[0];

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
        pid_t frontPID = GetFocusedAppId();
        printf("DEBUG: Front app PID: %d\n", (int)frontPID);

        AXUIElementRef app = AXUIElementCreateApplication(targetPID);

        if (app != NULL) {
            CFArrayRef windows;
            AXError result = AXUIElementCopyAttributeValue(
                app, kAXWindowsAttribute, (CFTypeRef *)&windows);
            if (result == kAXErrorSuccess) {
                CFIndex windowCount = CFArrayGetCount(windows);
                printf("DEBUG: Window count: %ld\n", windowCount);

                // No windows for the app, create a new window
                if (windowCount == 0) {
                    printf("DEBUG: Creating new window\n");

                    CreateNewWindow(targetPID);

                    statusCode = 201;
                } else if (frontPID != targetPID) {
                    printf("DEBUG: Bringing app to front\n");

                    SetFrontProcessWithOptions(&psn,
                                               kSetFrontProcessFrontWindowOnly);

                    statusCode = 202;
                }
                CFRelease(windows);
            } else {
                printf("Failed to get windows. AXError: %d\n", result);

                statusCode = 500;
            }

            CFRelease(app);
        }

        printf("Action completed for the application.\n");
    } else {
        statusCode = 500;

        printf("Failed to find or launch the application.\n");
    }

    CFRelease(appNameStr);
    CFRelease(appURL);

    return statusCode;
}

/**
 * Cycle through windows of currently open application.
 * This is equivalent to Cmd + ` key press on default macOS configuration.
 */
void cmd_cycle_windows(const char *argv[]) { CycleAppWindows(); }

/**
 * Cycle through windows of currently open application.
 * This is equivalent to Cmd + ` key press on default macOS configuration.
 */
void cmd_open(const char *argv[]) {
    const char *app = argv[2];

    OpenOrFocusApp(&app);
}

void cmd_open_cycle(const char *argv[]) {
    const char *app = argv[2];

    OpenOrFocusApp(&app);

    CycleAppWindows();
}

struct Command {
    const char *name;
    void (*function)(const char **);
};

struct Command commands[] = {
    {"open", cmd_open},
    {"cycle", cmd_cycle_windows},
    {"open-cycle", cmd_open_cycle},
    {NULL, NULL} // mark the end of the array
};

int main(int argc, const char *argv[]) {
    if (argc > 1) {
        for (struct Command *cmd = commands; cmd->name != NULL; cmd++) {
            if (strcmp(argv[1], cmd->name) == 0) {
                cmd->function(argv);

                return 0;
            }
        }
    }

    // join and print all available comamnd
    printf("Available commands: ");
    for (struct Command *cmd = commands; cmd->name != NULL; cmd++) {
        printf("%s ", cmd->name);
    }
    printf("\n");

    return 1;
}
