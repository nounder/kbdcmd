import AppKit
import ApplicationServices
import ArgumentParser
import Core
import Foundation

struct WindowListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window-list",
        abstract: "List all windows in JSON format"
    )

    @Flag(name: .long, help: "Include minimized windows")
    var includeMinimized: Bool = false

    @Option(name: .shortAndLong, help: "Filter by application name")
    var app: String?

    func run() throws {
        try Permissions.checkAccessibility()

        let windows = getWindows()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let jsonData = try encoder.encode(windows)
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
        }
    }

    private func getWindows() -> [WindowOutput] {
        let runningApps = NSWorkspace.shared.runningApplications
        let zIndexMap = buildZIndexMap()

        var windows: [WindowOutput] = []

        for app in runningApps {
            guard let appName = app.localizedName,
                  app.activationPolicy == .regular
            else {
                continue
            }

            if let filterApp = self.app,
               !appName.localizedCaseInsensitiveContains(filterApp) {
                continue
            }

            let axApp = AXUIElementCreateApplication(app.processIdentifier)

            guard let axWindows = axApp.get(Ax.windowsAttr) else {
                continue
            }

            for axWindow in axWindows {
                guard let windowId = axWindow.containingWindowId() else {
                    continue
                }

                let role = axWindow.get(Ax.roleAttr)
                if let role = role, role != "AXWindow" {
                    continue
                }

                let subrole = axWindow.get(Ax.subroleAttr)
                if let subrole = subrole {
                    let excludedSubroles = ["AXSystemDialog", "AXDialog", "AXUnknown"]
                    if excludedSubroles.contains(subrole) {
                        continue
                    }
                }

                let position = axWindow.get(Ax.topLeftCornerAttr)
                let size = axWindow.get(Ax.sizeAttr)

                guard let size = size else {
                    continue
                }

                if size.width < 100 || size.height < 100 {
                    continue
                }

                let windowTitle = axWindow.get(Ax.titleAttr) ?? ""
                let isMinimized = axWindow.get(Ax.minimizedAttr) ?? false

                if isMinimized && !includeMinimized {
                    continue
                }

                if windowTitle.isEmpty && !isMinimized {
                    continue
                }

                let output = WindowOutput(
                    cgid: Int(windowId),
                    title: windowTitle.isEmpty ? "Untitled" : windowTitle,
                    appName: appName,
                    bundleId: app.bundleIdentifier,
                    pid: Int(app.processIdentifier),
                    position: position.map { PointOutput(x: $0.x, y: $0.y) },
                    size: SizeOutput(width: size.width, height: size.height),
                    isMinimized: isMinimized,
                    zIndex: zIndexMap[windowId]
                )

                windows.append(output)
            }
        }

        return windows.sorted {
            if let z0 = $0.zIndex, let z1 = $1.zIndex {
                return z0 < z1
            }
            return $0.appName < $1.appName
        }
    }

    private func buildZIndexMap() -> [CGWindowID: Int] {
        var zIndexMap: [CGWindowID: Int] = [:]

        let windowsInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)

        guard let windowList = windowsInfo as? [[String: Any]] else {
            return zIndexMap
        }

        for (index, windowDict) in windowList.enumerated() {
            if let windowId = windowDict[kCGWindowNumber as String] as? CGWindowID {
                zIndexMap[windowId] = index
            }
        }

        return zIndexMap
    }
}

struct WindowOutput: Codable {
    let cgid: Int
    let title: String
    let appName: String
    let bundleId: String?
    let pid: Int
    let position: PointOutput?
    let size: SizeOutput
    let isMinimized: Bool
    let zIndex: Int?
}

struct PointOutput: Codable {
    let x: Double
    let y: Double
}

struct SizeOutput: Codable {
    let width: Double
    let height: Double
}
