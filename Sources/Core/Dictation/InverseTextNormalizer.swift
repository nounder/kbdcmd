import Foundation

/// Converts spoken-form transcription output into written form, following the
/// semiotic classes of NeMo's English inverse text normalization grammars:
/// cardinals, ordinals, decimals, fractions, money, time, dates, measures,
/// telephone numbers, and spoken punctuation.
public enum InverseTextNormalizer {
  public static func normalize(_ text: String) -> String {
    guard !text.isEmpty else { return text }
    let tokens = ItnTokenizer.tokenize(text)
    guard !tokens.isEmpty else { return text }

    var pieces: [ItnPiece] = []
    var index = 0
    while index < tokens.count {
      let consumed = emit(tokens, at: index, into: &pieces)
      index += max(consumed, 1)
    }
    return ItnTokenizer.join(pieces)
  }

  private static func emit(_ tokens: [ItnToken], at index: Int, into pieces: inout [ItnPiece])
    -> Int
  {
    if let consumed = emitBreak(tokens, at: index, into: &pieces) { return consumed }
    if let consumed = emitPunctuation(tokens, at: index, into: &pieces) { return consumed }
    if let consumed = emitTime(tokens, at: index, into: &pieces) { return consumed }
    if let consumed = emitMoney(tokens, at: index, into: &pieces) { return consumed }
    if let consumed = emitDate(tokens, at: index, into: &pieces) { return consumed }
    if let consumed = emitFraction(tokens, at: index, into: &pieces) { return consumed }
    if let consumed = emitNumeric(tokens, at: index, into: &pieces) { return consumed }

    let token = tokens[index]
    pieces.append(ItnPiece(text: token.text, leadingSpace: token.leadingSpace))
    return 1
  }

  private static func emitBreak(_ tokens: [ItnToken], at index: Int, into pieces: inout [ItnPiece])
    -> Int?
  {
    for length in stride(from: min(2, tokens.count - index), through: 1, by: -1) {
      let phrase = tokens[index..<(index + length)].map(\.normalized).joined(separator: " ")
      guard let replacement = ItnLexicon.breaks[phrase] else { continue }
      pieces.append(ItnPiece(text: replacement, attachesLeft: true))
      return length
    }
    return nil
  }

  private static func emitPunctuation(
    _ tokens: [ItnToken], at index: Int, into pieces: inout [ItnPiece]
  ) -> Int? {
    for length in stride(from: min(2, tokens.count - index), through: 1, by: -1) {
      let phrase = tokens[index..<(index + length)].map(\.normalized).joined(separator: " ")
      guard let mark = ItnLexicon.punctuation[phrase] else { continue }
      // Single-word marks are only punctuation when dictated deliberately;
      // "period" and "quote" are ordinary nouns in running speech.
      if length == 1, !isDeliberatePunctuation(phrase) { continue }
      let attaches = !"([{\"'".contains(mark)
      pieces.append(ItnPiece(text: mark, attachesLeft: attaches))
      return length
    }
    return nil
  }

  private static func isDeliberatePunctuation(_ word: String) -> Bool {
    switch word {
    case "comma", "semicolon", "colon", "ellipsis", "asterisk", "ampersand", "underscore",
      "backslash", "hashtag", "apostrophe":
      return true
    default:
      return false
    }
  }

  private static func emitMoney(_ tokens: [ItnToken], at index: Int, into pieces: inout [ItnPiece])
    -> Int?
  {
    guard let amount = ItnNumberParser.parse(tokens, at: index), !amount.isOrdinal else {
      return nil
    }
    var cursor = index + amount.wordCount
    let whole = amount.value
    var fractionDigits: Int?

    if cursor < tokens.count, tokens[cursor].normalized == "point" {
      guard let decimal = parseDecimalTail(tokens, at: cursor + 1) else { return nil }
      guard cursor + 1 + decimal.wordCount < tokens.count,
        let currency = ItnLexicon.currencies[tokens[cursor + 1 + decimal.wordCount].normalized]
      else { return nil }
      let digits = decimal.digits.count == 1 ? decimal.digits + "0" : decimal.digits
      let text = "\(currency.symbol)\(ItnNumberParser.grouped(whole)).\(digits.prefix(2))"
      pieces.append(ItnPiece(text: text, leadingSpace: tokens[index].leadingSpace))
      return cursor + 2 + decimal.wordCount - index
    }

    guard cursor < tokens.count, let currency = ItnLexicon.currencies[tokens[cursor].normalized]
    else { return nil }
    cursor += 1

    if cursor < tokens.count, currency.subunitDigits > 0 {
      var lookahead = cursor
      if tokens[lookahead].normalized == "and" { lookahead += 1 }
      if let sub = ItnNumberParser.parse(tokens, at: lookahead), !sub.isOrdinal,
        sub.value < 100
      {
        let after = lookahead + sub.wordCount
        let named =
          after < tokens.count && ItnLexicon.subunitNames.contains(tokens[after].normalized)
        if named || after >= tokens.count || !ItnNumberParser.startsNumber(tokens[after].normalized)
        {
          fractionDigits = sub.value
          cursor = named ? after + 1 : after
        }
      }
    }

    var text = "\(currency.symbol)\(ItnNumberParser.grouped(whole))"
    if let fractionDigits {
      text += String(format: ".%02d", fractionDigits)
    }
    pieces.append(ItnPiece(text: text, leadingSpace: tokens[index].leadingSpace))
    return cursor - index
  }

