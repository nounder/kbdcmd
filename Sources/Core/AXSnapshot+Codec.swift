import ApplicationServices
import Foundation

// MARK: - AXSnapshotNode Codable

extension AXSnapshotNode {
  enum CodingKeys: String, CodingKey {
    case id = "@id"
    case parent, prevSibling, nextSibling, children
    case attributes, parameterizedAttributes, actions
    case bounds, zIndex
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)

    // Encode references as { "@id": "..." } objects
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

    // Encode bounds as nested object
    if let bounds = bounds {
      var boundsDict: [String: Double] = [:]
      boundsDict["x"] = bounds.origin.x
      boundsDict["y"] = bounds.origin.y
      boundsDict["width"] = bounds.width
      boundsDict["height"] = bounds.height
      try container.encode(boundsDict, forKey: .bounds)
    }

    try container.encodeIfPresent(zIndex, forKey: .zIndex)
  }

  public convenience init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(String.self, forKey: .id)
    let children = try container.decode([AXSnapshotNode].self, forKey: .children)
    let attributes = try container.decode([String: AXSnapshotValue].self, forKey: .attributes)
    let parameterizedAttributes = try container.decode(
      [String].self, forKey: .parameterizedAttributes)
    let actions = try container.decode([AXSnapshotAction].self, forKey: .actions)

    // Decode bounds
    let bounds: CGRect?
    if let boundsDict = try container.decodeIfPresent([String: Double].self, forKey: .bounds) {
      bounds = CGRect(
        x: boundsDict["x"] ?? 0,
        y: boundsDict["y"] ?? 0,
        width: boundsDict["width"] ?? 0,
        height: boundsDict["height"] ?? 0
      )
    } else {
      bounds = nil
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
      bounds: bounds,
      zIndex: zIndex
    )
  }
}

// MARK: - AXSnapshotValue Codable

// Helper wrappers for encoding flat specialized types
private struct TypedValue: Encodable {
  let type: String
  let value: String

  enum CodingKeys: String, CodingKey {
    case type = "@type"
    case value
  }
}

private struct CGPointValue: Encodable {
  let type: String
  let x: Double
  let y: Double

  enum CodingKeys: String, CodingKey {
    case type = "@type"
    case x, y
  }
}

private struct CGSizeValue: Encodable {
  let type: String
  let width: Double
  let height: Double

  enum CodingKeys: String, CodingKey {
    case type = "@type"
    case width, height
  }
}

private struct CGRectValue: Encodable {
  let type: String
  let x: Double
  let y: Double
  let width: Double
  let height: Double

  enum CodingKeys: String, CodingKey {
    case type = "@type"
    case x, y, width, height
  }
}

private struct CFRangeValue: Encodable {
  let type: String
  let location: Int
  let length: Int

  enum CodingKeys: String, CodingKey {
    case type = "@type"
    case location, length
  }
}

