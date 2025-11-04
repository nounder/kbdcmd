import ApplicationServices

extension AXUIElement {
  /// Batch fetch multiple attributes in one IPC call
  /// Returns array of optional values corresponding to the requested keys
  func getAttributes(_ keys: String...) -> [AnyObject?] {
    guard !keys.isEmpty else { return [] }

    let cfKeys = keys.map { $0 as CFString }
    var valuesArray: CFArray?
    let result = AXUIElementCopyMultipleAttributeValues(
      self,
      cfKeys as CFArray,
      [],
      &valuesArray
    )

    guard result == .success, let values = valuesArray as? [AnyObject] else {
      return Array(repeating: nil, count: keys.count)
    }

    return (0..<keys.count).map { index in
      index < values.count ? values[index] : nil
    }
  }
}
