import ApplicationServices
import Foundation

// MARK: - Configuration

/// Number of concurrent threads for parallel AX attribute fetching.
/// AX calls are blocking IPC, so parallelization can significantly reduce latency.
/// Start with 2 threads; tune based on profiling results.
public let kAXSnapshotWorkerCount = 2

// MARK: - AXSnapshot

/// A complete snapshot of an accessibility tree with timing information
public struct AXSnapshot: Codable {
  public let root: AXSnapshotNode
  public let timings: [TimingEntry]
  public let metadata: SnapshotMetadata

  public init(root: AXSnapshotNode, timings: [TimingEntry], metadata: SnapshotMetadata) {
    self.root = root
    self.timings = timings
    self.metadata = metadata
  }

  public struct SnapshotMetadata: Codable {
    public let timestamp: Date
    public let totalDuration: TimeInterval
    public let nodeCount: Int

    public init(timestamp: Date, totalDuration: TimeInterval, nodeCount: Int) {
      self.timestamp = timestamp
      self.totalDuration = totalDuration
      self.nodeCount = nodeCount
    }
  }
}

// MARK: - AXSnapshotNode

/// Represents a single node in the accessibility tree snapshot
public final class AXSnapshotNode: Codable {
  public let id: String
  public weak var parent: AXSnapshotNode?
  public weak var prevSibling: AXSnapshotNode?
  public weak var nextSibling: AXSnapshotNode?
  public var children: [AXSnapshotNode]

  public let attributes: [String: AXSnapshotValue]
  public let parameterizedAttributes: [String]
  public let actions: [AXSnapshotAction]

  // Extracted geometry info
  public let bounds: CGRect?
  public let zIndex: Int?

  public init(
    id: String,
    parent: AXSnapshotNode?,
    prevSibling: AXSnapshotNode?,
    nextSibling: AXSnapshotNode?,
    children: [AXSnapshotNode],
    attributes: [String: AXSnapshotValue],
    parameterizedAttributes: [String],
    actions: [AXSnapshotAction],
    bounds: CGRect?,
    zIndex: Int?
  ) {
    self.id = id
    self.parent = parent
    self.prevSibling = prevSibling
    self.nextSibling = nextSibling
    self.children = children
    self.attributes = attributes
    self.parameterizedAttributes = parameterizedAttributes
    self.actions = actions
    self.bounds = bounds
    self.zIndex = zIndex
  }
}

// MARK: - AXSnapshotReference

/// A reference to another node in the tree (for parent/sibling relationships)
public struct AXSnapshotReference: Codable {
  public let id: String

  public init(id: String) {
    self.id = id
  }

  enum CodingKeys: String, CodingKey {
    case id = "@id"
  }
}

// MARK: - AXSnapshotAction

/// Represents an accessibility action that can be performed on an element
public struct AXSnapshotAction: Codable {
  public let name: String
  public let description: String?

  public init(name: String, description: String?) {
    self.name = name
    self.description = description
  }
}

// MARK: - AXSnapshotValue

/// Represents any value type that can appear in accessibility attributes
public enum AXSnapshotValue: Codable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case null
  case url(String)
  case date(String)
  case data(String)  // base64 encoded
  case array([AXSnapshotValue])
  case dictionary([String: AXSnapshotValue])
  case cgPoint(x: Double, y: Double)
  case cgSize(width: Double, height: Double)
  case cgRect(x: Double, y: Double, width: Double, height: Double)
  case cfRange(location: Int, length: Int)
  case elementReference(String)  // reference to another element by id
  case attributedString(String)  // NSAttributedString description
  case cgPath(String)  // CGPath description
  case unknown(String)  // fallback description
}

// MARK: - TimingEntry

/// Records timing information for each operation during snapshot
public struct TimingEntry: Codable {
  public let operation: String
  public let nodeId: String
  public let duration: TimeInterval
  public let timestamp: Date

  public init(operation: String, nodeId: String, duration: TimeInterval, timestamp: Date) {
    self.operation = operation
    self.nodeId = nodeId
    self.duration = duration
    self.timestamp = timestamp
  }
}

