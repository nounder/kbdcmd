import Foundation

enum ItnLexicon {
  static let units: [String: Int] = [
    "zero": 0, "oh": 0, "o": 0, "nought": 0, "naught": 0,
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9,
  ]

  static let teens: [String: Int] = [
    "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
    "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
  ]

  static let tens: [String: Int] = [
    "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50,
    "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
  ]

  static let scales: [String: Int] = [
    "hundred": 100, "thousand": 1_000, "million": 1_000_000,
    "billion": 1_000_000_000, "trillion": 1_000_000_000_000,
  ]

  static let ordinalUnits: [String: Int] = [
    "zeroth": 0, "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
    "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
    "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
    "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
    "nineteenth": 19, "twentieth": 20, "thirtieth": 30, "fortieth": 40,
    "fiftieth": 50, "sixtieth": 60, "seventieth": 70, "eightieth": 80,
    "ninetieth": 90,
  ]

  static let ordinalScales: [String: Int] = [
    "hundredth": 100, "thousandth": 1_000, "millionth": 1_000_000,
    "billionth": 1_000_000_000,
  ]

  static let months: [String: Int] = [
    "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6,
    "july": 7, "august": 8, "september": 9, "october": 10, "november": 11,
    "december": 12,
  ]

  struct Currency {
    let symbol: String
    let subunit: String
    let subunitDigits: Int
    let symbolLeads: Bool
  }

  static let currencies: [String: Currency] = [
    "dollar": Currency(symbol: "$", subunit: "cent", subunitDigits: 2, symbolLeads: true),
    "dollars": Currency(symbol: "$", subunit: "cent", subunitDigits: 2, symbolLeads: true),
    "euro": Currency(symbol: "€", subunit: "cent", subunitDigits: 2, symbolLeads: true),
    "euros": Currency(symbol: "€", subunit: "cent", subunitDigits: 2, symbolLeads: true),
    "pound": Currency(symbol: "£", subunit: "penny", subunitDigits: 2, symbolLeads: true),
    "pounds": Currency(symbol: "£", subunit: "penny", subunitDigits: 2, symbolLeads: true),
    "yen": Currency(symbol: "¥", subunit: "", subunitDigits: 0, symbolLeads: true),
  ]

  static let subunitNames: Set<String> = ["cent", "cents", "penny", "pence", "p"]

  struct Measure {
    let symbol: String
    let spaced: Bool
  }

  static let measures: [String: Measure] = [
    "percent": Measure(symbol: "%", spaced: false),
    "percents": Measure(symbol: "%", spaced: false),
    "degree": Measure(symbol: "°", spaced: false),
    "degrees": Measure(symbol: "°", spaced: false),
    "kilogram": Measure(symbol: "kg", spaced: true),
    "kilograms": Measure(symbol: "kg", spaced: true),
    "kilo": Measure(symbol: "kg", spaced: true),
    "kilos": Measure(symbol: "kg", spaced: true),
    "gram": Measure(symbol: "g", spaced: true),
    "grams": Measure(symbol: "g", spaced: true),
    "milligram": Measure(symbol: "mg", spaced: true),
    "milligrams": Measure(symbol: "mg", spaced: true),
    "pound weight": Measure(symbol: "lb", spaced: true),
    "kilometer": Measure(symbol: "km", spaced: true),
    "kilometers": Measure(symbol: "km", spaced: true),
    "kilometre": Measure(symbol: "km", spaced: true),
    "kilometres": Measure(symbol: "km", spaced: true),
    "meter": Measure(symbol: "m", spaced: true),
    "meters": Measure(symbol: "m", spaced: true),
    "metre": Measure(symbol: "m", spaced: true),
    "metres": Measure(symbol: "m", spaced: true),
    "centimeter": Measure(symbol: "cm", spaced: true),
    "centimeters": Measure(symbol: "cm", spaced: true),
    "millimeter": Measure(symbol: "mm", spaced: true),
    "millimeters": Measure(symbol: "mm", spaced: true),
    "gigabyte": Measure(symbol: "GB", spaced: true),
    "gigabytes": Measure(symbol: "GB", spaced: true),
    "megabyte": Measure(symbol: "MB", spaced: true),
    "megabytes": Measure(symbol: "MB", spaced: true),
    "kilobyte": Measure(symbol: "KB", spaced: true),
    "kilobytes": Measure(symbol: "KB", spaced: true),
    "terabyte": Measure(symbol: "TB", spaced: true),
    "terabytes": Measure(symbol: "TB", spaced: true),
    "megahertz": Measure(symbol: "MHz", spaced: true),
    "gigahertz": Measure(symbol: "GHz", spaced: true),
  ]

  static let fractionDenominators: [String: Int] = [
    "half": 2, "halves": 2, "third": 3, "thirds": 3, "quarter": 4, "quarters": 4,
    "fourth": 4, "fourths": 4, "fifth": 5, "fifths": 5, "sixth": 6, "sixths": 6,
    "seventh": 7, "sevenths": 7, "eighth": 8, "eighths": 8, "ninth": 9,
    "ninths": 9, "tenth": 10, "tenths": 10, "sixteenth": 16, "sixteenths": 16,
  ]

  static let punctuation: [String: String] = [
    "comma": ",",
    "period": ".",
    "full stop": ".",
    "question mark": "?",
    "exclamation mark": "!",
    "exclamation point": "!",
    "semicolon": ";",
    "colon": ":",
    "ellipsis": "…",
    "hyphen": "-",
    "dash": "—",
    "underscore": "_",
    "asterisk": "*",
    "ampersand": "&",
    "at sign": "@",
    "hashtag": "#",
    "hash sign": "#",
    "percent sign": "%",
    "dollar sign": "$",
    "plus sign": "+",
    "equals sign": "=",
    "slash": "/",
    "forward slash": "/",
    "backslash": "\\",
    "open paren": "(",
    "open parenthesis": "(",
    "close paren": ")",
    "close parenthesis": ")",
    "open bracket": "[",
    "close bracket": "]",
    "open brace": "{",
    "close brace": "}",
    "quote": "\"",
    "double quote": "\"",
    "single quote": "'",
    "apostrophe": "'",
  ]

  static let breaks: [String: String] = [
    "new line": "\n",
    "newline": "\n",
    "new paragraph": "\n\n",
    "tab key": "\t",
  ]

  static func isNumberWord(_ word: String) -> Bool {
    units[word] != nil || teens[word] != nil || tens[word] != nil || scales[word] != nil
  }
}
