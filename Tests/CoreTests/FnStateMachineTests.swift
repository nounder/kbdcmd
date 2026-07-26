import Testing

@testable import Core

struct FnStateMachineTests {
  var machine = FnStateMachine()

  @discardableResult
  private mutating func send(
    _ event: FnStateMachine.Event, at time: Double
  ) -> FnStateMachine.Output {
    machine.handle(event, at: time)
  }

  // Replays fn press/release pairs including the hold timer firing at the
  // right moments, the way the controller would deliver them.
  private mutating func pressFn(downAt: Double, upAt: Double) -> FnStateMachine.Output {
    _ = send(.fnDown, at: downAt)
    let holdFires = downAt + machine.config.holdIndicatorDelay
    if holdFires < upAt, case .pending = machine.state {
      _ = send(.holdTimerFired, at: holdFires)
    }
    return send(.fnUp, at: upAt)
  }

  // Replays the exact live event stream captured from the unified log: a
  // quick fn tap also delivers a keyDown for the Globe key itself (179),
  // which must not abort the double-tap window.
  @Test mutating func quickDoubleTapSurvivesGlobeKeyDown() {
    _ = send(.fnDown, at: 0)
    _ = send(.fnUp, at: 0.14)
    let globe = send(.keyDown(keyCode: 179), at: 0.141)
    #expect(!globe.consumeEvent)
    #expect(globe.effects.isEmpty)
    #expect(machine.state == .awaitingSecondTap(cuePlayed: false))

    _ = send(.fnDown, at: 0.32)
    #expect(machine.state == .toggleActive(startedAt: 0.32))

    _ = send(.fnUp, at: 0.45)
    _ = send(.keyDown(keyCode: 179), at: 0.451)
    #expect(machine.state == .toggleActive(startedAt: 0.32))
  }

  @Test mutating func quickDoubleTapStartsToggle() {
    _ = pressFn(downAt: 0, upAt: 0.15)
    #expect(machine.state == .awaitingSecondTap(cuePlayed: false))

    let output = send(.fnDown, at: 0.4)
    #expect(machine.state == .toggleActive(startedAt: 0.4))
    #expect(output.consumeEvent)
    #expect(output.effects.contains(.showToggleOverlay))
    #expect(output.effects.contains(.beginToggleSession))
    #expect(output.effects.contains(.playStartCue))

    let release = send(.fnUp, at: 0.55)
    #expect(release.consumeEvent)
    #expect(machine.state == .toggleActive(startedAt: 0.4))
  }

  @Test mutating func moderateSpeedDoubleTapStartsToggle() {
    // 400ms presses with a 300ms gap: the hold timer fires mid-press (playing
    // the start cue), so the first tap goes through holdRecording before
    // release classifies it. The running capture is kept and the toggle skips
    // the cue — one mic activation, one sound.
    let first = pressFn(downAt: 0, upAt: 0.4)
    #expect(machine.state == .awaitingSecondTap(cuePlayed: true))
    #expect(first.effects.contains(.hideOverlay))
    #expect(!first.effects.contains(.discardCapture))
    #expect(!first.effects.contains(.finishHoldSession))

    let toggle = send(.fnDown, at: 0.7)
    #expect(machine.state == .toggleActive(startedAt: 0.7))
    #expect(!toggle.effects.contains(.playStartCue))
  }

  // Capture starts silently at fn-down (hold dictation must not lose the
  // first word); the audible cue plays exactly once, when a mode engages.
  @Test mutating func captureStartsAtFnDownButCuePlaysAtToggle() {
    let down = send(.fnDown, at: 0)
    #expect(down.effects.contains(.startCapture))
    #expect(!down.effects.contains(.playStartCue))

    let up = send(.fnUp, at: 0.15)
    #expect(!up.effects.contains(.discardCapture))
    #expect(!up.effects.contains(.playStartCue))

    let toggle = send(.fnDown, at: 0.4)
    #expect(toggle.effects.contains(.playStartCue))
    #expect(toggle.effects.contains(.beginToggleSession))
  }

  @Test mutating func expiredTapWindowStopsAnyRunningCapture() {
    _ = pressFn(downAt: 0, upAt: 0.4)
    #expect(machine.state == .awaitingSecondTap(cuePlayed: true))

    let timeout = send(.tapTimerFired, at: 1.2)
    #expect(timeout.effects.contains(.discardCapture))
    #expect(machine.state == .idle)
  }

  @Test mutating func slowDoubleTapWithinGenerousWindowStartsToggle() {
    _ = pressFn(downAt: 0, upAt: 0.5)
    #expect(machine.state == .awaitingSecondTap(cuePlayed: true))

    _ = send(.fnDown, at: 1.2)
    #expect(machine.state == .toggleActive(startedAt: 1.2))
  }

  @Test mutating func singleTapTimesOutToIdle() {
    let output = pressFn(downAt: 0, upAt: 0.12)
    #expect(!output.consumeEvent)
    #expect(machine.state == .awaitingSecondTap(cuePlayed: false))

    _ = send(.tapTimerFired, at: 0.95)
    #expect(machine.state == .idle)
  }

  @Test mutating func holdDictationTranscribesOnRelease() {
    let down = send(.fnDown, at: 0)
    #expect(down.effects.contains(.startCapture))
    #expect(machine.state == .pending(downAt: 0))

    let hold = send(.holdTimerFired, at: 0.3)
    #expect(hold.effects.contains(.showHoldOverlay))
    #expect(hold.effects.contains(.playStartCue))
    #expect(machine.state == .holdRecording(downAt: 0))

    let release = send(.fnUp, at: 2.5)
    #expect(release.consumeEvent)
    #expect(release.effects == [.finishHoldSession])
    #expect(machine.state == .transcribing)

    _ = send(.sessionCompleted, at: 3.0)
    #expect(machine.state == .idle)
  }

