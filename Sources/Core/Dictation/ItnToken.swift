import Foundation

struct ItnToken {
  var text: String
  var normalized: String
  var leadingSpace: Bool

  init(text: String, leadingSpace: Bool) {
    self.text = text
    self.leadingSpace = leadingSpace
    self.normalized = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",."))
  }
}

enum ItnTokenizer {
  static func tokenize(_ text: String) -> [ItnToken] {
    var tokens: [ItnToken] = []
    var current = ""
    var pendingSpace = false

    for character in text {
      if character.isWhitespace {
        if !current.isEmpty {
          tokens.append(ItnToken(text: current, leadingSpace: pendingSpace))
          current = ""
          pendingSpace = true
        } else if !tokens.isEmpty {
          pendingSpace = true
        }
        continue
      }
      current.append(character)
    }
    if !current.isEmpty {
      tokens.append(ItnToken(text: current, leadingSpace: pendingSpace))
    }
    return tokens
  }

  static func join(_ pieces: [ItnPiece]) -> String {
    var result = ""
    for piece in pieces {
      if piece.attachesLeft || result.isEmpty || result.hasSuffix("\n") {
        result += piece.text
      } else if piece.leadingSpace {
        result += " " + piece.text
      } else {
        result += piece.text
      }
    }
    return result
  }
}

struct ItnPiece {
  var text: String
  var leadingSpace: Bool
  var attachesLeft: Bool

  init(text: String, leadingSpace: Bool = true, attachesLeft: Bool = false) {
    self.text = text
    self.leadingSpace = leadingSpace
    self.attachesLeft = attachesLeft
  }
}
