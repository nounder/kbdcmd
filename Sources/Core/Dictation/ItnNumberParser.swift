import Foundation

struct ItnNumber {
  var value: Int
  var isOrdinal: Bool
  var wordCount: Int
  var digitString: String?

  var text: String {
    if let digitString { return digitString }
    if isOrdinal { return ItnNumberParser.ordinalString(value) }
    return String(value)
  }
}

enum ItnNumberParser {
  // Parses the longest cardinal/ordinal run starting at `index`. Returns nil
  // when the word at `index` does not begin a number.
  static func parse(_ words: [ItnToken], at index: Int) -> ItnNumber? {
    guard index < words.count else { return nil }

    if let year = parseYearPair(words, at: index) {
      return year
    }
    if let digits = parseDigitRun(words, at: index) {
      return digits
    }
    return parseCompound(words, at: index)
  }

  // "nineteen eighty four" / "twenty twenty five" — two tens-teens groups that
  // read as a year rather than an arithmetic sum.
  private static func parseYearPair(_ words: [ItnToken], at index: Int) -> ItnNumber? {
    guard index + 1 < words.count else { return nil }
    let first = words[index].normalized
    guard let high = ItnLexicon.teens[first] ?? ItnLexicon.tens[first], high >= 10 else {
      return nil
    }
    guard high % 10 == 0 || ItnLexicon.teens[first] != nil else { return nil }

    if index + 2 < words.count, ItnLexicon.scales[words[index + 1].normalized] != nil {
      return nil
    }

    let secondWord = words[index + 1].normalized
    if secondWord == "hundred" {
      return nil
    }

    // "nineteen oh five" -> 1905
    if secondWord == "oh" || secondWord == "o", index + 2 < words.count,
      let digit = ItnLexicon.units[words[index + 2].normalized], digit > 0
    {
      return ItnNumber(
        value: high * 100 + digit, isOrdinal: false, wordCount: 3,
        digitString: String(high * 100 + digit))
    }

    if let low = ItnLexicon.teens[secondWord] {
      return ItnNumber(
        value: high * 100 + low, isOrdinal: false, wordCount: 2,
        digitString: String(high * 100 + low))
    }
    if let lowTens = ItnLexicon.tens[secondWord] {
      var total = high * 100 + lowTens
      var consumed = 2
      if index + 2 < words.count, let unit = ItnLexicon.units[words[index + 2].normalized],
        unit > 0
      {
        total += unit
        consumed = 3
      }
      return ItnNumber(
        value: total, isOrdinal: false, wordCount: consumed, digitString: String(total))
    }
    return nil
  }

  // Bare digit sequences ("four one five") stay positional so phone numbers and
  // codes keep their leading zeros.
  private static func parseDigitRun(_ words: [ItnToken], at index: Int) -> ItnNumber? {
    var digits: [Int] = []
    var cursor = index
    while cursor < words.count, let digit = ItnLexicon.units[words[cursor].normalized] {
      digits.append(digit)
      cursor += 1
    }
    guard digits.count >= 3 else { return nil }
    let string = digits.map(String.init).joined()
    return ItnNumber(
      value: Int(string) ?? 0, isOrdinal: false, wordCount: digits.count, digitString: string)
  }

  private static func parseCompound(_ words: [ItnToken], at index: Int) -> ItnNumber? {
    var total = 0
    var current = 0
    var cursor = index
    var matched = false
    var isOrdinal = false
    var sawValue = false

    while cursor < words.count {
      let word = words[cursor].normalized

      // "and" only joins a number after a scale ("one hundred and five"); in
      // "ten and twenty" it is ordinary prose and must survive.
      if word == "and", matched, total > 0 || current >= 100, cursor + 1 < words.count,
        startsNumber(words[cursor + 1].normalized)
      {
        cursor += 1
        continue
      }

      if let unit = ItnLexicon.units[word] {
        if sawValue && current % 10 != 0 && current != 0 { break }
        if word == "oh" || word == "o" { break }
        current += unit
        sawValue = true
        matched = true
        cursor += 1
        continue
      }
      if let teen = ItnLexicon.teens[word] {
        if sawValue { break }
        current += teen
        sawValue = true
        matched = true
        cursor += 1
        continue
      }
      if let ten = ItnLexicon.tens[word] {
        if sawValue { break }
        current += ten
        sawValue = true
        matched = true
        cursor += 1
        continue
      }
      if let scale = ItnLexicon.scales[word] {
        if scale == 100 {
          current = max(current, 1) * 100
        } else {
          total += max(current, 1) * scale
          current = 0
        }
        sawValue = false
        matched = true
        cursor += 1
        continue
      }
      if let ordinal = ItnLexicon.ordinalUnits[word] {
        if sawValue && current % 10 != 0 { break }
        current += ordinal
        isOrdinal = true
        matched = true
        cursor += 1
        break
      }
      if let ordinalScale = ItnLexicon.ordinalScales[word] {
        if ordinalScale == 100 {
          current = max(current, 1) * 100
        } else {
          total += max(current, 1) * ordinalScale
          current = 0
        }
        isOrdinal = true
        matched = true
        cursor += 1
        break
      }
      break
    }

    guard matched else { return nil }
    while cursor > index, words[cursor - 1].normalized == "and" {
      cursor -= 1
    }
    let value = total + current
    return ItnNumber(
      value: value, isOrdinal: isOrdinal, wordCount: cursor - index, digitString: nil)
  }

  // Clock hours and minutes are plain cardinals: "ten thirty" must not collapse
  // into the year 1030 before the time rule can read it.
  static func parseClockComponent(_ words: [ItnToken], at index: Int) -> ItnNumber? {
    guard let number = parseCompound(words, at: index), !number.isOrdinal else { return nil }
    return number
  }

  static func startsNumber(_ word: String) -> Bool {
    ItnLexicon.isNumberWord(word) || ItnLexicon.ordinalUnits[word] != nil
      || ItnLexicon.ordinalScales[word] != nil
  }

  static func ordinalString(_ value: Int) -> String {
    let suffix: String
    switch (value % 100, value % 10) {
    case (11, _), (12, _), (13, _): suffix = "th"
    case (_, 1): suffix = "st"
    case (_, 2): suffix = "nd"
    case (_, 3): suffix = "rd"
    default: suffix = "th"
    }
    return "\(value)\(suffix)"
  }

  static func grouped(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = Locale(identifier: "en_US")
    formatter.usesGroupingSeparator = true
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
  }
}