  private static func emitTime(_ tokens: [ItnToken], at index: Int, into pieces: inout [ItnPiece])
    -> Int?
  {
    guard let hour = ItnNumberParser.parseClockComponent(tokens, at: index), hour.value >= 1,
      hour.value <= 24
    else { return nil }
    var cursor = index + hour.wordCount
    var minute = 0
    var haveMinute = false

    if cursor < tokens.count {
      let word = tokens[cursor].normalized
      if word == "oh" || word == "o", cursor + 1 < tokens.count,
        let digit = ItnLexicon.units[tokens[cursor + 1].normalized]
      {
        minute = digit
        haveMinute = true
        cursor += 2
      } else if let candidate = ItnNumberParser.parseClockComponent(tokens, at: cursor),
        candidate.value < 60
      {
        let after = cursor + candidate.wordCount
        if after < tokens.count, isMeridiem(tokens, at: after) != nil {
          minute = candidate.value
          haveMinute = true
          cursor = after
        }
      }
    }

    guard cursor < tokens.count, let meridiem = isMeridiem(tokens, at: cursor) else {
      return nil
    }
    cursor += meridiem.wordCount

    let displayHour = hour.value
    let text =
      haveMinute
      ? String(format: "%d:%02d %@", displayHour, minute, meridiem.label)
      : "\(displayHour) \(meridiem.label)"
    pieces.append(ItnPiece(text: text, leadingSpace: tokens[index].leadingSpace))
    return cursor - index
  }

  private struct Meridiem {
    let label: String
    let wordCount: Int
  }

  private static func isMeridiem(_ tokens: [ItnToken], at index: Int) -> Meridiem? {
    guard index < tokens.count else { return nil }
    let word = tokens[index].normalized.replacingOccurrences(of: ".", with: "")
    if word == "am" { return Meridiem(label: "AM", wordCount: 1) }
    if word == "pm" { return Meridiem(label: "PM", wordCount: 1) }
    guard index + 1 < tokens.count else { return nil }
    let next = tokens[index + 1].normalized.replacingOccurrences(of: ".", with: "")
    if word == "a", next == "m" { return Meridiem(label: "AM", wordCount: 2) }
    if word == "p", next == "m" { return Meridiem(label: "PM", wordCount: 2) }
    return nil
  }

  private static func emitDate(_ tokens: [ItnToken], at index: Int, into pieces: inout [ItnPiece])
    -> Int?
  {
    let word = tokens[index].normalized
    if ItnLexicon.months[word] != nil {
      guard index + 1 < tokens.count,
        let day = ItnNumberParser.parse(tokens, at: index + 1),
        day.value >= 1, day.value <= 31
      else { return nil }
      guard day.isOrdinal || day.digitString == nil else { return nil }
      var cursor = index + 1 + day.wordCount
      var text = "\(capitalizedMonth(tokens[index].text)) \(day.value)"

      if cursor < tokens.count, let year = ItnNumberParser.parse(tokens, at: cursor),
        !year.isOrdinal, year.value >= 1000, year.value <= 2999
      {
        text += ", \(year.value)"
        cursor += year.wordCount
      }
      pieces.append(ItnPiece(text: text, leadingSpace: tokens[index].leadingSpace))
      return cursor - index
    }

    // "the third of march" -> "March 3", dropping the article.
    var dayStart = index
    if word == "the", index + 1 < tokens.count {
      dayStart = index + 1
    }
    if let day = ItnNumberParser.parse(tokens, at: dayStart), day.isOrdinal, day.value >= 1,
      day.value <= 31
    {
      let after = dayStart + day.wordCount
      guard after + 1 < tokens.count, tokens[after].normalized == "of",
        ItnLexicon.months[tokens[after + 1].normalized] != nil
      else { return nil }
      var cursor = after + 2
      var text = "\(capitalizedMonth(tokens[after + 1].text)) \(day.value)"
      if cursor < tokens.count, let year = ItnNumberParser.parse(tokens, at: cursor),
        !year.isOrdinal, year.value >= 1000, year.value <= 2999
      {
        text += ", \(year.value)"
        cursor += year.wordCount
      }
      pieces.append(ItnPiece(text: text, leadingSpace: tokens[index].leadingSpace))
      return cursor - index
    }
    return nil
  }

