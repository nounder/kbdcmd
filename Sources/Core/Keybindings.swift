import Carbon
import Cocoa
import Foundation

// MARK: - Key Enum (Union type: Character or SpecialKey)

public enum Key: Hashable {
  case character(Character)
  case named(Named)

  public enum Named: Int64, CaseIterable {
    case escape = 53
    case tab = 48
    case `return` = 36
    case delete = 51  // Backspace
    case forwardDelete = 117
    case space = 49
    case leftArrow = 123
    case rightArrow = 124
    case downArrow = 125
    case upArrow = 126
    case home = 115
    case end = 119
    case pageUp = 116
    case pageDown = 121
    case f1 = 122
    case f2 = 120
    case f3 = 99
    case f4 = 118
    case f5 = 96
    case f6 = 97
    case f7 = 98
    case f8 = 100
    case f9 = 101
    case f10 = 109
    case f11 = 103
    case f12 = 111
    case leftCommand = 55
    case rightCommand = 54
    case leftOption = 58
    case rightOption = 61
    case leftControl = 59
    case rightControl = 62
  }
}

// MARK: - Modifier Enum

public enum Modifier: Hashable {
  case control(Side)
  case option(Side)
  case command(Side)
  case capsLock

  public enum Side: Hashable {
    case left
    case right
    case either
  }
}

// MARK: - Sequence Support

public struct KeyPress {
  public let key: Key
  public let flags: CGEventFlags

  public init(key: Key, flags: CGEventFlags = CGEventFlags(rawValue: 0)) {
    self.key = key
    self.flags = flags
  }
}

private struct KeyInSequence: Hashable {
  let key: Key
  let flags: UInt64

  init(_ press: KeyPress, modifierMask: UInt64) {
    switch press.key {
    case .character(let char):
      self.key = .character(Character(String(char).uppercased()))
    case .named:
      self.key = press.key
    }
    self.flags = press.flags.rawValue & modifierMask
  }
}

private class SequenceNode {
  var action: (([KeyPress]) -> Void)?
  var sequence: [KeyPress]?
  var consume: Bool = false  // By default, don't consume the event (let it pass through)
  var children: [KeyInSequence: SequenceNode] = [:]
}

// MARK: - Action Types

public enum KeybindingAction: Equatable {
  case appActivation(appPath: String)
  case windowActivation(windowId: CGWindowID, appPath: String, includeMinimized: Bool)
}

// MARK: - Persistence Model

struct KeybindingItem: Codable {
  let letter: String
  let appPath: String
  let windowId: CGWindowID?
}

struct KeybindingsFile: Codable {
  let version: Int
  let items: [KeybindingItem]
}

// MARK: - Keybindings Class

public class Keybindings {
  public static let shared = Keybindings()

  // Unified storage: trie structure for all keybindings (single-key and sequences)
  private var sequenceRoot = SequenceNode()

  // In-memory storage for all keybindings (letter -> action)
  // App bindings are persisted, window bindings are ephemeral
  private var keybindings: [Character: KeybindingAction] = [:]

  // Window monitoring - one observer per app (pid), tracking which windows we're monitoring
  private var appObservers: [pid_t: AXObserver] = [:]
  private var monitoredWindows: [pid_t: Set<CGWindowID>] = [:]

  // Modifier mask for extracting only relevant flags
  private let modifierMask: UInt64 = {
    CGEventFlags.maskControlLeft.rawValue | CGEventFlags.maskControlRight.rawValue
      | CGEventFlags.maskOptionLeft.rawValue | CGEventFlags.maskOptionRight.rawValue
      | CGEventFlags.maskCmdLeft.rawValue | CGEventFlags.maskCmdRight.rawValue
      | CGEventFlags.maskShiftLeft.rawValue | CGEventFlags.maskShiftRight.rawValue
      | CGEventFlags.maskAlphaShift.rawValue
  }()

  private let configDirectory: URL
  private let keysFileURL: URL

