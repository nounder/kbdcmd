import ApplicationServices

// MARK: - Traversal Control

enum AXTraversalAction {
  case `continue`
  case skipChildren
  case stop
}

// MARK: - AXTree

class AXTree {
  let root: AXUIElement

  init(root: AXUIElement) {
    self.root = root
  }

  /// Traverse the accessibility tree depth-first
  /// Visitor returns AXTraversalAction to control flow (nil = continue)
  func traverse(_ visitor: (AXUIElement, Int) -> AXTraversalAction?) {
    var queue: [(AXUIElement, Int)] = [(root, 0)]

    while let (element, depth) = queue.popLast() {
      let action = visitor(element, depth) ?? .continue

      if action == .stop {
        return
      }

      if action == .continue {
        var children: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
          == .success,
          let childElements = children as? [AXUIElement]
        {
          for child in childElements.reversed() {
            queue.append((child, depth + 1))
          }
        }
      }
    }
  }

  /// Collect elements based on visitor callback
  /// Returns array of all elements where visitor was called
  func collect(_ visitor: (AXUIElement, Int) -> AXTraversalAction?) -> [AXUIElement] {
    var results: [AXUIElement] = []

    traverse { element, depth in
      results.append(element)
      return visitor(element, depth)
    }

    return results
  }
}
