import Foundation
import IOKit.hid

/// A monitor for keyboard HID (Human Interface Device) events.
/// Provides callbacks for key events and device connection/disconnection events.
///
/// Usage Pages:
/// - 0x01: Generic Desktop (used for device matching - keyboards have usage 0x06)
/// - 0x07: Keyboard/Keypad (used for monitoring actual key presses)
/// - 0x08: LEDs (e.g., Caps Lock, Num Lock indicator lights)
/// - 0x0C: Consumer (media controls: volume, brightness, etc.)
///
/// For Caps Lock specifically:
/// - Usage page 0x07, usage 0x39 represents the physical Caps Lock key
final class KeyboardHIDMonitor {
  // MARK: - Public Types

  struct DeviceInfo: Equatable {
    let product: String
    let vendor: String
    let vendorID: Int
    let productID: Int
    let locationID: String
    let transport: String
  }

  enum EventKind {
    case key(usagePage: UInt32, usage: UInt32, pressed: Bool)
    case deviceConnected(DeviceInfo)
    case deviceDisconnected(DeviceInfo)
  }

  struct Event {
    let kind: EventKind
    let device: DeviceInfo
    let timestamp: Date
  }

  final class CallbackHandle {
    fileprivate let cancelClosure: () -> Void

    fileprivate init(cancelClosure: @escaping () -> Void) {
      self.cancelClosure = cancelClosure
    }

    deinit {
      cancelClosure()
    }
  }

  // MARK: - Private Types

  private struct ElementKey: Hashable {
    let deviceLocationID: String
    let usagePage: UInt32
    let usage: UInt32
  }

  // MARK: - Properties

  private let monitorKeys: Bool
  private let monitorDevices: Bool
  private let runLoop: CFRunLoop
  private let mode: CFRunLoopMode

  private var manager: IOHIDManager?
  private var keyCallbacks: [UUID: (Event) -> Void] = [:]
  private var deviceCallbacks: [UUID: (Event) -> Void] = [:]
  private var lastState: [ElementKey: Bool] = [:]
  private let queue = DispatchQueue(label: "com.kbdcmd.KeyboardHIDMonitor", qos: .userInteractive)

  // MARK: - Initialization

  init(
    monitorKeys: Bool = true,
    monitorDevices: Bool = true,
    runLoop: CFRunLoop = CFRunLoopGetCurrent(),
    mode: CFRunLoopMode = .defaultMode
  ) {
    self.monitorKeys = monitorKeys
    self.monitorDevices = monitorDevices
    self.runLoop = runLoop
    self.mode = mode
  }

  deinit {
    stop()
  }

  // MARK: - Public Methods

