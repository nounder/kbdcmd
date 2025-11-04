import CoreGraphics

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