// MARK: - TimingRecorder

/// Helper class to record timing information during snapshot generation
class TimingRecorder {
  private var entries: [TimingEntry] = []
  private let startTime: Date

  init() {
    self.startTime = Date()
  }

  func measure<T>(_ operation: String, _ nodeId: String, _ block: () -> T) -> T {
    let start = Date()
    let result = block()
    let duration = Date().timeIntervalSince(start)

    entries.append(
      TimingEntry(
        operation: operation,
        nodeId: nodeId,
        duration: duration,
        timestamp: start
      )
    )

    return result
  }

  func finalize() -> [TimingEntry] {
    return entries
  }

  var totalDuration: TimeInterval {
    return Date().timeIntervalSince(startTime)
  }
}

// MARK: - Geometry Info

struct GeometryInfo {
  let bounds: CGRect?
  let zIndex: Int?
}

// MARK: - AXElementIdRegistry

/// Maintains stable IDs for AXUIElements encountered during snapshot collection
final class AXElementIdRegistry {
  private var entries: [(element: AXUIElement, id: String)] = []

  func register(_ element: AXUIElement, id: String) {
    // Avoid duplicate registrations when the element is already present
    if lookup(element) != nil {
      return
    }
    entries.append((element: element, id: id))
  }

  func registerAlias(_ element: AXUIElement, id: String) {
    entries.append((element: element, id: id))
  }

  func lookup(_ element: AXUIElement) -> String? {
    for entry in entries {
      if CFEqual(entry.element, element) {
        return entry.id
      }
    }
    return nil
  }
}

// MARK: - Snapshot Generation

extension AXSnapshot {
  /// Creates a complete snapshot of the accessibility tree starting from the given root element
  /// - Parameters:
  ///   - root: The root AXUIElement to start traversal from
  ///   - progressCallback: Optional callback called for each node processed (nodeId, nodeCount, node)
  public static func snapshot(
    root: AXUIElement,
    progressCallback: ((String, Int, MutableNode) -> Void)? = nil
  ) -> AXSnapshot {
    let tree = AXTree(root: root)
    let timings = TimingRecorder()
    let elementIdRegistry = AXElementIdRegistry()

    // PASS 1: Build complete element-to-ID map
    var idStack: [String] = []
    var siblingCountStack: [Int] = [0]

    tree.traverse { element, depth in
      // Adjust ID stack to match current depth (path to current node)
      while idStack.count > depth {
        idStack.removeLast()
      }

      // Adjust sibling count stack - keep counts for all depths we've seen
      // But reset counts for depths deeper than current + 1
      while siblingCountStack.count > depth + 1 {
        siblingCountStack.removeLast()
      }

      // Ensure sibling count stack has an entry for this depth
      while siblingCountStack.count <= depth {
        siblingCountStack.append(0)
      }

      let siblingIndex = siblingCountStack[depth]
      let parentId = idStack.last
      let nodeId = composeId(parentId: parentId, index: siblingIndex)

      // Register this element's ID in the map
      elementIdRegistry.register(element, id: nodeId)

      // Update stacks
      idStack.append(nodeId)
      siblingCountStack[depth] += 1

      return .continue
    }

    // PASS 2: Collect attributes and build tree structure
    var nodeStack: [MutableNode] = []
    var siblingStack: [[MutableNode]] = [[]]
    var rootNode: MutableNode?
    var nodeCount = 0

    tree.traverse { element, depth in
      // Adjust stacks to match current depth
      while nodeStack.count > depth {
        nodeStack.removeLast()
        siblingStack.removeLast()
      }

      // Ensure sibling stack has an entry for this depth
      if siblingStack.count <= depth {
        siblingStack.append([])
      }

      let siblingIndex = siblingStack[depth].count
      let parentId = nodeStack.last?.id
      let nodeId = composeId(parentId: parentId, index: siblingIndex)

      // Collect data with timing
      let attributes = timings.measure("attributes", nodeId) {
        collectAttributes(element: element, elementIdRegistry: elementIdRegistry)
      }

      let parameterized = timings.measure("parameterized", nodeId) {
        collectParameterizedAttributes(element: element)
      }

      let actions = timings.measure("actions", nodeId) {
        collectActions(element: element)
      }

      let geometry = timings.measure("geometry", nodeId) {
        collectGeometry(attributes: attributes, element: element)
      }

      // Create mutable node
      let prevSibling = siblingStack[depth].last
      let node = MutableNode(
        id: nodeId,
        parent: nodeStack.last,
        prevSibling: prevSibling,
        attributes: attributes,
        parameterizedAttributes: parameterized,
        actions: actions,
        bounds: geometry.bounds,
        zIndex: geometry.zIndex
      )

      // Wire up next sibling reference
      if let prev = prevSibling {
        prev.nextSibling = node
      }

      // Add to parent's children or set as root
      if let parent = nodeStack.last {
        parent.children.append(node)
      } else {
        rootNode = node
      }

      // Update stacks
      siblingStack[depth].append(node)
      nodeStack.append(node)
      nodeCount += 1

      // Call progress callback if provided with node data
      progressCallback?(nodeId, nodeCount, node)

      return .continue
    }

    guard let root = rootNode else {
      fatalError("No root node created during traversal")
    }

    let metadata = AXSnapshot.SnapshotMetadata(
      timestamp: Date(),
      totalDuration: timings.totalDuration,
      nodeCount: nodeCount
    )

    // Finalize the tree with a cache to avoid duplicates
    var cache: [String: AXSnapshotNode] = [:]
    let finalizedRoot = root.finalize(cache: &cache)

    return AXSnapshot(
      root: finalizedRoot,
      timings: timings.finalize(),
      metadata: metadata
    )
  }
}