  init() {
    // Setup config directory: $HOME/.config/kbdcmd
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    configDirectory = homeDirectory.appendingPathComponent(".config/kbdcmd")
    keysFileURL = configDirectory.appendingPathComponent("keys.json")

    // Create config directory if it doesn't exist
    try? FileManager.default.createDirectory(
      at: configDirectory,
      withIntermediateDirectories: true,
      attributes: nil
    )

    // Load saved keybindings
    loadKeybindings()
  }

  // MARK: - Registration

  public func register<S: Sequence>(
    _ sequence: S, consume: Bool = true, action: @escaping ([KeyPress]) -> Void
  )
  where S.Element == KeyPress {

    let seq = Array(sequence)
    guard !seq.isEmpty else { return }

    let firstMasked = seq[0].flags.rawValue & modifierMask
    let firstHasModifiers = firstMasked != 0

    if firstHasModifiers {
      for i in 1..<seq.count {
        let masked = seq[i].flags.rawValue & modifierMask
        guard masked == 0 else {
          print("ERROR: Only first key in sequence can have modifiers")
          return
        }
      }
    }

    let expandedSequences = expandEitherInSequence(seq)

    for expanded in expandedSequences {
      var node = sequenceRoot
      for press in expanded {
        let element = KeyInSequence(press, modifierMask: modifierMask)
        if node.children[element] == nil {
          node.children[element] = SequenceNode()
        }
        node = node.children[element]!
      }
      node.sequence = expanded
      node.action = action
      node.consume = consume
    }
  }

  // MARK: - Lookup

  public enum SequenceMatch {
    case complete(action: ([KeyPress]) -> Void, sequence: [KeyPress], consume: Bool)
    case partial
    case noMatch
  }

  public func matchSequence<S: Sequence>(_ buffer: S) -> SequenceMatch
  where S.Element == KeyPress {

    let bufferArray = Array(buffer)
    guard !bufferArray.isEmpty else { return .noMatch }

    // Find all matching paths where registered modifiers are subset of pressed modifiers
    var candidates:
      [(action: ([KeyPress]) -> Void, sequence: [KeyPress], flags: UInt64, consume: Bool)] = []
    var hasPartialMatch = false

    findMatches(
      at: sequenceRoot,
      buffer: bufferArray,
      index: 0,
      candidates: &candidates,
      hasPartialMatch: &hasPartialMatch
    )

    // If we found complete matches, return the most specific one
    if !candidates.isEmpty {
      let bestMatch = candidates.max { a, b in
        isMoreSpecific(b.flags, than: a.flags)
      }!
      return .complete(
        action: bestMatch.action, sequence: bestMatch.sequence, consume: bestMatch.consume)
    }

    return hasPartialMatch ? .partial : .noMatch
  }

  private func findMatches(
    at node: SequenceNode,
    buffer: [KeyPress],
    index: Int,
    candidates: inout [(
      action: ([KeyPress]) -> Void, sequence: [KeyPress], flags: UInt64, consume: Bool
    )],
    hasPartialMatch: inout Bool
  ) {
    // Base case: we've matched all keys in the buffer
    if index >= buffer.count {
      if let action = node.action, let sequence = node.sequence {
        // Extract flags from first key press (only first key can have modifiers)
        let flags = sequence.first?.flags.rawValue ?? 0
        candidates.append((action: action, sequence: sequence, flags: flags, consume: node.consume))
      }
      if !node.children.isEmpty {
        hasPartialMatch = true
      }
      return
    }

    let press = buffer[index]
    let pressedElement = KeyInSequence(press, modifierMask: modifierMask)

    // Check all children where registered flags are a subset of pressed flags
    for (childKey, childNode) in node.children {
      // Keys must match
      guard childKey.key == pressedElement.key else { continue }

      // Registered flags must be a subset of pressed flags
      // (registeredFlags & pressedFlags) == registeredFlags
      if (childKey.flags & pressedElement.flags) == childKey.flags {
        findMatches(
          at: childNode,
          buffer: buffer,
          index: index + 1,
          candidates: &candidates,
          hasPartialMatch: &hasPartialMatch
        )
      }
    }
  }

