import Carbon
import Cocoa

extension CGEventFlags {
    static var maskShiftLeft: CGEventFlags {
        return CGEventFlags(rawValue: 0x0000_0002)
    }

    static var maskShiftRight: CGEventFlags {
        return CGEventFlags(rawValue: 0x0000_0004)
    }

    static var maskCmdLeft: CGEventFlags {
        return CGEventFlags(rawValue: 0x0000_0008)
    }

    static var maskCmdRight: CGEventFlags {
        return CGEventFlags(rawValue: 0x0000_0010)
    }

    static var maskControlLeft: CGEventFlags {
        return CGEventFlags(rawValue: 0x0000_0001)
    }

    static var maskControlRight: CGEventFlags {
        return CGEventFlags(rawValue: 0x0000_2000)
    }
}
