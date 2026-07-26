import Foundation

// Pure FN-key dictation state machine: consumes timestamped events, returns
// effects for the caller to execute. No clocks, timers, or IO — fully
// deterministic and unit-testable.
public struct FnStateMachine {
  public struct Config {
    // Delay before the hold cue and overlay while fn is held. Audio capture
    // itself starts at fn-down, so this only gates feedback: short enough to
    // feel immediate, long enough that taps and fn-combos don't flash/beep.
    public var holdIndicatorDelay: TimeInterval = 0.15
    // A press released before this counts as a tap even if the hold overlay
    // already appeared; only longer presses transcribe on release.
    public var tapMaxDuration: TimeInterval = 0.60
    // Max gap between first-tap release and second press.
    public var doubleTapWindow: TimeInterval = 0.75
    // Minimum toggle-session age before fn ends it (debounces the double-tap).
    public var minToggleDuration: TimeInterval = 0.60
    public var maxSessionDuration: TimeInterval = 300
    public var holdEnabled = true
    public var doubleTapEnabled = true

    public init() {}
  }

  public enum State: Equatable {
    case idle
    case pending(downAt: TimeInterval)
    case awaitingSecondTap(cuePlayed: Bool)
    case holdRecording(downAt: TimeInterval)
    case toggleActive(startedAt: TimeInterval)
    case transcribing
  }

  public enum Event: Equatable {
    case fnDown
    case fnUp
    case holdTimerFired
    case tapTimerFired
    case maxSessionTimerFired
    case keyDown(keyCode: Int64)
    case otherModifierChanged
    case sessionCompleted
  }

  public enum Effect: Equatable {
    case startCapture
    case discardCapture
    case playStartCue
    case showHoldOverlay
    case showToggleOverlay
    case hideOverlay
    case armHoldTimer(TimeInterval)
    case cancelHoldTimer
    case armTapTimer(TimeInterval)
    case cancelTapTimer
    case armMaxSessionTimer(TimeInterval)
    case cancelMaxSessionTimer
    case beginToggleSession
    case finishHoldSession
    case finishToggleSession
    case cancelToggleSession
  }

  public struct Output: Equatable {
    public let effects: [Effect]
    public let consumeEvent: Bool

    static func passThrough(_ effects: [Effect] = []) -> Output {
      Output(effects: effects, consumeEvent: false)
    }

    static func consume(_ effects: [Effect] = []) -> Output {
      Output(effects: effects, consumeEvent: true)
    }
  }

  public var config: Config
  public private(set) var state: State = .idle
  private var ignoreNextFnUp = false

  private static let escapeKeyCode: Int64 = 53

  public init(config: Config = Config()) {
    self.config = config
  }

  public var isEngaged: Bool {
    switch state {
    case .idle, .transcribing: return false
    default: return true
    }
  }

  // A quick fn tap also emits a regular keyDown/keyUp for the Globe key
  // itself (keycode 179; 63 on some keyboards). Those must not count as
  // "fn + other key" combos or they abort the double-tap state.
  private static let globeKeyCodes: Set<Int64> = [179, 63]

  public mutating func handle(_ event: Event, at now: TimeInterval) -> Output {
    if case .keyDown(let keyCode) = event, Self.globeKeyCodes.contains(keyCode) {
      return .passThrough()
    }
    if event == .fnUp && ignoreNextFnUp {
      ignoreNextFnUp = false
      return .consume()
    }

    switch state {
    case .idle:
      return handleIdle(event, at: now)
    case .pending(let downAt):
      return handlePending(event, at: now, downAt: downAt)
    case .awaitingSecondTap(let cuePlayed):
      return handleAwaitingSecondTap(event, at: now, cuePlayed: cuePlayed)
    case .holdRecording(let downAt):
      return handleHoldRecording(event, at: now, downAt: downAt)
    case .toggleActive(let startedAt):
      return handleToggleActive(event, at: now, startedAt: startedAt)
    case .transcribing:
      return handleTranscribing(event)
    }
  }

