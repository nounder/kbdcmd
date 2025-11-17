import Foundation
import CoreGraphics

/// Async wrapper for CGWindow operations to avoid blocking the main thread
public actor AsyncCGWindowManager {
    /// Quality of service for window operations
    private let qos: DispatchQoS.QoSClass

    /// Dedicated queue for window operations
    private let windowQueue: DispatchQueue

    public init(qos: DispatchQoS.QoSClass = .userInitiated) {
        self.qos = qos
        self.windowQueue = DispatchQueue(
            label: "com.kbdcmd.async-window-manager",
            qos: qos
        )
    }

    /// Asynchronously retrieves the window list
    /// - Parameters:
    ///   - option: Window list option
    ///   - relativeToWindow: Window to get list relative to
    /// - Returns: Array of window dictionaries
    public func getWindowList(
        option: CGWindowListOption = .optionOnScreenOnly,
        relativeToWindow: CGWindowID = kCGNullWindowID
    ) async -> [[String: Any]] {
        await withCheckedContinuation { continuation in
            windowQueue.async {
                guard let windowList = CGWindowListCopyWindowInfo(option, relativeToWindow) as? [[String: Any]] else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: windowList)
            }
        }
    }

    /// Asynchronously checks if a window exists
    /// - Parameter windowId: The window ID to check
    /// - Returns: True if the window exists
    public func windowExists(_ windowId: CGWindowID) async -> Bool {
        await withCheckedContinuation { continuation in
            windowQueue.async {
                let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
                let exists = windowList.contains { dict in
                    (dict[kCGWindowNumber as String] as? CGWindowID) == windowId
                }
                continuation.resume(returning: exists)
            }
        }
    }

    /// Asynchronously retrieves window information for a specific window
    /// - Parameter windowId: The window ID
    /// - Returns: Window dictionary if found
    public func getWindowInfo(_ windowId: CGWindowID) async -> [String: Any]? {
        await withCheckedContinuation { continuation in
            windowQueue.async {
                let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
                let windowInfo = windowList.first { dict in
                    (dict[kCGWindowNumber as String] as? CGWindowID) == windowId
                }
                continuation.resume(returning: windowInfo)
            }
        }
    }

    /// Asynchronously retrieves all windows for a specific process
    /// - Parameter pid: Process ID
    /// - Returns: Array of window dictionaries
    public func getWindowsForProcess(_ pid: pid_t) async -> [[String: Any]] {
        await withCheckedContinuation { continuation in
            windowQueue.async {
                let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
                let filtered = windowList.filter { dict in
                    (dict[kCGWindowOwnerPID as String] as? pid_t) == pid
                }
                continuation.resume(returning: filtered)
            }
        }
    }

    /// Asynchronously retrieves visible windows only
    /// - Returns: Array of window dictionaries for on-screen windows
    public func getVisibleWindows() async -> [[String: Any]] {
        await getWindowList(option: .optionOnScreenOnly)
    }

    /// Asynchronously retrieves all windows (including off-screen)
    /// - Returns: Array of all window dictionaries
    public func getAllWindows() async -> [[String: Any]] {
        await getWindowList(option: .optionAll)
    }

    /// Asynchronously builds a Z-index mapping of windows
    /// - Returns: Dictionary mapping window ID to Z-index
    public func getZIndexMapping() async -> [CGWindowID: Int] {
        await withCheckedContinuation { continuation in
            windowQueue.async {
                let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []

                var zIndexMap: [CGWindowID: Int] = [:]

                for (index, dict) in windowList.enumerated() {
                    if let windowId = dict[kCGWindowNumber as String] as? CGWindowID {
                        zIndexMap[windowId] = index
                    }
                }

                continuation.resume(returning: zIndexMap)
            }
        }
    }
}

// MARK: - Global Async Window Manager Instance

/// Shared async window manager instance
public let asyncWindowManager = AsyncCGWindowManager()

// MARK: - Convenience Functions

/// Asynchronously retrieves the window list
public func getWindowListAsync(
    option: CGWindowListOption = .optionOnScreenOnly,
    relativeToWindow: CGWindowID = kCGNullWindowID
) async -> [[String: Any]] {
    await asyncWindowManager.getWindowList(option: option, relativeToWindow: relativeToWindow)
}

/// Asynchronously checks if a window exists
public func windowExistsAsync(_ windowId: CGWindowID) async -> Bool {
    await asyncWindowManager.windowExists(windowId)
}

/// Asynchronously retrieves window information
public func getWindowInfoAsync(_ windowId: CGWindowID) async -> [String: Any]? {
    await asyncWindowManager.getWindowInfo(windowId)
}

/// Asynchronously retrieves windows for a process
public func getWindowsForProcessAsync(_ pid: pid_t) async -> [[String: Any]] {
    await asyncWindowManager.getWindowsForProcess(pid)
}
