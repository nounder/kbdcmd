import Foundation
import ApplicationServices
import Cocoa

/// Async wrappers for blocking window and accessibility APIs
@available(macOS 15.0, *)
enum AsyncWindowAPI {

    // MARK: - Window List Queries

    /// Asynchronously fetches window list information
    /// - Parameters:
    ///   - options: Window list options
    ///   - relativeToWindow: Window ID to get windows relative to
    /// - Returns: Array of window dictionaries
    static func windowListCopyWindowInfo(
        _ options: CGWindowListOption,
        _ relativeToWindow: CGWindowID = kCGNullWindowID
    ) async -> [[String: Any]] {
        await Task.detached(priority: .userInitiated) {
            guard let windowsInfo = CGWindowListCopyWindowInfo(options, relativeToWindow) as? [[String: Any]] else {
                return []
            }
            return windowsInfo
        }.value
    }

    /// Asynchronously fetches windows for a specific application
    /// - Parameter app: The running application
    /// - Returns: Array of window dictionaries
    static func windowsForApplication(_ app: NSRunningApplication) async -> [[String: Any]] {
        let pid = app.processIdentifier
        let allWindows = await windowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])
        return allWindows.filter { window in
            guard let windowPid = window[kCGWindowOwnerPID as String] as? Int32 else { return false }
            return windowPid == pid
        }
    }

    /// Asynchronously fetches all visible windows grouped by application
    /// - Returns: Dictionary mapping PID to window arrays
    static func windowsGroupedByApplication() async -> [Int32: [[String: Any]]] {
        let allWindows = await windowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])
        var grouped: [Int32: [[String: Any]]] = [:]

        for window in allWindows {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32 else { continue }
            grouped[pid, default: []].append(window)
        }

        return grouped
    }

    // MARK: - Accessibility Queries

    /// Asynchronously fetches an accessibility attribute value
    /// - Parameters:
    ///   - element: The AXUIElement to query
    ///   - attribute: The attribute name
    /// - Returns: Optional CFTypeRef value
    static func axAttributeValue(
        _ element: AXUIElement,
        _ attribute: String
    ) async -> CFTypeRef? {
        await Task.detached(priority: .userInitiated) {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            return result == .success ? value : nil
        }.value
    }

    /// Asynchronously fetches multiple accessibility attributes
    /// - Parameters:
    ///   - element: The AXUIElement to query
    ///   - attributes: Array of attribute names
    /// - Returns: Dictionary of attribute values
    static func axMultipleAttributeValues(
        _ element: AXUIElement,
        _ attributes: [String]
    ) async -> [String: CFTypeRef] {
        await Task.detached(priority: .userInitiated) {
            var result: [String: CFTypeRef] = [:]

            for attribute in attributes {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                   let value = value {
                    result[attribute] = value
                }
            }

            return result
        }.value
    }

    /// Asynchronously fetches window title from AXUIElement
    /// - Parameter element: The window AXUIElement
    /// - Returns: Optional window title
    static func axWindowTitle(_ element: AXUIElement) async -> String? {
        guard let value = await axAttributeValue(element, kAXTitleAttribute as String) else {
            return nil
        }
        return value as? String
    }

    /// Asynchronously fetches all windows for an application element
    /// - Parameter appElement: The application AXUIElement
    /// - Returns: Array of window AXUIElements
    static func axWindowList(_ appElement: AXUIElement) async -> [AXUIElement] {
        guard let value = await axAttributeValue(appElement, kAXWindowsAttribute as String) else {
            return []
        }

        guard let windows = value as? [AXUIElement] else {
            return []
        }

        return windows
    }

    /// Asynchronously fetches the focused window for an application
    /// - Parameter appElement: The application AXUIElement
    /// - Returns: Optional focused window AXUIElement
    static func axFocusedWindow(_ appElement: AXUIElement) async -> AXUIElement? {
        guard let value = await axAttributeValue(appElement, kAXFocusedWindowAttribute as String) else {
            return nil
        }
        return (value as! AXUIElement)
    }

    /// Asynchronously sets an accessibility attribute value
    /// - Parameters:
    ///   - element: The AXUIElement to modify
    ///   - attribute: The attribute name
    ///   - value: The value to set
    /// - Returns: Success boolean
    @discardableResult
    static func axSetAttributeValue(
        _ element: AXUIElement,
        _ attribute: String,
        _ value: CFTypeRef
    ) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
        }.value
    }

    /// Asynchronously performs an accessibility action
    /// - Parameters:
    ///   - element: The AXUIElement to act on
    ///   - action: The action name
    /// - Returns: Success boolean
    @discardableResult
    static func axPerformAction(
        _ element: AXUIElement,
        _ action: String
    ) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            AXUIElementPerformAction(element, action as CFString) == .success
        }.value
    }

    // MARK: - Window Operations

    /// Asynchronously activates a window by bringing it to front
    /// - Parameter element: The window AXUIElement
    /// - Returns: Success boolean
    @discardableResult
    static func activateWindow(_ element: AXUIElement) async -> Bool {
        await axPerformAction(element, kAXRaiseAction as String)
    }

    /// Asynchronously focuses a window
    /// - Parameter element: The window AXUIElement
    /// - Returns: Success boolean
    @discardableResult
    static func focusWindow(_ element: AXUIElement) async -> Bool {
        // Get the application from the window
        guard let app = await axAttributeValue(element, kAXParentAttribute as String) as? AXUIElement else {
            return false
        }

        // Set the focused window attribute
        return await axSetAttributeValue(app, kAXFocusedWindowAttribute as String, element)
    }

    // MARK: - Application Queries

    /// Asynchronously fetches the frontmost application
    /// - Returns: Optional running application
    static func frontmostApplication() async -> NSRunningApplication? {
        await Task.detached(priority: .userInitiated) {
            NSWorkspace.shared.frontmostApplication
        }.value
    }

    /// Asynchronously activates an application
    /// - Parameter app: The application to activate
    /// - Returns: Success boolean
    @discardableResult
    static func activateApplication(_ app: NSRunningApplication) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }.value
    }

    // MARK: - Screen Queries

    /// Asynchronously fetches all screens
    /// - Returns: Array of NSScreen
    static func screens() async -> [NSScreen] {
        await MainActor.run {
            NSScreen.screens
        }
    }

    /// Asynchronously fetches the main screen
    /// - Returns: Optional main screen
    static func mainScreen() async -> NSScreen? {
        await MainActor.run {
            NSScreen.main
        }
    }

    /// Asynchronously finds the screen containing a point
    /// - Parameter point: The point to check
    /// - Returns: Optional screen
    static func screen(containing point: CGPoint) async -> NSScreen? {
        let screens = await screens()
        return screens.first { NSPointInRect(point, $0.frame) }
    }
}