  private static func capitalizedMonth(_ raw: String) -> String {
    let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: ",."))
    return cleaned.prefix(1).uppercased() + cleaned.dropFirst().lowercased()
  }

  private static func emitFraction(
    _ tokens: [ItnToken], at index: Int, into pieces: inout [ItnPiece]
  ) -> Int? {
    guard let numerator = ItnNumberParser.parse(tokens, at: index), !numerator.isOrdinal,
      numerator.digitString == nil
    else { return nil }
    var cursor = index + numerator.wordCount
    guard cursor < tokens.count else { return nil }

    if tokens[cursor].normalized == "and", cursor + 1 < tokens.count,
      let inner = ItnNumberParser.parse(tokens, at: cursor + 1), !inner.isOrdinal,
      cursor + 1 + inner.wordCount < tokens.count,
      let denominator = ItnLexicon.fractionDenominators[
        tokens[cursor + 1 + inner.wordCount].normalized],
      denominator > 1
    {
      let end = cursor + 2 + inner.wordCount
      let text = "\(numerator.value) \(inner.value)/\(denominator)"
      pieces.append(ItnPiece(text: text, leadingSpace: tokens[index].leadingSpace))
      return end - index
    }

    guard let denominator = ItnLexicon.fractionDenominators[tokens[cursor].normalized],
      denominator > 1
    else { return nil }
    // "a third of the users" is a quantity, not a fraction literal.
    if numerator.value > denominator { return nil }
    cursor += 1
    let text = "\(numerator.value)/\(denominator)"
    pieces.append(ItnPiece(text: text, leadingSpace: tokens[index].leadingSpace))
    return cursor - index
  }

  private struct DecimalTail {
    let digits: String
    let wordCount: Int
  }

  private static func parseDecimalTail(_ tokens: [ItnToken], at index: Int) -> DecimalTail? {
    var digits = ""
    var cursor = index
    while cursor < tokens.count, let digit = ItnLexicon.units[tokens[cursor].normalized] {
      digits.append(String(digit))
      cursor += 1
    }
    if digits.isEmpty, cursor < tokens.count,
      let number = ItnNumberParser.parse(tokens, at: cursor), !number.isOrdinal
    {
      return DecimalTail(digits: String(number.value), wordCount: number.wordCount)
    }
    guard !digits.isEmpty else { return nil }
    return DecimalTail(digits: digits, wordCount: cursor - index)
  }

  private static func emitNumeric(
    _ tokens: [ItnToken], at index: Int, into pieces: inout [ItnPiece]
  ) -> Int? {
    guard let number = ItnNumberParser.parse(tokens, at: index) else { return nil }
    // A lone small cardinal reads better as a word in prose.
    if shouldKeepAsWord(number, tokens: tokens, at: index) { return nil }

    var cursor = index + number.wordCount
    var text = number.text

    if !number.isOrdinal, number.digitString == nil, cursor < tokens.count,
      tokens[cursor].normalized == "point", let decimal = parseDecimalTail(tokens, at: cursor + 1)
    {
      text = "\(number.value).\(decimal.digits)"
      cursor += 1 + decimal.wordCount
    } else if number.digitString == nil, !number.isOrdinal, number.value >= 10_000 {
      text = ItnNumberParser.grouped(number.value)
    }

    if cursor < tokens.count, let measure = ItnLexicon.measures[tokens[cursor].normalized] {
      text += measure.spaced ? " \(measure.symbol)" : measure.symbol
      cursor += 1
    }

    pieces.append(ItnPiece(text: text, leadingSpace: tokens[index].leadingSpace))
    return cursor - index
  }

  private static func shouldKeepAsWord(_ number: ItnNumber, tokens: [ItnToken], at index: Int)
    -> Bool
  {
    // A single-word ordinal below tenth is usually enumeration in prose
    // ("first line"), not a written-form ordinal.
    if number.isOrdinal, number.wordCount == 1, number.value <= 10 {
      return true
    }
    guard number.digitString == nil, !number.isOrdinal, number.value < 10, number.wordCount == 1
    else { return false }
    let next = index + number.wordCount
    if next < tokens.count {
      if ItnLexicon.measures[tokens[next].normalized] != nil { return false }
      if tokens[next].normalized == "point" { return false }
      if ItnLexicon.currencies[tokens[next].normalized] != nil { return false }
      if ItnLexicon.fractionDenominators[tokens[next].normalized] != nil { return false }
    }
    return true
  }
}