// MARK: - MutableNode

/// Internal mutable node used during tree construction
public class MutableNode {
  public let id: String
  public weak var parent: MutableNode?
  public weak var prevSibling: MutableNode?
  public var nextSibling: MutableNode?
  public var children: [MutableNode] = []

  public let attributes: [String: AXSnapshotValue]
  public let parameterizedAttributes: [String]
  public let actions: [AXSnapshotAction]
  public let bounds: CGRect?
  public let zIndex: Int?

  public init(
    id: String,
    parent: MutableNode?,
    prevSibling: MutableNode?,
    attributes: [String: AXSnapshotValue],
    parameterizedAttributes: [String],
    actions: [AXSnapshotAction],
    bounds: CGRect?,
    zIndex: Int?
  ) {
    self.id = id
    self.parent = parent
    self.prevSibling = prevSibling
    self.attributes = attributes
    self.parameterizedAttributes = parameterizedAttributes
    self.actions = actions
    self.bounds = bounds
    self.zIndex = zIndex
  }

  func finalize(cache: inout [String: AXSnapshotNode]) -> AXSnapshotNode {
    // Check cache first to avoid duplicates
    if let cached = cache[id] {
      return cached
    }

    // Create node without relationships first
    let node = AXSnapshotNode(
      id: id,
      parent: nil,
      prevSibling: nil,
      nextSibling: nil,
      children: [],
      attributes: attributes,
      parameterizedAttributes: parameterizedAttributes,
      actions: actions,
      bounds: bounds,
      zIndex: zIndex
    )

    // Cache it immediately to handle any potential cycles
    cache[id] = node

    // Now finalize children and wire up relationships
    node.children = children.map { child in
      let childNode = child.finalize(cache: &cache)
      childNode.parent = node
      return childNode
    }

    // Wire up sibling relationships
    for i in 0..<node.children.count {
      if i > 0 {
        node.children[i].prevSibling = node.children[i - 1]
      }
      if i < node.children.count - 1 {
        node.children[i].nextSibling = node.children[i + 1]
      }
    }

    return node
  }
}

// MARK: - Helper Functions

/// Composes a hierarchical node ID based on parent ID and sibling index
private func composeId(parentId: String?, index: Int) -> String {
  if let parentId = parentId {
    return "\(parentId)-\(index)"
  } else {
    return "#0"
  }
}