extension AXSnapshotValue {
  public func encode(to encoder: Encoder) throws {
    switch self {
    case .string(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .number(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .bool(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .null:
      var container = encoder.singleValueContainer()
      try container.encodeNil()
    case .array(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .dictionary(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .elementReference(let ref):
      var container = encoder.singleValueContainer()
      try container.encode(["@id": ref])
    case .url(let string):
      var container = encoder.singleValueContainer()
      try container.encode(TypedValue(type: "url", value: string))
    case .date(let string):
      var container = encoder.singleValueContainer()
      try container.encode(TypedValue(type: "date", value: string))
    case .data(let base64):
      var container = encoder.singleValueContainer()
      try container.encode(TypedValue(type: "data", value: base64))
    case .cgPoint(let x, let y):
      var container = encoder.singleValueContainer()
      try container.encode(CGPointValue(type: "CGPoint", x: x, y: y))
    case .cgSize(let width, let height):
      var container = encoder.singleValueContainer()
      try container.encode(CGSizeValue(type: "CGSize", width: width, height: height))
    case .cgRect(let x, let y, let width, let height):
      var container = encoder.singleValueContainer()
      try container.encode(CGRectValue(type: "CGRect", x: x, y: y, width: width, height: height))
    case .cfRange(let location, let length):
      var container = encoder.singleValueContainer()
      try container.encode(CFRangeValue(type: "CFRange", location: location, length: length))
    case .attributedString(let description):
      var container = encoder.singleValueContainer()
      try container.encode(TypedValue(type: "NSAttributedString", value: description))
    case .cgPath(let description):
      var container = encoder.singleValueContainer()
      try container.encode(TypedValue(type: "CGPath", value: description))
    case .unknown(let description):
      var container = encoder.singleValueContainer()
      try container.encode(TypedValue(type: "unknown", value: description))
    }
  }

  public init(from decoder: Decoder) throws {
    let singleValueContainer = try decoder.singleValueContainer()

    if singleValueContainer.decodeNil() {
      self = .null
      return
    }

    if let bool = try? singleValueContainer.decode(Bool.self) {
      self = .bool(bool)
      return
    }

    if let number = try? singleValueContainer.decode(Double.self) {
      self = .number(number)
      return
    }

    if let string = try? singleValueContainer.decode(String.self) {
      self = .string(string)
      return
    }

    if let array = try? singleValueContainer.decode([AXSnapshotValue].self) {
      self = .array(array)
      return
    }

    if let dictionary = try? singleValueContainer.decode([String: AXSnapshotValue].self) {
      if let decoded = AXSnapshotValue.decodeSpecialDictionary(dictionary) {
        self = decoded
        return
      }

      self = .dictionary(dictionary)
      return
    }

    throw DecodingError.dataCorruptedError(
      in: singleValueContainer,
      debugDescription: "Unsupported AXSnapshotValue representation"
    )
  }

  private static func decodeSpecialDictionary(_ dictionary: [String: AXSnapshotValue])
    -> AXSnapshotValue?
  {
    // Handle @id format for element references
    if dictionary.count == 1,
      let refValue = dictionary["@id"],
      case .string(let ref) = refValue
    {
      return .elementReference(ref)
    }

    // Handle @type format for specialized values
    guard let typeValue = dictionary["@type"],
      case .string(let typeString) = typeValue
    else {
      return nil
    }

    switch typeString {
    case "url":
      guard let value = dictionary["value"],
        case .string(let string) = value
      else { return nil }
      return .url(string)
    case "date":
      guard let value = dictionary["value"],
        case .string(let string) = value
      else { return nil }
      return .date(string)
    case "data":
      guard let value = dictionary["value"],
        case .string(let base64) = value
      else { return nil }
      return .data(base64)
    case "CGPoint":
      guard case .number(let x) = dictionary["x"],
        case .number(let y) = dictionary["y"]
      else { return nil }
      return .cgPoint(x: x, y: y)
    case "CGSize":
      guard case .number(let width) = dictionary["width"],
        case .number(let height) = dictionary["height"]
      else { return nil }
      return .cgSize(width: width, height: height)
    case "CGRect":
      guard case .number(let x) = dictionary["x"],
        case .number(let y) = dictionary["y"],
        case .number(let width) = dictionary["width"],
        case .number(let height) = dictionary["height"]
      else { return nil }
      return .cgRect(x: x, y: y, width: width, height: height)
    case "CFRange":
      guard case .number(let location) = dictionary["location"],
        case .number(let length) = dictionary["length"]
      else { return nil }
      return .cfRange(location: Int(location), length: Int(length))
    case "NSAttributedString":
      guard let value = dictionary["value"],
        case .string(let description) = value
      else { return nil }
      return .attributedString(description)
    case "CGPath":
      guard let value = dictionary["value"],
        case .string(let description) = value
      else { return nil }
      return .cgPath(description)
    case "unknown":
      guard let value = dictionary["value"],
        case .string(let description) = value
      else { return nil }
      return .unknown(description)
    default:
      return nil
    }
  }
}