  private func isMoreSpecific(_ a: UInt64, than b: UInt64) -> Bool {
    // If A contains all of B's flags AND has additional flags, A is more specific
    if (a & b) == b && a != b {
      return true
    }
    // If B contains all of A's flags AND has additional flags, B is more specific (A is not)
    if (b & a) == a && b != a {
      return false
    }
    // Neither is a subset of the other - use raw value as tiebreaker
    return a > b
  }

  // MARK: - App Keybinding Management

  public func assignAppKeybinding(character: Character, appPath: String) {
    let upperLetter = Character(String(character).uppercased())

    // If this app already has a different keybinding, remove it
    if let existingKey = getKeybindingForApp(appPath), existingKey != upperLetter {
      keybindings.removeValue(forKey: existingKey)
    }

    // Clean up window observer if this letter was assigned to a window
    if case .windowActivation(let windowId, _, _) = keybindings[upperLetter] {
      stopMonitoringWindow(windowId)
    }

    // Assign new keybinding (this will overwrite if the letter was already assigned to another app/window)
    keybindings[upperLetter] = .appActivation(appPath: appPath)

    // Register the keybinding with right command
    register([KeyPress(key: .character(upperLetter), flags: .maskCmdRight)]) { _ in
      _ = try? ApplicationManager.openOrFocus(appPath)
    }

    // Save to disk
    saveKeybindings()
  }

  public func getAppKeybindings() -> [Character: String] {
    return keybindings.compactMap { letter, action in
      if case .appActivation(let appPath) = action {
        return (letter, appPath)
      }
      return nil
    }.reduce(into: [Character: String]()) { result, pair in
      result[pair.0] = pair.1
    }
  }

  public func getKeybindingForApp(_ appPath: String) -> Character? {
    return keybindings.first {
      if case .appActivation(let path) = $0.value, path == appPath {
        return true
      }
      return false
    }?.key
  }

  // MARK: - Window Keybinding Management

  public func assignWindowKeybinding(
    character: Character, windowId: CGWindowID, includeMinimized: Bool = false
  ) {
    let upperLetter = Character(String(character).uppercased())
    debugLog(
      "Assigning window \(windowId) to key '\(upperLetter)', includeMinimized: \(includeMinimized)")

    // Get the app path for this window
    guard let appPath = getAppPathForWindow(windowId) else {
      debugLog("Failed to get app path for window \(windowId)")
      return
    }

    // Clean up previous assignment if any
    if case .windowActivation(let oldWindowId, _, _) = keybindings[upperLetter] {
      stopMonitoringWindow(oldWindowId)
    }

    // Assign new keybinding
    keybindings[upperLetter] = .windowActivation(
      windowId: windowId, appPath: appPath, includeMinimized: includeMinimized)
    debugLog("Stored keybinding: \(upperLetter) -> window \(windowId) in app \(appPath)")

    // Register the keybinding with right command
    register([KeyPress(key: .character(upperLetter), flags: .maskCmdRight)]) { [weak self] _ in
      guard let self = self else { return }
      debugLog("Keybinding '\(upperLetter)' triggered for window \(windowId)")
      Task {
        if await !WindowManager.main.activateWindow(windowId: windowId, includeMinimized: includeMinimized)
        {
          // Window doesn't exist anymore, remove keybinding
          debugLog("Window activation failed, removing keybinding '\(upperLetter)'")
          self.removeKeybinding(forLetter: upperLetter)
        }
      }
    }

    // Start monitoring this window for destruction
    startMonitoringWindow(windowId)

    // Save to disk (now includes window bindings)
    saveKeybindings()
  }

  private func getAppPathForWindow(_ windowId: CGWindowID) -> String? {
    let windowsInfo = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)

    guard let windowList = windowsInfo as? [[String: Any]],
          let windowDict = windowList.first(where: {
            ($0[kCGWindowNumber as String] as? CGWindowID) == windowId
          }),
          let pid = windowDict[kCGWindowOwnerPID as String] as? pid_t,
          let app = NSRunningApplication(processIdentifier: pid),
          let bundleURL = app.bundleURL
    else {
      return nil
    }
    