/// Collects all attributes from an element
private func collectAttributes(element: AXUIElement, elementIdRegistry: AXElementIdRegistry)
  -> [String: AXSnapshotValue]
{
  var result: [String: AXSnapshotValue] = [:]

  // Get the list of attributes this element actually has
  var names: CFArray?
  guard AXUIElementCopyAttributeNames(element, &names) == .success,
    let attributeNames = names as? [String]
  else {
    return result
  }

  // Fetch all available attributes
  for name in attributeNames {
    var value: AnyObject?
    if AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
      let val = value
    {
      result[name] = convertValue(val, elementIdRegistry: elementIdRegistry)
    }
  }

  // Additionally, try to fetch all standard attributes that Accessibility Inspector shows
  // even if they're not in the reported list (some may be computed or conditionally available)
  let standardAttributes = getStandardAccessibilityAttributes()

  for attrName in standardAttributes {
    // Skip if we already have it
    if result[attrName] != nil {
      continue
    }

    // Try to fetch it
    var value: AnyObject?
    if AXUIElementCopyAttributeValue(element, attrName as CFString, &value) == .success,
      let val = value
    {
      result[attrName] = convertValue(val, elementIdRegistry: elementIdRegistry)
    }
  }

  return result
}

/// Returns a comprehensive list of standard accessibility attributes
/// Based on Apple's Accessibility Programming Guide and common attributes
private func getStandardAccessibilityAttributes() -> [String] {
  return [
    // Basic identification
    kAXRoleAttribute,
    kAXSubroleAttribute,
    kAXRoleDescriptionAttribute,
    kAXTitleAttribute,
    kAXDescriptionAttribute,
    kAXHelpAttribute,
    kAXIdentifierAttribute,

    // Hierarchy and relationships
    kAXParentAttribute,
    kAXChildrenAttribute,
    kAXSelectedChildrenAttribute,
    kAXVisibleChildrenAttribute,
    kAXWindowAttribute,
    kAXTopLevelUIElementAttribute,
    kAXTitleUIElementAttribute,
    kAXServesAsTitleForUIElementsAttribute,
    kAXLinkedUIElementsAttribute,

    // Visual state
    kAXEnabledAttribute,
    kAXFocusedAttribute,
    kAXPositionAttribute,
    kAXSizeAttribute,
    kAXOrientationAttribute,

    // Value attributes
    kAXValueAttribute,
    kAXValueDescriptionAttribute,
    kAXMinValueAttribute,
    kAXMaxValueAttribute,
    kAXValueIncrementAttribute,
    kAXValueWrapsAttribute,
    kAXAllowedValuesAttribute,

    // Text-specific
    kAXSelectedTextAttribute,
    kAXSelectedTextRangeAttribute,
    kAXSelectedTextRangesAttribute,
    kAXVisibleCharacterRangeAttribute,
    kAXNumberOfCharactersAttribute,
    kAXSharedTextUIElementsAttribute,
    kAXSharedCharacterRangeAttribute,
    kAXInsertionPointLineNumberAttribute,

    // Window-specific
    kAXMainAttribute,
    kAXMinimizedAttribute,
    kAXCloseButtonAttribute,
    kAXZoomButtonAttribute,
    kAXMinimizeButtonAttribute,
    kAXToolbarButtonAttribute,
    kAXProxyAttribute,
    kAXGrowAreaAttribute,
    kAXModalAttribute,
    kAXDefaultButtonAttribute,
    kAXCancelButtonAttribute,
    "AXFullScreen",  // Not in standard constants
    kAXFullScreenButtonAttribute,

    // Menu-specific
    kAXMenuItemCmdCharAttribute,
    kAXMenuItemCmdVirtualKeyAttribute,
    kAXMenuItemCmdGlyphAttribute,
    kAXMenuItemCmdModifiersAttribute,
    kAXMenuItemMarkCharAttribute,
    kAXMenuItemPrimaryUIElementAttribute,

    // Application-specific
    kAXMenuBarAttribute,
    kAXWindowsAttribute,
    kAXFrontmostAttribute,
    kAXHiddenAttribute,
    kAXMainWindowAttribute,
    kAXFocusedWindowAttribute,
    kAXFocusedUIElementAttribute,
    kAXExtrasMenuBarAttribute,

    // Table/outline/browser-specific
    kAXRowsAttribute,
    kAXVisibleRowsAttribute,
    kAXSelectedRowsAttribute,
    kAXColumnsAttribute,
    kAXVisibleColumnsAttribute,
    kAXSelectedColumnsAttribute,
    kAXSortDirectionAttribute,
    kAXColumnHeaderUIElementsAttribute,
    kAXIndexAttribute,
    kAXDisclosingAttribute,
    kAXDisclosedRowsAttribute,
    kAXDisclosedByRowAttribute,
    kAXSelectedCellsAttribute,
    kAXVisibleCellsAttribute,
    kAXRowIndexRangeAttribute,
    kAXColumnIndexRangeAttribute,
    kAXHorizontalUnitsAttribute,
    kAXVerticalUnitsAttribute,
    kAXHorizontalUnitDescriptionAttribute,
    kAXVerticalUnitDescriptionAttribute,
    kAXRowCountAttribute,
    kAXColumnCountAttribute,

    // Layout-specific
    kAXHorizontalScrollBarAttribute,
    kAXVerticalScrollBarAttribute,
    kAXHeaderAttribute,
    kAXEditedAttribute,
    kAXTabsAttribute,
    kAXOverflowButtonAttribute,
    kAXFilenameAttribute,
    kAXExpandedAttribute,
    kAXSelectedAttribute,
    kAXSplittersAttribute,
    kAXContentsAttribute,
    kAXNextContentsAttribute,
    kAXPreviousContentsAttribute,
    kAXDocumentAttribute,

    // UI element attributes
    kAXIncrementorAttribute,
    kAXDecrementButtonAttribute,
    kAXIncrementButtonAttribute,
    kAXColumnTitleAttribute,
    kAXURLAttribute,
    kAXLabelUIElementsAttribute,
    kAXLabelValueAttribute,
    kAXShownMenuUIElementAttribute,
    kAXIsApplicationRunningAttribute,
    kAXFocusedApplicationAttribute,
    kAXElementBusyAttribute,
    kAXAlternateUIVisibleAttribute,

    // Matte-specific
    kAXMatteHoleAttribute,
    kAXMatteContentUIElementAttribute,

    // Ruler-specific
    kAXMarkerUIElementsAttribute,
    kAXUnitsAttribute,
    kAXUnitDescriptionAttribute,
    kAXMarkerTypeAttribute,
    kAXMarkerTypeDescriptionAttribute,

    // Date/time-specific
    kAXHourFieldAttribute,
    kAXMinuteFieldAttribute,
    kAXSecondFieldAttribute,
    kAXAMPMFieldAttribute,
    kAXDayFieldAttribute,
    kAXMonthFieldAttribute,
    kAXYearFieldAttribute,

    // Additional common attributes not in constants
    "AXEnhancedUserInterface",
    "AXActivationPoint",
    "AXAutomationType",
    "AXDocument",
    "AXFrame",
    "AXKeyboardFocused",
    "AXMain",
    "AXSections",
    "AXSharedFocusElements",
  ]
}

