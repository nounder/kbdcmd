import Cocoa
import CoreGraphics

func altGetWindows() {

    let options = CGWindowListOption(
        arrayLiteral: CGWindowListOption.excludeDesktopElements,
        CGWindowListOption.optionOnScreenOnly)
    let windowListInfo = CGWindowListCopyWindowInfo(options, CGWindowID(0))
    let infoList = windowListInfo as NSArray? as? [[String: AnyObject]]

    print(infoList)
}

func getWindows() {
    let windowsInfo = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    let maxDisplays: UInt32 = 10
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
    var displayCount: UInt32 = 0
    let error = CGGetOnlineDisplayList(maxDisplays, &displays, &displayCount)

    for window in Array<NSDictionary>.fromCFArray(records: windowsInfo) ?? [] {
        // for (key, value) in windowInfo {
        //     print("\(key): \(value ?? "<null>")")
        // }

        guard let id = window[kCGWindowNumber as String] as? CGWindowID,
            let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
            let app = NSRunningApplication(processIdentifier: ownerPID)
        else {
            continue
        }

        app.activate(options: .activateIgnoringOtherApps)

        print(app)

        if let bounds = window["kCGWindowBounds"] as? NSDictionary {
            if let x = bounds["X"] as? Double,
                let y = bounds["Y"] as? Double,
                let width = bounds["Width"] as? Double,
                let height = bounds["Height"] as? Double
            {
                if width < 50 {
                    continue
                }

                if let appName = window["kCGWindowOwnerName"] as? String {
                    print("appName: \(appName)")
                }

                print("X: \(bounds["X"] ?? "<unknown>")")
                print("Y: \(bounds["Y"] ?? "<unknown>")")
                print("Width: \(bounds["Width"] ?? "<unknown>")")
                print("Height: \(bounds["Height"] ?? "<unknown>")")

                for index in 0..<Int(maxDisplays) {
                    let display = displays[index]
                    let displayRect = CGDisplayBounds(display)
                    if displayRect.contains(CGRect(x: x, y: y, width: width, height: height)) {
                        print("Display: \(index)")
                        break
                    }
                }
            }

            print("---")
        }
    }
}

extension Array {
    static func fromCFArray(records: CFArray?) -> [Element]? {
        var result: [Element]?
        if let records = records {
            for i in 0..<CFArrayGetCount(records) {
                let unmanagedObject: UnsafeRawPointer = CFArrayGetValueAtIndex(records, i)
                let rec: Element = unsafeBitCast(unmanagedObject, to: Element.self)
                if result == nil {
                    result = [Element]()
                }
                result!.append(rec)
            }
        }
        return result
    }
}