    return bundleURL.path
  }

  public func getKeybindingForWindow(_ windowId: CGWindowID) -> Character? {
    let result = keybindings.first {
      if case .windowActivation(let id, _, _) = $0.value, id == windowId {
        return true
      }
      return false
    }?.key

    if result != nil {
      debugLog("Found keybinding '\(result!)' for window \(windowId)")
    }

    return result
  }

  public func removeKeybinding(forLetter letter: Character) {
    let upperLetter = Character(String(letter).uppercased())

    // Clean up window observer if this was a window keybinding
    if case .windowActivation(let windowId, _, _) = keybindings[upperLetter] {
      stopMonitoringWindow(windowId)
    }

    keybindings.removeValue(forKey: upperLetter)

    // If it was an app keybinding, update persistence
    saveKeybindings()
  }

  public func getKeybindings() -> [Character: KeybindingAction] {
    return keybindings
  }

  // MARK: - Window Monitoring

  private func startMonitoringWindow(_ windowId: CGWindowID) {
    // Get window's pid
    let windowsInfo = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)

    guard let windowList = windowsInfo as? [[String: Any]],
      let windowDict = windowList.first(where: {
        ($0[kCGWindowNumber as String] as? CGWindowID) == windowId
      }),
      let pid = windowDict[kCGWindowOwnerPID as String] as? pid_t
    else {
      debugLog("Failed to find window \(windowId) for monitoring")
      return
    }

    // Check if we already have an observer for this app
    if appObservers[pid] != nil {
      // Observer already exists for this app, just track this window
      monitoredWindows[pid, default: []].insert(windowId)
      debugLog("Added window \(windowId) to existing observer for pid \(pid)")
      return
    }

    // Create new observer for this app
    var observer: AXObserver?
    let result = AXObserverCreate(
      pid,
      { (observer, element, notification, refcon) in
        let keybindings = Unmanaged<Keybindings>.fromOpaque(refcon!).takeUnretainedValue()

        // Check if this is a window we're monitoring
        if let windowId = element.containingWindowId() {
          keybindings.handleWindowDestroyed(windowId)
        }
      }, &observer)

    guard result == .success, let observer = observer else {
      debugLog("Failed to create AX observer for pid \(pid)")
      return
    }

    // Get app element
    let axApp = AXUIElementCreateApplication(pid)

    // Add notification for window destruction
    AXObserverAddNotification(
      observer,
      axApp,
      kAXUIElementDestroyedNotification as CFString,
      Unmanaged.passUnretained(self).toOpaque()
    )

    // Add to run loop
    CFRunLoopAddSource(
      CFRunLoopGetCurrent(),
      AXObserverGetRunLoopSource(observer),
      .defaultMode
    )

    // Store observer and track this window
    appObservers[pid] = observer
    monitoredWindows[pid] = [windowId]
    debugLog("Created new observer for pid \(pid), monitoring window \(windowId)")
  }

  private func stopMonitoringWindow(_ windowId: CGWindowID) {
    // Find which pid this window belongs to
    guard let pid = monitoredWindows.first(where: { $0.value.contains(windowId) })?.key else {
      debugLog("Window \(windowId) not found in monitored windows")
      return
    }

    // Remove this window from the tracked set
    monitoredWindows[pid]?.remove(windowId)
    debugLog("Removed window \(windowId) from monitoring for pid \(pid)")

    // If no more windows are being monitored for this app, remove the observer
    if monitoredWindows[pid]?.isEmpty == true {
      if let observer = appObservers[pid] {
        CFRunLoopRemoveSource(
          CFRunLoopGetCurrent(),
          AXObserverGetRunLoopSource(observer),
          .defaultMode
        )
        appObservers.removeValue(forKey: pid)
        monitoredWindows.removeValue(forKey: pid)
        debugLog("Removed observer for pid \(pid) (no more monitored windows)")
      }
    }
  }

  private func handleWindowDestroyed(_ windowId: CGWindowID) {
    debugLog("Window \(windowId) destroyed")

    // Find and remove keybinding for this window
    if let letter = keybindings.first(where: {
      if case .windowActivation(let id, _, _) = $0.value, id == windowId {
        return true
      }
      return false
    })?.key {
      debugLog("Removing keybinding '\(letter)' for destroyed window \(windowId)")
      removeKeybinding(forLetter: letter)
    }
  }

  // MARK: - Persistence

  private func loadKeybindings() {
    Task {
      await loadKeybindingsAsync()
    }
  }

  private func loadKeybindingsAsync() async {
    guard FileManager.default.fileExists(atPath: keysFileURL.path) else {
      return
    }

    do {
      let data = try Data(contentsOf: keysFileURL)
      let file = try JSONDecoder().decode(KeybindingsFile.self, from: data)

      // Check version compatibility (currently only version 1 exists)
      guard file.version == 1 else {
        print("Unsupported keybindings file version: \(file.version)")
        return
      }

      // Restore keybindings
      for item in file.items {
        guard let letter = item.letter.first else { continue }
        let upperLetter = Character(String(letter).uppercased())

        if let windowId = item.windowId {
          // This is a window keybinding
          // Check if the window still exists before restoring the keybinding
          if await WindowManager.main.windowExists(windowId: windowId, appPath: item.appPath) {
            keybindings[upperLetter] = .windowActivation(windowId: windowId, appPath: item.appPath, includeMinimized: true)

            // Register the keybinding
            register([KeyPress(key: .character(upperLetter), flags: .maskCmdRight)]) { [weak self] _ in
              guard let self = self else { return }
              Task {
                if await !WindowManager.main.activateWindow(windowId: windowId, includeMinimized: true) {
                  // Window doesn't exist anymore, remove keybinding
                  self.removeKeybinding(forLetter: upperLetter)
                }
              }
            }

            // Start monitoring this window for destruction
            startMonitoringWindow(windowId)
          } else {
            // Window doesn't exist anymore, skip this keybinding (it will be excluded from next save)
            debugLog("Window \(windowId) no longer exists, skipping keybinding '\(upperLetter)'")
          }
        } else {
          // This is an app keybinding
          keybindings[upperLetter] = .appActivation(appPath: item.appPath)

          // Register the keybinding
          register([KeyPress(key: .character(upperLetter), flags: .maskCmdRight)]) { _ in
            _ = try? ApplicationManager.openOrFocus(item.appPath)
          }
        }
      }
      
      // Save keybindings to remove any windows that no longer exist
      saveKeybindings()
    } catch {
      print("Failed to load keybindings: \(error)")
    }
  }

  private func saveKeybindings() {
    let items = keybindings.compactMap { letter, action -> KeybindingItem? in
      switch action {
      case .appActivation(let appPath):
        return KeybindingItem(letter: String(letter), appPath: appPath, windowId: nil)
      case .windowActivation(let windowId, let appPath, let includeMinimized):
        return KeybindingItem(letter: String(letter), appPath: appPath, windowId: windowId)
      }
    }.sorted { $0.letter < $1.letter }

    let file = KeybindingsFile(version: 1, items: items)

    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(file)
      try data.write(to: keysFileURL, options: .atomic)
    } catch {
      print("Failed to save keybindings: \(error)")
    }
  }

  // MARK: - Helpers

  private func expandEitherInSequence(_ sequence: [KeyPress]) -> [[KeyPress]] {
    var hasEither = false
    for press in sequence {
      if hasEitherModifier(press.flags) {
        hasEither = true
        break
      }
    }

    if !hasEither {
      return [sequence]
    }

    var results: [[KeyPress]] = [[]]

    for press in sequence {
      if hasEitherModifier(press.flags) {
        let expansions = expandEitherFlags(press.flags)
        results = results.flatMap { partial in
          expansions.map { expandedFlags in
            partial + [KeyPress(key: press.key, flags: expandedFlags)]
          }
        }
      } else {
        results = results.map { $0 + [press] }
      }
    }

    return results
  }

  private func hasEitherModifier(_ flags: CGEventFlags) -> Bool {
    // Check if BOTH left and right variants are set (indicates .either)
    let hasControlBoth = flags.contains(.maskControlLeft) && flags.contains(.maskControlRight)
    let hasOptionBoth = flags.contains(.maskOptionLeft) && flags.contains(.maskOptionRight)
    let hasCmdBoth = flags.contains(.maskCmdLeft) && flags.contains(.maskCmdRight)
    let hasShiftBoth = flags.contains(.maskShiftLeft) && flags.contains(.maskShiftRight)

    return hasControlBoth || hasOptionBoth || hasCmdBoth || hasShiftBoth
  }

  private func expandEitherFlags(_ flags: CGEventFlags) -> [CGEventFlags] {
    var results: [CGEventFlags] = [CGEventFlags(rawValue: 0)]

    // Handle control either
    if flags.contains(.maskControlLeft) && flags.contains(.maskControlRight) {
      results = results.flatMap { base in
        [
          CGEventFlags(rawValue: base.rawValue | CGEventFlags.maskControlLeft.rawValue),
          CGEventFlags(rawValue: base.rawValue | CGEventFlags.maskControlRight.rawValue),
        ]
      }
    } else if flags.contains(.maskControlLeft) {
      results = results.map {
        CGEventFlags(rawValue: $0.rawValue | CGEventFlags.maskControlLeft.rawValue)
      }
    } else if flags.contains(.maskControlRight) {
      results = results.map {
        CGEventFlags(rawValue: $0.rawValue | CGEventFlags.maskControlRight.rawValue)
      }
    }

    // Handle option either
    if flags.contains(.maskOptionLeft) && flags.contains(.maskOptionRight) {
      results = results.flatMap { base in
        [
          CGEventFlags(rawValue: base.rawValue | CGEventFlags.maskOptionLeft.rawValue),
          CGEventFlags(rawValue: base.rawValue | CGEventFlags.maskOptionRight.rawValue),
        ]
      }
    } else if flags.contains(.maskOptionLeft) {
      results = results.map {
        CGEventFlags(rawValue: $0.rawValue | CGEventFlags.maskOptionLeft.rawValue)
      }
    } else if flags.contains(.maskOptionRight) {
      results = results.map {
        CGEventFlags(rawValue: $0.rawValue | CGEventFlags.maskOptionRight.rawValue)
      }
    }

    // Handle command either
    if flags.contains(.maskCmdLeft) && flags.contains(.maskCmdRight) {
      results = results.flatMap { base in
        [
          CGEventFlags(rawValue: base.rawValue | CGEventFlags.maskCmdLeft.rawValue),
          CGEventFlags(rawValue: base.rawValue | CGEventFlags.maskCmdRight.rawValue),
        ]
      }
    } else if flags.contains(.maskCmdLeft) {
      results = results.map {
        CGEventFlags(rawValue: $0.rawValue | CGEventFlags.maskCmdLeft.rawValue)
      }
    } else if flags.contains(.maskCmdRight) {
      results = results.map {
        CGEventFlags(rawValue: $0.rawValue | CGEventFlags.maskCmdRight.rawValue)
      }
    }

    // Handle shift either
    if flags.contains(.maskShiftLeft) && flags.contains(.maskShiftRight) {
      results = results.flatMap { base in
        [
          CGEventFlags(rawValue: base.rawValue | CGEventFlags.maskShiftLeft.rawValue),
          CGEventFlags(rawValue: base.rawValue | CGEventFlags.maskShiftRight.rawValue),
        ]
      }
    } else if flags.contains(.maskShiftLeft) {
      results = results.map {
        CGEventFlags(rawValue: $0.rawValue | CGEventFlags.maskShiftLeft.rawValue)
      }
    } else if flags.contains(.maskShiftRight) {
      results = results.map {
        CGEventFlags(rawValue: $0.rawValue | CGEventFlags.maskShiftRight.rawValue)
      }
    }

    // Handle capsLock
    if flags.contains(.maskAlphaShift) {
      results = results.map {
        CGEventFlags(rawValue: $0.rawValue | CGEventFlags.maskAlphaShift.rawValue)
      }
    }

    return results
  }

}
