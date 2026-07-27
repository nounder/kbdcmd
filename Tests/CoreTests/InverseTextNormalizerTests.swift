import Testing

@testable import Core

struct InverseTextNormalizerTests {
  private func check(_ input: String, _ expected: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(
      InverseTextNormalizer.normalize(input) == expected,
      "\(input) -> \(InverseTextNormalizer.normalize(input))",
      sourceLocation: sourceLocation)
  }

  @Test func cardinals() {
    check("one hundred twenty three", "123")
    check("three thousand five hundred", "3500")
    check("two million", "2,000,000")
    check("forty two", "42")
    check("one hundred and five", "105")
  }

  @Test func largeCardinalsGetGrouping() {
    check("twenty five thousand", "25,000")
    check("one hundred thousand", "100,000")
  }

  @Test func smallCardinalsStayWords() {
    check("i have two cats", "i have two cats")
    check("give me one", "give me one")
  }

  @Test func ordinals() {
    check("twenty first", "21st")
    check("one hundred third", "103rd")
    check("twenty fifth", "25th")
  }

  // Low bare ordinals read as enumeration in prose, so they stay spelled out.
  @Test func lowBareOrdinalsStayWords() {
    check("second", "second")
    check("the first item", "the first item")
  }

  @Test func years() {
    check("nineteen eighty four", "1984")
    check("twenty twenty five", "2025")
    check("nineteen oh five", "1905")
  }

  @Test func decimals() {
    check("three point one four", "3.14")
    check("zero point five", "0.5")
  }

  @Test func money() {
    check("three dollars fifty", "$3.50")
    check("three dollars and fifty cents", "$3.50")
    check("twenty dollars", "$20")
    check("five euros", "€5")
    check("two point five dollars", "$2.50")
  }

  @Test func time() {
    check("ten thirty a m", "10:30 AM")
    check("nine p m", "9 PM")
    check("eight oh five a m", "8:05 AM")
  }

  @Test func dates() {
    check("march third", "March 3")
    check("december twenty fifth twenty twenty four", "December 25, 2024")
    check("the fourth of july", "July 4")
  }

  @Test func measures() {
    check("two point five kilograms", "2.5 kg")
    check("fifty percent", "50%")
    check("one hundred kilometers", "100 km")
    check("sixteen gigabytes", "16 GB")
  }

  @Test func fractions() {
    check("one half", "1/2")
    check("three quarters", "3/4")
    check("two and one half", "2 1/2")
  }

  @Test func digitRunsStayPositional() {
    check("four one five five five one two three four", "415551234")
  }

  @Test func spokenPunctuation() {
    check("hello comma world", "hello, world")
    check("wait semicolon then go", "wait; then go")
  }

  @Test func lineBreaks() {
    check("first line new line second line", "first line\nsecond line")
  }

  @Test func punctuationNounsAreNotConverted() {
    check("the period was long", "the period was long")
    check("a quote from him", "a quote from him")
  }

  // Normalization must never drop a spoken word, even when a rule declines to
  // fire partway through a run.
  @Test func conjunctionsSurviveFailedNumberRuns() {
    check("between ten and twenty people", "between 10 and 20 people")
    check("ten and twenty", "10 and 20")
    check("one hundred and five", "105")
    check("me and you", "me and you")
  }

  @Test func passthroughLeavesProseAlone() {
    check("this is a normal sentence", "this is a normal sentence")
    check("", "")
  }

  @Test func mixedSentence() {
    check(
      "meet me at ten thirty a m on march third",
      "meet me at 10:30 AM on March 3")
    check(
      "transfer twenty five thousand dollars",
      "transfer $25,000")
  }
}