  func start() throws {
    guard manager == nil else {
      debugLog("KeyboardHIDMonitor already started")
      return
    }

    let newManager = IOHIDManagerCreate(
      kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    self.manager = newManager

    // Match keyboard devices (Generic Desktop usage page 0x01, Keyboard usage 0x06)
    let deviceMatching: [[String: Any]] = [
      [
        kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
        kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
      ]
    ]

    IOHIDManagerSetDeviceMatchingMultiple(newManager, deviceMatching as CFArray)

    // Pass self as context to callbacks
    let contextPtr = Unmanaged.passUnretained(self).toOpaque()

    // Register device matching callback
    if monitorDevices {
      IOHIDManagerRegisterDeviceMatchingCallback(
        newManager,
        { context, result, sender, device in
          guard let context = context else { return }
          let monitor = Unmanaged<KeyboardHIDMonitor>.fromOpaque(context)
            .takeUnretainedValue()
          monitor.handleDeviceMatching(device: device)
        },
        contextPtr
      )
    }

    // Register device removal callback
    if monitorDevices {
      IOHIDManagerRegisterDeviceRemovalCallback(
        newManager,
        { context, result, sender, device in
          guard let context = context else { return }
          let monitor = Unmanaged<KeyboardHIDMonitor>.fromOpaque(context)
            .takeUnretainedValue()
          monitor.handleDeviceRemoval(device: device)
        },
        contextPtr
      )
    }

    // Register input value callback for key events
    if monitorKeys {
      IOHIDManagerRegisterInputValueCallback(
        newManager,
        { context, result, sender, value in
          guard let context = context else { return }
          let monitor = Unmanaged<KeyboardHIDMonitor>.fromOpaque(context)
            .takeUnretainedValue()
          guard let sender = sender else { return }
          let device = unsafeBitCast(sender, to: IOHIDDevice.self)
          monitor.handleInputValue(value: value, device: device)
        },
        contextPtr
      )
    }

    // Schedule with run loop
    IOHIDManagerScheduleWithRunLoop(newManager, runLoop, mode.rawValue as CFString)

    // Open the manager
    let openResult = IOHIDManagerOpen(newManager, IOOptionBits(kIOHIDOptionsTypeNone))
    if openResult != kIOReturnSuccess {
      throw NSError(
        domain: "KeyboardHIDMonitor", code: Int(openResult),
        userInfo: [NSLocalizedDescriptionKey: "Failed to open IOHIDManager"])
    }

    debugLog("KeyboardHIDMonitor started successfully")
  }

  func stop() {
    guard let manager = manager else { return }

    // Unschedule from run loop
    IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, mode.rawValue as CFString)

    // Close the manager
    IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))

    // Clear state
    queue.sync {
      self.keyCallbacks.removeAll()
      self.deviceCallbacks.removeAll()
      self.lastState.removeAll()
    }

    self.manager = nil
    debugLog("KeyboardHIDMonitor stopped")
  }

  @discardableResult
  func onKeyEvent(_ callback: @escaping (Event) -> Void) -> CallbackHandle {
    let id = UUID()
    queue.sync {
      keyCallbacks[id] = callback
    }

    return CallbackHandle { [weak self] in
      self?.queue.sync {
        _ = self?.keyCallbacks.removeValue(forKey: id)
      }
    }
  }

  @discardableResult
  func onDeviceChange(_ callback: @escaping (Event) -> Void) -> CallbackHandle {
    let id = UUID()
    queue.sync {
      deviceCallbacks[id] = callback
    }

    return CallbackHandle { [weak self] in
      self?.queue.sync {
        _ = self?.deviceCallbacks.removeValue(forKey: id)
      }
    }
  }

  // MARK: - Private Methods

  private func handleDeviceMatching(device: IOHIDDevice) {
    let deviceInfo = extractDeviceInfo(device)
    let event = Event(
      kind: .deviceConnected(deviceInfo),
      device: deviceInfo,
      timestamp: Date()
    )

    emitDeviceEvent(event)
  }

  private func handleDeviceRemoval(device: IOHIDDevice) {
    let deviceInfo = extractDeviceInfo(device)

    // Clear state for this device
    queue.sync {
      lastState = lastState.filter { $0.key.deviceLocationID != deviceInfo.locationID }
    }

    let event = Event(
      kind: .deviceDisconnected(deviceInfo),
      device: deviceInfo,
      timestamp: Date()
    )

    emitDeviceEvent(event)
  }

  private func handleInputValue(value: IOHIDValue, device: IOHIDDevice) {
    let element = IOHIDValueGetElement(value)
    let usagePage = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)

    // Only monitor keyboard/keypad usage page (0x07)
    guard usagePage == UInt32(kHIDPage_KeyboardOrKeypad) else { return }

    let integerValue = IOHIDValueGetIntegerValue(value)
    let pressed = integerValue != 0

    let deviceInfo = extractDeviceInfo(device)
    let key = ElementKey(
      deviceLocationID: deviceInfo.locationID,
      usagePage: usagePage,
      usage: usage
    )

    // Dedupe: only emit if state changed
    var shouldEmit = false
    queue.sync {
      let lastPressed = lastState[key]
      if lastPressed != pressed {
        lastState[key] = pressed
        shouldEmit = true
      }
    }

    guard shouldEmit else { return }

    let event = Event(
      kind: .key(usagePage: usagePage, usage: usage, pressed: pressed),
      device: deviceInfo,
      timestamp: Date()
    )

    emitKeyEvent(event)
  }

  private func emitKeyEvent(_ event: Event) {
    queue.async {
      let callbacks = Array(self.keyCallbacks.values)
      DispatchQueue.main.async {
        for callback in callbacks {
          callback(event)
        }
      }
    }
  }

  private func emitDeviceEvent(_ event: Event) {
    queue.async {
      let callbacks = Array(self.deviceCallbacks.values)
      DispatchQueue.main.async {
        for callback in callbacks {
          callback(event)
        }
      }
    }
  }

  private func extractDeviceInfo(_ device: IOHIDDevice) -> DeviceInfo {
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
}