/// Collects parameterized attribute names
private func collectParameterizedAttributes(element: AXUIElement) -> [String] {
  var names: CFArray?
  guard AXUIElementCopyParameterizedAttributeNames(element, &names) == .success,
    let attributeNames = names as? [String]
  else {
    return []
  }

  return attributeNames
}

/// Collects available actions for an element
private func collectActions(element: AXUIElement) -> [AXSnapshotAction] {
  var names: CFArray?
  guard AXUIElementCopyActionNames(element, &names) == .success,
    let actionNames = names as? [String]
  else {
    return []
  }

  return actionNames.map { name in
    var descriptionRef: CFString?
    let description: String?
    if AXUIElementCopyActionDescription(element, name as CFString, &descriptionRef) == .success,
      let desc = descriptionRef as String?
    {
      description = desc
    } else {
      description = nil
    }

    return AXSnapshotAction(name: name, description: description)
  }
}

/// Extracts geometry information from attributes
private func collectGeometry(
  attributes: [String: AXSnapshotValue],
  element: AXUIElement
) -> GeometryInfo {
  var bounds: CGRect?
  var zIndex: Int?

  // Extract position and size from attributes
  if case .cgPoint(let x, let y) = attributes[kAXPositionAttribute],
    case .cgSize(let width, let height) = attributes[kAXSizeAttribute]
  {
    bounds = CGRect(x: x, y: y, width: width, height: height)
  }

  // Try to get z-index (may not always be available)
  // Note: AX API doesn't always expose z-index; this is a best-effort attempt
  if case .number(let z) = attributes["AXZIndex"] {
    zIndex = Int(z)
  }

  return GeometryInfo(bounds: bounds, zIndex: zIndex)
}

