import Foundation

public func sleepSeconds(_ seconds: Double) {
  guard seconds > 0 else { return }
  usleep(UInt32(min(seconds * 1_000_000, Double(UInt32.max))))
}
