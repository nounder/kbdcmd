import Carbon
import Cocoa

extension CGEventFlags {
  public static var maskShiftLeft: CGEventFlags {
    return CGEventFlags(rawValue: 0x0000_0002)
  }

  public static var maskShiftRight: CGEventFlags {
    return CGEventFlags(rawValue: 0x0000_0004)
  }

  public static var maskCmdLeft: CGEventFlags {
    return CGEventFlags(rawValue: 0x0000_0008)
  }

  public static var maskCmdRight: CGEventFlags {
    return CGEventFlags(rawValue: 0x0000_0010)
  }

  public static var maskControlLeft: CGEventFlags {
    return CGEventFlags(rawValue: 0x0000_0001)
  }

  public static var maskControlRight: CGEventFlags {
    return CGEventFlags(rawValue: 0x0000_2000)
  }

  public static var maskOptionLeft: CGEventFlags {
    return CGEventFlags(rawValue: 0x0000_0020)
  }

  public static var maskOptionRight: CGEventFlags {
    return CGEventFlags(rawValue: 0x0000_0040)
  }
}
