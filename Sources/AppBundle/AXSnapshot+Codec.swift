import ApplicationServices
import Foundation

// MARK: - AXSnapshotNode Codable

extension AXSnapshotNode {
  enum CodingKeys: String, CodingKey {
    case id, parent, prevSibling, nextSibling, children
    case attributes, parameterizedAttributes, actions
    case position, size, zIndex
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)

    // Encode references as { "id": "..." } objects
    if let parent = parent {
      try container.encode(AXSnapshotReference(id: parent.id), forKey: .parent)
    }

    if let prevSibling = prevSibling {
      try container.encode(AXSnapshotReference(id: prevSibling.id), forKey: .prevSibling)
    }

    if let nextSibling = nextSibling {
      try container.encode(AXSnapshotReference(id: nextSibling.id), forKey: .nextSibling)
    }

    try container.encode(children, forKey: .children)
    try container.encode(attributes, forKey: .attributes)
    try container.encode(parameterizedAttributes, forKey: .parameterizedAttributes)
    try container.encode(actions, forKey: .actions)

    // Encode geometry as nested objects for cleaner JSON
    if let position = position {
      var posDict: [String: Double] = [:]
      posDict["x"] = position.x
      posDict["y"] = position.y
      try container.encode(posDict, forKey: .position)
    }

    if let size = size {
      var sizeDict: [String: Double] = [:]
      sizeDict["width"] = size.width
      sizeDict["height"] = size.height
      try container.encode(sizeDict, forKey: .size)
    }

    try container.encodeIfPresent(zIndex, forKey: .zIndex)
  }

  convenience init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(String.self, forKey: .id)
    let children = try container.decode([AXSnapshotNode].self, forKey: .children)
    let attributes = try container.decode([String: AXSnapshotValue].self, forKey: .attributes)
    let parameterizedAttributes = try container.decode(
      [String].self, forKey: .parameterizedAttributes)
    let actions = try container.decode([AXSnapshotAction].self, forKey: .actions)

    // Decode geometry
    let position: CGPoint?
    if let posDict = try container.decodeIfPresent([String: Double].self, forKey: .position) {
      position = CGPoint(x: posDict["x"] ?? 0, y: posDict["y"] ?? 0)
    } else {
      position = nil
    }

    let size: CGSize?
    if let sizeDict = try container.decodeIfPresent([String: Double].self, forKey: .size) {
      size = CGSize(width: sizeDict["width"] ?? 0, height: sizeDict["height"] ?? 0)
    } else {
      size = nil
    }

    let zIndex = try container.decodeIfPresent(Int.self, forKey: .zIndex)

    self.init(
      id: id,
      parent: nil,  // Will be resolved in post-processing if needed
      prevSibling: nil,
      nextSibling: nil,
      children: children,
      attributes: attributes,
      parameterizedAttributes: parameterizedAttributes,
      actions: actions,
      position: position,
      size: size,
      zIndex: zIndex
    )
  }
}

// MARK: - AXSnapshotValue Codable

extension AXSnapshotValue {
  enum CodingKeys: String, CodingKey {
    case type, value
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
    case .string(let s):
      try container.encode("string", forKey: .type)
      try container.encode(s, forKey: .value)
    case .number(let n):
      try container.encode("number", forKey: .type)
      try container.encode(n, forKey: .value)
    case .bool(let b):
      try container.encode("bool", forKey: .type)
      try container.encode(b, forKey: .value)
    case .null:
      try container.encode("null", forKey: .type)
    case .url(let u):
      try container.encode("url", forKey: .type)
      try container.encode(u, forKey: .value)
    case .date(let d):
      try container.encode("date", forKey: .type)
      try container.encode(d, forKey: .value)
    case .data(let d):
      try container.encode("data", forKey: .type)
      try container.encode(d, forKey: .value)
    case .array(let arr):
      try container.encode("array", forKey: .type)
      try container.encode(arr, forKey: .value)
    case .dictionary(let dict):
      try container.encode("dictionary", forKey: .type)
      try container.encode(dict, forKey: .value)
    case .point(let x, let y):
      try container.encode("point", forKey: .type)
      var pointDict: [String: Double] = [:]
      pointDict["x"] = x
      pointDict["y"] = y
      try container.encode(pointDict, forKey: .value)
    case .size(let width, let height):
      try container.encode("size", forKey: .type)
      var sizeDict: [String: Double] = [:]
      sizeDict["width"] = width
      sizeDict["height"] = height
      try container.encode(sizeDict, forKey: .value)
    case .rect(let x, let y, let width, let height):
      try container.encode("rect", forKey: .type)
      var rectDict: [String: Double] = [:]
      rectDict["x"] = x
      rectDict["y"] = y
      rectDict["width"] = width
      rectDict["height"] = height
      try container.encode(rectDict, forKey: .value)
    case .range(let location, let length):
      try container.encode("range", forKey: .type)
      var rangeDict: [String: Int] = [:]
      rangeDict["location"] = location
      rangeDict["length"] = length
      try container.encode(rangeDict, forKey: .value)
    case .elementReference(let ref):
      try container.encode("elementReference", forKey: .type)
      try container.encode(ref, forKey: .value)
    case .unknown(let desc):
      try container.encode("unknown", forKey: .type)
      try container.encode(desc, forKey: .value)
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)

    switch type {
    case "string":
      self = .string(try container.decode(String.self, forKey: .value))
    case "number":
      self = .number(try container.decode(Double.self, forKey: .value))
    case "bool":
      self = .bool(try container.decode(Bool.self, forKey: .value))
    case "null":
      self = .null
    case "url":
      self = .url(try container.decode(String.self, forKey: .value))
    case "date":
      self = .date(try container.decode(String.self, forKey: .value))
    case "data":
      self = .data(try container.decode(String.self, forKey: .value))
    case "array":
      self = .array(try container.decode([AXSnapshotValue].self, forKey: .value))
    case "dictionary":
      self = .dictionary(try container.decode([String: AXSnapshotValue].self, forKey: .value))
    case "point":
      let dict = try container.decode([String: Double].self, forKey: .value)
      self = .point(x: dict["x"] ?? 0, y: dict["y"] ?? 0)
    case "size":
      let dict = try container.decode([String: Double].self, forKey: .value)
      self = .size(width: dict["width"] ?? 0, height: dict["height"] ?? 0)
    case "rect":
      let dict = try container.decode([String: Double].self, forKey: .value)
      self = .rect(
        x: dict["x"] ?? 0,
        y: dict["y"] ?? 0,
        width: dict["width"] ?? 0,
        height: dict["height"] ?? 0
      )
    case "range":
      let dict = try container.decode([String: Int].self, forKey: .value)
      self = .range(location: dict["location"] ?? 0, length: dict["length"] ?? 0)
    case "elementReference":
      self = .elementReference(try container.decode(String.self, forKey: .value))
    case "unknown":
      self = .unknown(try container.decode(String.self, forKey: .value))
    default:
      self = .unknown("unknown type: \(type)")
    }
  }
}
