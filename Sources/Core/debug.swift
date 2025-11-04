import Foundation

/// Debug logging function that only prints in DEBUG builds
/// - Parameter message: The message to log (autoclosure for lazy evaluation)
func debugLog(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
  #if DEBUG
    let fileName = (file as NSString).lastPathComponent
    print("[\(fileName):\(line)] \(message())")
  #endif
}