/// Converts an AnyObject value to AXSnapshotValue
private func convertValue(_ value: AnyObject, elementIdRegistry: AXElementIdRegistry)
  -> AXSnapshotValue
{
  // Handle nil
  if value is NSNull {
    return .null
  }

  // Handle String
  if let str = value as? String {
    return .string(str)
  }

  // Handle NSNumber (could be bool or numeric)
  if let num = value as? NSNumber {
    // Check if it's a boolean
    if CFGetTypeID(num as CFTypeRef) == CFBooleanGetTypeID() {
      return .bool(num.boolValue)
    }
    return .number(num.doubleValue)
  }

  // Handle URL
  if let url = value as? URL {
    return .url(url.absoluteString)
  }

  // Handle Date
  if let date = value as? Date {
    let formatter = ISO8601DateFormatter()
    return .date(formatter.string(from: date))
  }

  // Handle Data
  if let data = value as? Data {
    return .data(data.base64EncodedString())
  }

  // Handle AXValue (CGPoint, CGSize, CGRect, CFRange)
  if CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() {
    let axValue = value as! AXValue
    let valueType = AXValueGetType(axValue)

    switch valueType {
    case .cgPoint:
      var point = CGPoint.zero
      if AXValueGetValue(axValue, .cgPoint, &point) {
        return .cgPoint(x: point.x, y: point.y)
      }
    case .cgSize:
      var size = CGSize.zero
      if AXValueGetValue(axValue, .cgSize, &size) {
        return .cgSize(width: size.width, height: size.height)
      }
    case .cgRect:
      var rect = CGRect.zero
      if AXValueGetValue(axValue, .cgRect, &rect) {
        return .cgRect(
          x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
      }
    case .cfRange:
      var range = CFRange(location: 0, length: 0)
      if AXValueGetValue(axValue, .cfRange, &range) {
        return .cfRange(location: range.location, length: range.length)
      }
    default:
      break
    }
  }

  // Handle AXUIElement (nested element reference)
  if CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() {
    let element = value as! AXUIElement

    if let id = elementIdRegistry.lookup(element) {
      // Register this particular reference to speed up future lookups
      elementIdRegistry.registerAlias(element, id: id)
      return .elementReference(id)
    } else {
      return .elementReference("external-element")
    }
  }

  // Handle NSAttributedString
  if let attrString = value as? NSAttributedString {
    return .attributedString(attrString.description)
  }

  // Handle CGPath
  if CFGetTypeID(value as CFTypeRef) == CGPath.typeID {
    let path = value as! CGPath
    return .cgPath(String(describing: path))
  }

  // Handle Array
  if let array = value as? [AnyObject] {
    return .array(array.map { convertValue($0, elementIdRegistry: elementIdRegistry) })
  }

  // Handle Dictionary
  if let dict = value as? [AnyHashable: AnyObject] {
    var result: [String: AXSnapshotValue] = [:]
    for (key, val) in dict {
      if let keyStr = key as? String {
        result[keyStr] = convertValue(val, elementIdRegistry: elementIdRegistry)
      }
    }
    return .dictionary(result)
  }

  // Fallback: convert to string description
  return .unknown(String(describing: value))
}
