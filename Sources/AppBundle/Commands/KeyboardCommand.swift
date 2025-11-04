import ArgumentParser
import Carbon
import Cocoa
import Foundation
import IOKit.hid
import InputMethodKit

struct KeyboardCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keyboard",
        abstract: "Monitor all keyboard events from HID and CG sources"
    )

    @Flag(name: .long, help: "Monitor HID events from keyboard devices")
    var hid: Bool = false

    @Flag(name: .long, help: "Monitor CG (Core Graphics) event tap events")
    var cg: Bool = false

    @Flag(name: .long, help: "Monitor input source changes")
    var inputSource: Bool = false

    @Flag(name: .long, help: "Monitor device connection/disconnection events")
    var devices: Bool = false

    // MARK: - Data Structures

    struct DeviceInfo {
        let product: String
        let vendor: String
        let vendorID: Int
        let productID: Int
        let locationID: String
        let transport: String
    }

    struct HIDEvent {
        let timestamp: Date
        let hidTimestamp: UInt64
        let source: DeviceInfo

        // Element information

        /// Usage Page: A high-level category defining the type of HID control.
        /// Common values:
        /// - 0x01: Generic Desktop (system power, sleep)
        /// - 0x07: Keyboard/Keypad (all keyboard keys and LEDs)
        /// - 0x08: LEDs (Num Lock, Caps Lock, Scroll Lock)
        /// - 0x0C: Consumer (media controls: volume, play/pause, brightness)
        /// See USB HID Usage Tables specification for complete list.
        let usagePage: UInt32

        /// Usage: A specific control within the usage page.
        /// For Keyboard/Keypad page (0x07):
        /// - 0x04-0x1D: Letters A-Z
        /// - 0x1E-0x27: Numbers 1-0
        /// - 0xE0-0xE7: Modifier keys (Ctrl, Shift, Alt, GUI/Command)
        /// - 0x39: Caps Lock
        /// - 0x53: Num Lock
        /// Usage values are defined per usage page in the USB HID Usage Tables.
        let usage: UInt32

        /// Element Cookie: A unique identifier for this specific element on this device.
        /// Used to distinguish between different controls that might share the same usage.
        /// For example, a keyboard might have multiple vendor-specific keys with the same usage code,
        /// but each will have a unique cookie. Cookies are persistent across connections
        /// for the same physical device.
        let elementCookie: IOHIDElementCookie

        let elementType: IOHIDElementType

        // Value information
        let integerValue: CFIndex
        let length: CFIndex
        let logicalMin: CFIndex
        let logicalMax: CFIndex
        let physicalMin: CFIndex
        let physicalMax: CFIndex

        // Derived properties
        var isPressed: Bool { integerValue != 0 }
        var scaledValue: Double? {
            guard logicalMax > logicalMin else { return nil }
            let range = Double(logicalMax - logicalMin)
            let value = Double(integerValue - logicalMin)
            return value / range
        }

        var eventCategory: EventCategory {
            switch usagePage {
            case UInt32(kHIDPage_KeyboardOrKeypad):
                if usage >= 0xE0 && usage <= 0xE7 {
                    return .modifierKey
                } else if usage >= 0x04 && usage <= 0xA4 {
                    return .standardKey
                } else {
                    return .keyboardOther
                }
            case UInt32(kHIDPage_Consumer):
                return .consumerControl
            case UInt32(kHIDPage_GenericDesktop):
                return .systemControl
            case UInt32(kHIDPage_LEDs):
                return .led
            default:
                return .other
            }
        }

        enum EventCategory: String {
            case standardKey = "StandardKey"
            case modifierKey = "ModifierKey"
            case keyboardOther = "KeyboardOther"
            case consumerControl = "ConsumerControl"
            case systemControl = "SystemControl"
            case led = "LED"
            case other = "Other"
        }
    }

    struct CGEventData {
        let timestamp: Date
        let eventType: CGEventType
        let keyCode: Int64
        let flags: CGEventFlags
        let cgTimestamp: CGEventTimestamp
        let sourcePID: Int64
        let processName: String
        let eventSourceStateID: Int64
    }

    struct DeviceChangeEvent {
        let timestamp: Date
        let changeType: ChangeType
        let device: DeviceInfo

        enum ChangeType {
            case connected
            case disconnected
        }
    }

    struct InputSourceChangeEvent {
        let timestamp: Date
        let sourceID: String
        let localizedName: String
        let languages: String
    }

    // MARK: - Monitor State

    final class MonitorState {
        var hidManager: IOHIDManager?
        var eventTap: CFMachPort?
        var cgRunLoopSource: CFRunLoopSource?
        var inputSourceObserver: NSObjectProtocol?

        let shouldMonitorDevices: Bool
        let shouldMonitorHID: Bool

        init(shouldMonitorDevices: Bool, shouldMonitorHID: Bool) {
            self.shouldMonitorDevices = shouldMonitorDevices
            self.shouldMonitorHID = shouldMonitorHID
        }

        deinit {
            teardown()
        }

        func teardown() {
            // Remove input source observer
            if let observer = inputSourceObserver {
                DistributedNotificationCenter.default().removeObserver(observer)
                inputSourceObserver = nil
            }

            // Disable and remove CG event tap
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
                eventTap = nil
            }

            if let source = cgRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
                cgRunLoopSource = nil
            }

            // Close and unschedule HID manager
            if let manager = hidManager {
                IOHIDManagerUnscheduleFromRunLoop(
                    manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                hidManager = nil
            }
        }
    }

    func run() throws {
        try Permissions.checkAccessibility()

        // If no flags specified, enable all monitors
        let enableAll = !hid && !cg && !inputSource && !devices
        let shouldMonitorHID = enableAll || hid
        let shouldMonitorCG = enableAll || cg
        let shouldMonitorInputSource = enableAll || inputSource
        let shouldMonitorDevices = enableAll || devices

        print("=== Keyboard Event Monitor Started ===")
        print("Monitoring:")
        if shouldMonitorHID { print("  - HID events") }
        if shouldMonitorCG { print("  - CG events") }
        if shouldMonitorInputSource { print("  - Input source changes") }
        if shouldMonitorDevices { print("  - Device connections/disconnections") }
        print()

        let state = MonitorState(
            shouldMonitorDevices: shouldMonitorDevices,
            shouldMonitorHID: shouldMonitorHID
        )

        // Setup HID Manager (for HID events and device monitoring)
        if shouldMonitorHID || shouldMonitorDevices {
            setupHIDManager(state: state)
            printCurrentDevices(state: state)
        }

        // Setup Input Source Change Observer
        if shouldMonitorInputSource {
            setupInputSourceObserver(state: state)
        }

        // Setup CG Event Tap
        if shouldMonitorCG {
            setupCGEventTap(state: state)
        }

        // Setup signal handler for clean shutdown
        signal(SIGINT) { _ in
            print("\n=== Shutting down ===")
            CFRunLoopStop(CFRunLoopGetCurrent())
        }

        print("\n=== Monitoring keyboard events (Press Ctrl+C to stop) ===\n")

        // Run the event loop
        CFRunLoopRun()

        // Cleanup
        state.teardown()
        print("\n=== Cleanup complete ===")
    }

    private func setupHIDManager(state: MonitorState) {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        state.hidManager = manager

        // Match keyboard devices
        let deviceMatching =
            [
                [
                    kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                    kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
                ] as [String: Any]
            ] as CFArray

        IOHIDManagerSetDeviceMatchingMultiple(manager, deviceMatching)

        // Pass state as context to callbacks
        let contextPtr = Unmanaged.passUnretained(state).toOpaque()

        // Register device matching callback
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            { context, result, sender, device in
                guard let context = context else { return }
                let state = Unmanaged<MonitorState>.fromOpaque(context).takeUnretainedValue()
                KeyboardCommand.handleDeviceMatching(
                    state: state, result: result, sender: sender, device: device)
            },
            contextPtr
        )

        // Register device removal callback
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            { context, result, sender, device in
                guard let context = context else { return }
                let state = Unmanaged<MonitorState>.fromOpaque(context).takeUnretainedValue()
                KeyboardCommand.handleDeviceRemoval(
                    state: state, result: result, sender: sender, device: device)
            },
            contextPtr
        )

        // Register input value callback
        IOHIDManagerRegisterInputValueCallback(
            manager,
            { context, result, sender, value in
                guard let context = context else { return }
                let state = Unmanaged<MonitorState>.fromOpaque(context).takeUnretainedValue()
                KeyboardCommand.handleInputValue(
                    state: state, result: result, sender: sender, value: value)
            },
            contextPtr
        )

        // Schedule with run loop
        IOHIDManagerScheduleWithRunLoop(
            manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        // Open the manager
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult != kIOReturnSuccess {
            print("ERROR: Failed to open IOHIDManager: \(openResult)")
        }
    }

    private func setupInputSourceObserver(state: MonitorState) {
        state.inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(
                rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { notification in
            KeyboardCommand.handleInputSourceChange(notification: notification)
        }
    }

    private func setupCGEventTap(state: MonitorState) {
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: eventMask,
                callback: { proxy, type, event, refcon in
                    let _ = KeyboardCommand.handleCGEvent(proxy: proxy, type: type, event: event)
                    return Unmanaged.passRetained(event)
                },
                userInfo: nil
            )
        else {
            print("ERROR: Failed to create CG event tap")
            return
        }

        state.eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        state.cgRunLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func getCurrentDevices(state: MonitorState) -> [DeviceInfo] {
        guard let manager = state.hidManager else { return [] }

        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        return devices.map { Self.extractDeviceInfo($0) }
    }

    private func printCurrentDevices(state: MonitorState) {
        let devices = getCurrentDevices(state: state)
        print("=== Connected Keyboards (\(devices.count)) ===")

        for device in devices {
            print(formatDeviceInfo(device))
        }
        print()
    }

    private func formatDeviceInfo(_ info: DeviceInfo) -> String {
        return """
            [Keyboard] \(info.product)
              - Vendor: \(info.vendor) (ID: \(info.vendorID))
              - Product ID: \(info.productID)
              - Location: \(info.locationID)
              - Transport: \(info.transport)
            """
    }

    // MARK: - Static Callback Handlers

    private static func handleDeviceMatching(
        state: MonitorState, result: IOReturn, sender: UnsafeMutableRawPointer?,
        device: IOHIDDevice
    ) {
        guard state.shouldMonitorDevices else { return }
        let event = createDeviceChangeEvent(device: device, changeType: .connected)
        print(formatDeviceChangeEvent(event))
    }

    private static func handleDeviceRemoval(
        state: MonitorState, result: IOReturn, sender: UnsafeMutableRawPointer?,
        device: IOHIDDevice
    ) {
        guard state.shouldMonitorDevices else { return }
        let event = createDeviceChangeEvent(device: device, changeType: .disconnected)
        print(formatDeviceChangeEvent(event))
    }

    private static func createDeviceChangeEvent(
        device: IOHIDDevice, changeType: DeviceChangeEvent.ChangeType
    ) -> DeviceChangeEvent {
        return DeviceChangeEvent(
            timestamp: Date(),
            changeType: changeType,
            device: extractDeviceInfo(device)
        )
    }

    private static func formatDeviceChangeEvent(_ event: DeviceChangeEvent) -> String {
        let timestamp = ISO8601DateFormatter().string(from: event.timestamp)
        let changeTypeStr =
            event.changeType == .connected ? "DEVICE_CONNECTED" : "DEVICE_DISCONNECTED"

        return """
            [\(timestamp)] [\(changeTypeStr)]
              Product: \(event.device.product)
              Vendor: \(event.device.vendor) (ID: \(event.device.vendorID))
              Product ID: \(event.device.productID)
              Location: \(event.device.locationID)
              Transport: \(event.device.transport)
            """
    }

    private static func handleInputValue(
        state: MonitorState, result: IOReturn, sender: UnsafeMutableRawPointer?,
        value: IOHIDValue
    ) {
        guard state.shouldMonitorHID else { return }

        // sender is the IOHIDDevice
        guard let sender = sender else { return }
        let device = unsafeBitCast(sender, to: IOHIDDevice.self)

        guard let hidEvent = createHIDEvent(from: value, device: device) else { return }
        print(formatHIDEvent(hidEvent))
    }

    private static func createHIDEvent(from value: IOHIDValue, device: IOHIDDevice) -> HIDEvent? {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let integerValue = IOHIDValueGetIntegerValue(value)
        let timestamp = IOHIDValueGetTimeStamp(value)
        let length = IOHIDValueGetLength(value)

        // Get element properties
        let elementType = IOHIDElementGetType(element)
        let cookie = IOHIDElementGetCookie(element)
        let logicalMin = IOHIDElementGetLogicalMin(element)
        let logicalMax = IOHIDElementGetLogicalMax(element)
        let physicalMin = IOHIDElementGetPhysicalMin(element)
        let physicalMax = IOHIDElementGetPhysicalMax(element)

        return HIDEvent(
            timestamp: Date(),
            hidTimestamp: timestamp,
            source: extractDeviceInfo(device),
            usagePage: usagePage,
            usage: usage,
            elementCookie: cookie,
            elementType: elementType,
            integerValue: integerValue,
            length: length,
            logicalMin: logicalMin,
            logicalMax: logicalMax,
            physicalMin: physicalMin,
            physicalMax: physicalMax
        )
    }

    private static func formatHIDEvent(_ event: HIDEvent) -> String {
        let timeString = ISO8601DateFormatter().string(from: event.timestamp)
        let eventTypeStr = event.isPressed ? "PRESSED" : "RELEASED"
        let elementTypeName = elementTypeToString(event.elementType)

        var output = """
            [\(timeString)] [HID_\(eventTypeStr)] [\(event.eventCategory.rawValue)]
              Usage Page: 0x\(String(event.usagePage, radix: 16))
              Usage: 0x\(String(event.usage, radix: 16)) (\(event.usage))
              Value: \(event.integerValue)
              Element Type: \(elementTypeName)
              Element Cookie: \(event.elementCookie)
              Timestamp: \(event.hidTimestamp)
              Source: \(event.source.product) [\(event.source.vendor)]
              Location: \(event.source.locationID)
            """

        // Add range information if available
        if event.logicalMax > event.logicalMin {
            output += """

                  Logical Range: \(event.logicalMin)-\(event.logicalMax)
                  Physical Range: \(event.physicalMin)-\(event.physicalMax)
                """
            if let scaled = event.scaledValue {
                output += """

                      Scaled Value: \(String(format: "%.2f", scaled * 100))%
                    """
            }
        }

        return output
    }

    private static func elementTypeToString(_ type: IOHIDElementType) -> String {
        switch type {
        case kIOHIDElementTypeInput_Misc:
            return "Input_Misc"
        case kIOHIDElementTypeInput_Button:
            return "Input_Button"
        case kIOHIDElementTypeInput_Axis:
            return "Input_Axis"
        case kIOHIDElementTypeInput_ScanCodes:
            return "Input_ScanCodes"
        case kIOHIDElementTypeOutput:
            return "Output"
        case kIOHIDElementTypeFeature:
            return "Feature"
        case kIOHIDElementTypeCollection:
            return "Collection"
        default:
            return "Unknown(\(type.rawValue))"
        }
    }

    private static func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent)
        -> Unmanaged<CGEvent>?
    {
        let cgEvent = createCGEventData(type: type, event: event)
        print(formatCGEvent(cgEvent))
        return Unmanaged.passRetained(event)
    }

    private static func createCGEventData(type: CGEventType, event: CGEvent) -> CGEventData {
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)

        return CGEventData(
            timestamp: Date(),
            eventType: type,
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            flags: event.flags,
            cgTimestamp: event.timestamp,
            sourcePID: sourcePID,
            processName: getProcessName(pid: pid_t(sourcePID)),
            eventSourceStateID: event.getIntegerValueField(.eventSourceStateID)
        )
    }

    private static func formatCGEvent(_ event: CGEventData) -> String {
        let timeString = ISO8601DateFormatter().string(from: event.timestamp)

        let eventTypeName: String
        switch event.eventType {
        case .keyDown:
            eventTypeName = "KEY_DOWN"
        case .keyUp:
            eventTypeName = "KEY_UP"
        case .flagsChanged:
            eventTypeName = "FLAGS_CHANGED"
        default:
            eventTypeName = "UNKNOWN(\(event.eventType.rawValue))"
        }

        return """
            [\(timeString)] [CG_\(eventTypeName)]
              KeyCode: \(event.keyCode)
              Flags: 0x\(String(event.flags.rawValue, radix: 16))
              Timestamp: \(event.cgTimestamp)
              Source PID: \(event.sourcePID) [\(event.processName)]
              State ID: \(event.eventSourceStateID)
            """
    }

    private static func handleInputSourceChange(notification: Notification) {
        guard let event = createInputSourceChangeEvent() else { return }
        print(formatInputSourceChangeEvent(event))
    }

    private static func createInputSourceChangeEvent() -> InputSourceChangeEvent? {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }

        return InputSourceChangeEvent(
            timestamp: Date(),
            sourceID: getInputSourceProperty(inputSource, kTISPropertyInputSourceID),
            localizedName: getInputSourceProperty(inputSource, kTISPropertyLocalizedName),
            languages: getInputSourceProperty(inputSource, kTISPropertyInputSourceLanguages)
        )
    }

    private static func formatInputSourceChangeEvent(_ event: InputSourceChangeEvent) -> String {
        let timeString = ISO8601DateFormatter().string(from: event.timestamp)
        return """
            [\(timeString)] [INPUT_SOURCE_CHANGED]
              Source ID: \(event.sourceID)
              Name: \(event.localizedName)
              Languages: \(event.languages)
            """
    }

    // MARK: - Helper Methods

    private static func extractDeviceInfo(_ device: IOHIDDevice) -> DeviceInfo {
        let product =
            IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
        let vendor =
            IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String
            ?? "Unknown"
        let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let locationID =
            IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int ?? 0
        let transport =
            IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "Unknown"

        return DeviceInfo(
            product: product,
            vendor: vendor,
            vendorID: vendorID,
            productID: productID,
            locationID: "0x\(String(locationID, radix: 16))",
            transport: transport
        )
    }

    private static func getProcessName(pid: pid_t) -> String {
        guard pid > 0 else { return "Unknown" }

        let runningApps = NSWorkspace.shared.runningApplications
        if let app = runningApps.first(where: { $0.processIdentifier == pid }) {
            return app.localizedName ?? "Unknown"
        }

        return "PID(\(pid))"
    }

    private static func getInputSourceProperty(_ inputSource: TISInputSource, _ key: CFString)
        -> String
    {
        guard let value = TISGetInputSourceProperty(inputSource, key) else {
            return "N/A"
        }

        let cfValue = Unmanaged<CFTypeRef>.fromOpaque(value).takeUnretainedValue()

        if CFGetTypeID(cfValue) == CFStringGetTypeID() {
            return cfValue as! String
        } else if CFGetTypeID(cfValue) == CFArrayGetTypeID() {
            let array = cfValue as! CFArray as [AnyObject]
            return array.map { "\($0)" }.joined(separator: ", ")
        }

        return "\(cfValue)"
    }
}
