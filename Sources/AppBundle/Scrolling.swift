import ApplicationServices
import Cocoa

/// Manages smooth scrolling functionality using CGEvent scroll wheel simulation
class Scrolling {
  static let shared = Scrolling()

  private init() {}

  /// Scrolls by the specified number of units
  /// - Parameters:
  ///   - amount: Positive values scroll up, negative values scroll down
  ///   - units: Scroll unit type (line or pixel), defaults to .line
  func scroll(_ amount: Int, units: CGScrollEventUnit = .line) {
    guard
      let event = CGEvent(
        scrollWheelEvent2Source: nil,
        units: units,
        wheelCount: 1,
        wheel1: Int32(amount),
        wheel2: 0,
        wheel3: 0
      )
    else {
      return
    }

    event.post(tap: .cghidEventTap)
  }

  /// Scrolls down by the specified number of units
  /// - Parameter units: Number of units to scroll (positive value)
  func scrollDown(_ units: Int = 10) {
    scroll(-abs(units))
  }

  /// Scrolls up by the specified number of units
  /// - Parameter units: Number of units to scroll (positive value)
  func scrollUp(_ units: Int = 10) {
    scroll(abs(units))
  }

  /// Performs smooth continuous scrolling with animation
  /// - Parameters:
  ///   - amount: Total pixels to scroll. Positive scrolls up, negative scrolls down
  ///   - steps: Number of scroll steps to perform
  func smoothScroll(_ amount: Int, steps: Int = 5) {
    let amountPerStep = amount / steps

    DispatchQueue.global(qos: .userInteractive).async {
      for _ in 1...steps {
        guard
          let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(amountPerStep),
            wheel2: 0,
            wheel3: 0
          )
        else {
          continue
        }

        event.post(tap: .cghidEventTap)

        // Small delay between steps for smoothness
        usleep(16_000)  // ~60fps
      }
    }
  }
}
