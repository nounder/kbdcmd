import Foundation

struct ParakeetTokenizer {
  private let vocabulary: [Int: String]

  init(vocabulary: [Int: String]) {
    self.vocabulary = vocabulary
  }

  init(vocabularyFile url: URL) throws {
    let data = try Data(contentsOf: url)
    let json = try JSONSerialization.jsonObject(with: data)
    var vocabulary: [Int: String] = [:]
    if let array = json as? [String] {
      for (index, token) in array.enumerated() {
        vocabulary[index] = token
      }
    } else if let dict = json as? [String: String] {
      for (key, value) in dict {
        if let tokenId = Int(key) {
          vocabulary[tokenId] = value
        }
      }
    } else {
      throw DictationError.processingFailed("Unrecognized vocabulary format in \(url.lastPathComponent)")
    }
    guard !vocabulary.isEmpty else {
      throw DictationError.processingFailed("Empty vocabulary in \(url.lastPathComponent)")
    }
    self.vocabulary = vocabulary
  }

  func decode(_ tokenIds: [Int]) -> String {
    var text = ""
    for id in tokenIds {
      guard let piece = vocabulary[id] else { continue }
      text += piece
    }
    return
      text
      .replacingOccurrences(of: "\u{2581}", with: " ")
      .trimmingCharacters(in: .whitespaces)
  }
}
