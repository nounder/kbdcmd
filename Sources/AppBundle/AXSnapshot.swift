import ApplicationServices
import Foundation

// MARK: - AXSnapshot

/// A complete snapshot of an accessibility tree with timing information
struct AXSnapshot: Codable {
    let root: AXSnapshotNode
    let timings: [TimingEntry]
    let metadata: SnapshotMetadata

    struct SnapshotMetadata: Codable {
        let timestamp: Date
        let totalDuration: TimeInterval
        let nodeCount: Int
    }
}

// MARK: - AXSnapshotNode

/// Represents a single node in the accessibility tree snapshot
final class AXSnapshotNode: Codable {
    let id: String
    weak var parent: AXSnapshotNode?
    weak var prevSibling: AXSnapshotNode?
    weak var nextSibling: AXSnapshotNode?
    var children: [AXSnapshotNode]

    let attributes: [String: AXSnapshotValue]
    let parameterizedAttributes: [String]
    let actions: [AXSnapshotAction]

    // Extracted geometry/position info
    let position: CGPoint?
    let size: CGSize?
    let zIndex: Int?

    init(
        id: String,
        parent: AXSnapshotNode?,
        prevSibling: AXSnapshotNode?,
        nextSibling: AXSnapshotNode?,
        children: [AXSnapshotNode],
        attributes: [String: AXSnapshotValue],
        parameterizedAttributes: [String],
        actions: [AXSnapshotAction],
        position: CGPoint?,
        size: CGSize?,
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
        self.position = position
        self.size = size
        self.zIndex = zIndex
    }
}

// MARK: - AXSnapshotReference

/// A reference to another node in the tree (for parent/sibling relationships)
struct AXSnapshotReference: Codable {
    let id: String
}

// MARK: - AXSnapshotAction

/// Represents an accessibility action that can be performed on an element
struct AXSnapshotAction: Codable {
    let name: String
    let description: String?
}

// MARK: - AXSnapshotValue

/// Represents any value type that can appear in accessibility attributes
enum AXSnapshotValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case url(String)
    case date(String)
    case data(String)  // base64 encoded
    case array([AXSnapshotValue])
    case dictionary([String: AXSnapshotValue])
    case point(x: Double, y: Double)
    case size(width: Double, height: Double)
    case rect(x: Double, y: Double, width: Double, height: Double)
    case range(location: Int, length: Int)
    case elementReference(String)  // reference to another element by id
    case unknown(String)  // fallback description
}

// MARK: - TimingEntry

/// Records timing information for each operation during snapshot
struct TimingEntry: Codable {
    let operation: String
    let nodeId: String
    let duration: TimeInterval
    let timestamp: Date
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
    let position: CGPoint?
    let size: CGSize?
    let zIndex: Int?
}

// MARK: - Snapshot Generation

extension AXSnapshot {
    /// Creates a complete snapshot of the accessibility tree starting from the given root element
    /// - Parameters:
    ///   - root: The root AXUIElement to start traversal from
    ///   - progressCallback: Optional callback called for each node processed (nodeId, nodeCount, node)
    static func snapshot(
        root: AXUIElement,
        progressCallback: ((String, Int, MutableNode) -> Void)? = nil
    ) -> AXSnapshot {
        let tree = AXTree(root: root)
        var nodeStack: [MutableNode] = []
        var siblingStack: [[MutableNode]] = [[]]
        var rootNode: MutableNode?
        let timings = TimingRecorder()
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
                collectAttributes(element: element)
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
                position: geometry.position,
                size: geometry.size,
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
internal class MutableNode {
    let id: String
    weak var parent: MutableNode?
    weak var prevSibling: MutableNode?
    var nextSibling: MutableNode?
    var children: [MutableNode] = []

    let attributes: [String: AXSnapshotValue]
    let parameterizedAttributes: [String]
    let actions: [AXSnapshotAction]
    let position: CGPoint?
    let size: CGSize?
    let zIndex: Int?

    init(
        id: String,
        parent: MutableNode?,
        prevSibling: MutableNode?,
        attributes: [String: AXSnapshotValue],
        parameterizedAttributes: [String],
        actions: [AXSnapshotAction],
        position: CGPoint?,
        size: CGSize?,
        zIndex: Int?
    ) {
        self.id = id
        self.parent = parent
        self.prevSibling = prevSibling
        self.attributes = attributes
        self.parameterizedAttributes = parameterizedAttributes
        self.actions = actions
        self.position = position
        self.size = size
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
            position: position,
            size: size,
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
        return "0"
    }
}

/// Collects all attributes from an element
private func collectAttributes(element: AXUIElement) -> [String: AXSnapshotValue] {
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
            result[name] = convertValue(val)
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
            result[attrName] = convertValue(val)
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
    var position: CGPoint?
    var size: CGSize?
    var zIndex: Int?

    // Extract position from attributes
    if case .point(let x, let y) = attributes[kAXPositionAttribute] {
        position = CGPoint(x: x, y: y)
    }

    // Extract size from attributes
    if case .size(let width, let height) = attributes[kAXSizeAttribute] {
        size = CGSize(width: width, height: height)
    }

    // Try to get z-index (may not always be available)
    // Note: AX API doesn't always expose z-index; this is a best-effort attempt
    if case .number(let z) = attributes["AXZIndex"] {
        zIndex = Int(z)
    }

    return GeometryInfo(position: position, size: size, zIndex: zIndex)
}

/// Converts an AnyObject value to AXSnapshotValue
private func convertValue(_ value: AnyObject) -> AXSnapshotValue {
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
                return .point(x: point.x, y: point.y)
            }
        case .cgSize:
            var size = CGSize.zero
            if AXValueGetValue(axValue, .cgSize, &size) {
                return .size(width: size.width, height: size.height)
            }
        case .cgRect:
            var rect = CGRect.zero
            if AXValueGetValue(axValue, .cgRect, &rect) {
                return .rect(
                    x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
            }
        case .cfRange:
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue(axValue, .cfRange, &range) {
                return .range(location: range.location, length: range.length)
            }
        default:
            break
        }
    }

    // Handle AXUIElement (nested element reference)
    if CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() {
        // For now, just mark as element reference
        // In a full implementation, we might want to track these and assign IDs
        return .elementReference("nested-element")
    }

    // Handle Array
    if let array = value as? [AnyObject] {
        return .array(array.map { convertValue($0) })
    }

    // Handle Dictionary
    if let dict = value as? [AnyHashable: AnyObject] {
        var result: [String: AXSnapshotValue] = [:]
        for (key, val) in dict {
            if let keyStr = key as? String {
                result[keyStr] = convertValue(val)
            }
        }
        return .dictionary(result)
    }

    // Fallback: convert to string description
    return .unknown(String(describing: value))
}