  @Test mutating func toggleEndsOnFnPressAfterDebounce() {
    _ = pressFn(downAt: 0, upAt: 0.15)
    _ = send(.fnDown, at: 0.4)
    #expect(machine.state == .toggleActive(startedAt: 0.4))
    _ = send(.fnUp, at: 0.5)

    // Too early: within the debounce, press is swallowed, session continues.
    let early = send(.fnDown, at: 0.8)
    #expect(early.consumeEvent)
    #expect(machine.state == .toggleActive(startedAt: 0.4))
    _ = send(.fnUp, at: 0.9)

    let stop = send(.fnDown, at: 5.0)
    #expect(stop.consumeEvent)
    #expect(stop.effects.contains(.finishToggleSession))
    #expect(machine.state == .transcribing)

    let trailingUp = send(.fnUp, at: 5.1)
    #expect(trailingUp.consumeEvent)
    #expect(machine.state == .transcribing)

    _ = send(.sessionCompleted, at: 6.0)
    #expect(machine.state == .idle)
  }

  @Test mutating func escapeCancelsToggleSession() {
    _ = pressFn(downAt: 0, upAt: 0.15)
    _ = send(.fnDown, at: 0.4)
    _ = send(.fnUp, at: 0.5)

    let escape = send(.keyDown(keyCode: 53), at: 2.0)
    #expect(escape.consumeEvent)
    #expect(escape.effects.contains(.cancelToggleSession))
    #expect(machine.state == .idle)
  }

  @Test mutating func typingDuringToggleSessionPassesThrough() {
    _ = pressFn(downAt: 0, upAt: 0.15)
    _ = send(.fnDown, at: 0.4)
    _ = send(.fnUp, at: 0.5)

    let typed = send(.keyDown(keyCode: 4), at: 2.0)
    #expect(!typed.consumeEvent)
    #expect(typed.effects.isEmpty)
    #expect(machine.state == .toggleActive(startedAt: 0.4))
  }

  @Test mutating func fnComboAbortsCandidateAndPassesKeyThrough() {
    _ = send(.fnDown, at: 0)
    let arrow = send(.keyDown(keyCode: 126), at: 0.1)
    #expect(!arrow.consumeEvent)
    #expect(arrow.effects.contains(.cancelHoldTimer))
    #expect(machine.state == .idle)

    _ = send(.fnUp, at: 0.2)
    #expect(machine.state == .idle)
  }

  @Test mutating func fnComboAfterHoldTimerAbortsToo() {
    _ = send(.fnDown, at: 0)
    _ = send(.holdTimerFired, at: 0.3)
    let arrow = send(.keyDown(keyCode: 126), at: 0.5)
    #expect(!arrow.consumeEvent)
    #expect(arrow.effects.contains(.hideOverlay))
    #expect(machine.state == .idle)
  }

  @Test mutating func otherModifierDuringPendingAborts() {
    _ = send(.fnDown, at: 0)
    _ = send(.otherModifierChanged, at: 0.1)
    #expect(machine.state == .idle)
  }

  @Test mutating func maxSessionAutoFinalizes() {
    _ = pressFn(downAt: 0, upAt: 0.15)
    _ = send(.fnDown, at: 0.4)
    _ = send(.fnUp, at: 0.5)

    let timeout = send(.maxSessionTimerFired, at: 300.4)
    #expect(timeout.effects.contains(.finishToggleSession))
    #expect(machine.state == .transcribing)
  }

  @Test mutating func doubleTapDisabledTapDoesNothing() {
    machine.config.doubleTapEnabled = false
    _ = send(.fnDown, at: 0)
    let up = send(.fnUp, at: 0.2)
    #expect(up.effects.contains(.discardCapture))
    #expect(machine.state == .idle)
  }

  @Test mutating func holdDisabledStillAllowsDoubleTap() {
    machine.config.holdEnabled = false
    let first = pressFn(downAt: 0, upAt: 0.4)
    #expect(!first.effects.contains(.finishHoldSession))
    #expect(machine.state == .awaitingSecondTap(cuePlayed: false))

    let toggle = send(.fnDown, at: 0.7)
    #expect(machine.state == .toggleActive(startedAt: 0.7))
    #expect(toggle.effects.contains(.playStartCue))
  }

  @Test mutating func holdDisabledLongPressDiscards() {
    machine.config.holdEnabled = false
    _ = send(.fnDown, at: 0)
    _ = send(.holdTimerFired, at: 0.3)
    let release = send(.fnUp, at: 2.0)
    #expect(!release.consumeEvent)
    #expect(release.effects.contains(.discardCapture))
    #expect(machine.state == .idle)
  }

  @Test mutating func fnIgnoredWhileTranscribing() {
    _ = send(.fnDown, at: 0)
    _ = send(.holdTimerFired, at: 0.3)
    _ = send(.fnUp, at: 2.0)
    #expect(machine.state == .transcribing)

    let press = send(.fnDown, at: 2.1)
    #expect(!press.consumeEvent)
    #expect(press.effects.isEmpty)
    #expect(machine.state == .transcribing)
  }

  @Test mutating func tapThenLaterHoldStartsFreshHold() {
    _ = pressFn(downAt: 0, upAt: 0.15)
    #expect(machine.state == .awaitingSecondTap(cuePlayed: false))
    _ = send(.tapTimerFired, at: 0.95)
    #expect(machine.state == .idle)

    _ = send(.fnDown, at: 2.0)
    _ = send(.holdTimerFired, at: 2.3)
    let release = send(.fnUp, at: 4.0)
    #expect(release.effects == [.finishHoldSession])
    #expect(machine.state == .transcribing)
  }
}
