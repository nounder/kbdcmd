import AppKit
import Foundation

public enum TextInserter {
  private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

  // Must be called on the main thread: key emission resolves layout-dependent
  // key codes through HIToolbox TSM, which asserts on the main queue.
  public static func insert(_ text: String, mode: DictationSettings.InsertMode = DictationSettings.insertMode) {
    guard !text.isEmpty else { return }
    switch mode {
    case .paste:
      paste(text)
    case .type:
      try? KeyEmitter.emit([.text(text)], delay: 0)
    }
  }

  private static func paste(_ text: String) {
    let pasteboard = NSPasteboard.general
    let saved = snapshot(pasteboard)

    pasteboard.clearContents()
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    item.setString("", forType: transientType)
    pasteboard.writeObjects([item])
    let ourChangeCount = pasteboard.changeCount

    try? KeyEmitter.emit(Keystroke(.char("v"), .cmd))
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      restore(saved, to: pasteboard, ifChangeCountIs: ourChangeCount)
    }
  }

  private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
    (pasteboard.pasteboardItems ?? []).map { item in
      var entry: [NSPasteboard.PasteboardType: Data] = [:]
      for type in item.types {
        if let data = item.data(forType: type) {
          entry[type] = data
        }
      }
      return entry
    }
  }

  private static func restore(
    _ saved: [[NSPasteboard.PasteboardType: Data]],
    to pasteboard: NSPasteboard,
    ifChangeCountIs expected: Int
  ) {
    guard pasteboard.changeCount == expected else { return }
    pasteboard.clearContents()
    guard !saved.isEmpty else { return }
    let items = saved.map { entry -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for (type, data) in entry {
        item.setData(data, forType: type)
      }
      return item
    }
    pasteboard.writeObjects(items)
  }
}