// MARK: - AXUIElement Extension for Async

@available(macOS 15.0, *)
extension AXUIElement {

    /// Asynchronously fetches an attribute value
    /// - Parameter attribute: The attribute name
    /// - Returns: Optional value
    func asyncAttributeValue(_ attribute: String) async -> CFTypeRef? {
        await AsyncWindowAPI.axAttributeValue(self, attribute)
    }

    /// Asynchronously fetches multiple attribute values
    /// - Parameter attributes: Array of attribute names
    /// - Returns: Dictionary of values
    func asyncAttributeValues(_ attributes: [String]) async -> [String: CFTypeRef] {
        await AsyncWindowAPI.axMultipleAttributeValues(self, attributes)
    }

    /// Asynchronously sets an attribute value
    /// - Parameters:
    ///   - attribute: The attribute name
    ///   - value: The value to set
    /// - Returns: Success boolean
    @discardableResult
    func asyncSetAttributeValue(_ attribute: String, _ value: CFTypeRef) async -> Bool {
        await AsyncWindowAPI.axSetAttributeValue(self, attribute, value)
    }

    /// Asynchronously performs an action
    /// - Parameter action: The action name
    /// - Returns: Success boolean
    @discardableResult
    func asyncPerformAction(_ action: String) async -> Bool {
        await AsyncWindowAPI.axPerformAction(self, action)
    }
}
