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

  // Converts a phrase into the same token pieces emitted by the model. This is
  // intentionally a vocabulary segmentation rather than a second tokenizer:
  // contextual biasing must use IDs from this exact model vocabulary.
  func encodePhrase(_ phrase: String) -> [Int]? {
    let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !phrase.isEmpty else { return nil }

    let pieces = vocabulary.compactMap { id, piece -> (id: Int, characters: [Character])? in
      guard id != ParakeetConstants.blankId,
        !piece.isEmpty,
        !piece.hasPrefix("<")
      else { return nil }
      // Some compatible vocabularies use SentencePiece's visible space marker,
      // while the current Parakeet vocabulary stores an ordinary leading space.
      let normalized = piece.replacingOccurrences(of: "\u{2581}", with: " ")
      return (id, Array(normalized))
    }

    // Prefer a leading-space encoding so a hotword starts at a word boundary.
    for candidate in [" " + phrase, phrase] {
      let target = Array(candidate)
      var paths = [[Int]?](repeating: nil, count: target.count + 1)
      paths[0] = []

      for offset in 0..<target.count {
        guard let path = paths[offset] else { continue }
        for piece in pieces where offset + piece.characters.count <= target.count {
          guard target[offset..<(offset + piece.characters.count)].elementsEqual(piece.characters)
          else { continue }
          let end = offset + piece.characters.count
          let next = path + [piece.id]
          if paths[end] == nil || next.count < paths[end]!.count {
            paths[end] = next
          }
        }
      }

      if let tokens = paths[target.count], !tokens.isEmpty {
        return tokens
      }
    }
    return nil
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