  // The mic starts listening silently the moment fn goes down so hold
  // dictation never loses the first word. The audible start cue is decoupled
  // from capture and plays exactly once per gesture, when a mode actually
  // engages — at the hold indicator, or at the second tap of a double-tap
  // (unless a slow first press already played it).
  private mutating func handleIdle(_ event: Event, at now: TimeInterval) -> Output {
    guard event == .fnDown, config.holdEnabled || config.doubleTapEnabled else {
      return .passThrough()
    }
    state = .pending(downAt: now)
    return .passThrough([.startCapture, .armHoldTimer(config.holdIndicatorDelay)])
  }

  private mutating func handlePending(
    _ event: Event, at now: TimeInterval, downAt: TimeInterval
  ) -> Output {
    switch event {
    case .holdTimerFired:
      state = .holdRecording(downAt: downAt)
      return .passThrough(config.holdEnabled ? [.playStartCue, .showHoldOverlay] : [])
    case .fnUp:
      return registerTap(cuePlayed: false)
    case .keyDown, .otherModifierChanged:
      state = .idle
      return .passThrough([.cancelHoldTimer, .discardCapture])
    default:
      return .passThrough()
    }
  }

  private mutating func handleAwaitingSecondTap(
    _ event: Event, at now: TimeInterval, cuePlayed: Bool
  ) -> Output {
    switch event {
    case .fnDown:
      guard config.doubleTapEnabled else {
        state = .idle
        return .passThrough([.cancelTapTimer, .discardCapture])
      }
      state = .toggleActive(startedAt: now)
      ignoreNextFnUp = true
      var effects: [Effect] = [.cancelTapTimer]
      if !cuePlayed {
        effects.append(.playStartCue)
      }
      effects.append(contentsOf: [
        .showToggleOverlay,
        .beginToggleSession,
        .armMaxSessionTimer(config.maxSessionDuration),
      ])
      return .consume(effects)
    case .tapTimerFired:
      state = .idle
      return .passThrough([.discardCapture])
    case .keyDown, .otherModifierChanged:
      state = .idle
      return .passThrough([.cancelTapTimer, .discardCapture])
    default:
      return .passThrough()
    }
  }

  private mutating func handleHoldRecording(
    _ event: Event, at now: TimeInterval, downAt: TimeInterval
  ) -> Output {
    switch event {
    case .fnUp:
      if now - downAt < config.tapMaxDuration {
        let output = registerTap(cuePlayed: config.holdEnabled)
        return Output(effects: [.hideOverlay] + output.effects, consumeEvent: output.consumeEvent)
      }
      guard config.holdEnabled else {
        state = .idle
        return .passThrough([.discardCapture, .hideOverlay])
      }
      state = .transcribing
      return .consume([.finishHoldSession])
    case .keyDown, .otherModifierChanged:
      state = .idle
      return .passThrough([.discardCapture, .hideOverlay])
    default:
      return .passThrough()
    }
  }

  private mutating func handleToggleActive(
    _ event: Event, at now: TimeInterval, startedAt: TimeInterval
  ) -> Output {
    switch event {
    case .fnDown:
      guard now - startedAt >= config.minToggleDuration else {
        ignoreNextFnUp = true
        return .consume()
      }
      state = .transcribing
      ignoreNextFnUp = true
      return .consume([.cancelMaxSessionTimer, .finishToggleSession])
    case .keyDown(let keyCode) where keyCode == Self.escapeKeyCode:
      state = .idle
      return .consume([.cancelMaxSessionTimer, .cancelToggleSession])
    case .maxSessionTimerFired:
      state = .transcribing
      return .passThrough([.finishToggleSession])
    default:
      return .passThrough()
    }
  }

  private mutating func handleTranscribing(_ event: Event) -> Output {
    if event == .sessionCompleted {
      state = .idle
    }
    return .passThrough()
  }

  // The mic keeps running through awaitingSecondTap so a toggle session
  // reuses it instead of re-activating the microphone; cuePlayed records
  // whether a slow first press already played the start cue.
  private mutating func registerTap(cuePlayed: Bool) -> Output {
    guard config.doubleTapEnabled else {
      state = .idle
      return .passThrough([.cancelHoldTimer, .discardCapture])
    }
    state = .awaitingSecondTap(cuePlayed: cuePlayed)
    return .passThrough([.cancelHoldTimer, .armTapTimer(config.doubleTapWindow)])
  }
}
