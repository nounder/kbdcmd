import Cocoa
import ApplicationServices

func handleTimeoutAlarm() {
    print("Execution timeout. Exiting...")
    exit(1)
}
func openSystemPreferencesToAccessibility() {
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    NSWorkspace.shared.open(url)
}

func checkAccessibilityPermissions() {
    if !AXIsProcessTrusted() {
        print("Error: This application doesn't have the required accessibility permissions.")
        print("Please grant accessibility permissions to Terminal (or your development environment) in:")
        print("System Preferences > Security & Privacy > Privacy > Accessibility")
        openSystemPreferencesToAccessibility()
        exit(1)
    }
}

func simulateKeyPress(keyCode: CGKeyCode, flags: CGEventFlags) {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }
    
    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
    
    keyDown.flags = flags
    keyUp.flags = flags
    
    keyDown.post(tap: .cghidEventTap)
    usleep(1000) // Small delay to ensure the event is processed
    keyUp.post(tap: .cghidEventTap)
}

func cycleAppWindows() {
    simulateKeyPress(keyCode: 0x32, flags: .maskCommand) // 0x32 is the keycode for `
    print("Simulated Cmd + ` key press to cycle windows")
}

func createNewWindow(for pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    
    var menuBar: AnyObject?
    let result = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBar)
    
    guard result == .success, 
          let menuBarElement = menuBar, 
          CFGetTypeID(menuBarElement) == AXUIElementGetTypeID() else {
        print("Failed to get menu bar. AXError: \(result.rawValue)")
        return
    }
    
    let menuBarAXElement = menuBarElement as! AXUIElement
    let newWindowCommand = "New Window" as CFString
    let actionResult = AXUIElementPerformAction(menuBarAXElement, newWindowCommand)
    
    if actionResult == .success {
        print("Successfully created a new window")
    } else {
        print("Failed to create new window. AXError: \(actionResult.rawValue)")
    }
}

func switchToDesktop(number: Int) -> Int {
    guard (1...9).contains(number) else {
        print("Error: Invalid desktop number. Must be between 1 and 9.")
        return -1
    }
    
    // Simulate Control + Option + Command + Up Arrow to enter Mission Control
    simulateKeyPress(keyCode: 0x7E, flags: [.maskControl, .maskAlternate, .maskCommand]) // 0x7E is Up Arrow
    
    // Wait for Mission Control to open
    usleep(100000)
    
    // Simulate pressing the number key for the desired desktop
    let desktopKeyCode = CGKeyCode(0x12 + (number - 1)) // 0x12 is '1' key
    simulateKeyPress(keyCode: desktopKeyCode, flags: .maskControl)
    
    print("Switched to desktop \(number)")
    return 0
}

func openOrFocusApp(_ appPath: String) -> Int {
    let workspace = NSWorkspace.shared
    let fileManager = FileManager.default
    
    // Ensure the path exists and is an app bundle
    guard fileManager.fileExists(atPath: appPath),
          appPath.hasSuffix(".app") else {
        print("Invalid application path")
        return 404
    }
    
    let appURL = URL(fileURLWithPath: appPath)
    
    // Check if the app is already running
    if let runningApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL == appURL }) {
        if runningApp.isActive {
            createNewWindow(for: runningApp.processIdentifier)
            return 201
        } else {
            runningApp.activate(options: .activateIgnoringOtherApps)
            return 202
        }
    }
    
    // If not running, launch the app
    do {
        try workspace.launchApplication(at: appURL, options: [], configuration: [:])
        return 201
    } catch {
        print("Failed to launch the application: \(error)")
        return 500
    }
}

func launchApp(at url: URL) {
    do {
        try NSWorkspace.shared.launchApplication(at: url, options: [], configuration: [:])
    } catch {
        print("Failed to launch the application: \(error)")
    }
}

func cmdCycleWindows() {
    cycleAppWindows()
}

func cmdOpen(_ appName: String) {
    _ = openOrFocusApp(appName)
}

func cmdOpenCycle(_ appName: String) {
    let status = openOrFocusApp(appName)
    
    if status == 201 || status == 202 {
        cycleAppWindows()
    }
}

func cmdSwitchDesktop(_ desktopNumber: String) {
    guard let number = Int(desktopNumber) else {
        print("Error: Please specify a valid desktop number")
        return
    }
    _ = switchToDesktop(number: number)
}

func executeCommand(_ args: [String]) -> Int {
    let commands: [String: ([String]) -> Void] = [
        "open": { cmdOpen($0[2]) },
        "cycle": { _ in cmdCycleWindows() },
        "open-cycle": { cmdOpenCycle($0[2]) },
        "switch-desktop": { cmdSwitchDesktop($0[2]) }
    ]
    
    guard args.count > 1, let command = commands[args[1]] else {
        print("Available commands: \(commands.keys.joined(separator: " "))")
        return 1
    }
    
    checkAccessibilityPermissions()
    command(args)
    return 0
}

signal(SIGALRM, { _ in handleTimeoutAlarm() })
alarm(1)

let args = CommandLine.arguments
exit(Int32(executeCommand(args)))
