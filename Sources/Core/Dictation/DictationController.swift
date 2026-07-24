import AppKit
import Foundation
import os

// Drives FnStateMachine from the CGEvent tap and executes its effects. All
// handle* methods are called from the tap callback on the main run loop and
// must only flip state and dispatch — audio and CoreML work runs on
// ParakeetTranscriber (an actor) or dispatched main-queue blocks.
public final class DictationController {
  public static let shared = DictationController()

  private static let minSpeechSamples = 4_800

  private let log = Logger(subsystem: "org.libred.kbdcmd", category: "dictation")

  private var machine = FnStateMachine()
  private var fnWasDown = false
  private var holdTimer: DispatchWorkItem?
  private var tapTimer: DispatchWorkItem?
  private var maxSessionTimer: DispatchWorkItem?
  private var transcribeTask: Task<Void, Never>?
  private var previewTask: Task<Void, Never>?

  private let capture = AudioCapture()
  private let overlay = DictationOverlayController.shared

  private init() {
    capture.onLevel = { [weak self] level in
      self?.overlay.model.pushLevel(level)
    }
    capture.onFailure = { [weak self] message in
      self?.fail(message)
    }
  }

  public var isEnabled: Bool { DictationSettings.enabled }

  public var isEngaged: Bool { machine.isEngaged }

  // The model stays resident once loaded; load it at launch when already
  // downloaded so the first dictation is instant.
  public func activate() {
    warnAboutGlobeSettingIfNeeded()
    let precision = DictationSettings.encoderPrecision
    if ModelDownloader.modelsPresent(precision: precision) {
      Task {
        try? await ParakeetTranscriber.shared.prepare(precision: precision)
        try? await ParakeetTranscriber.shared.warmUp()
      }
    }
  }

  public func handleFnFlagChange(isDown: Bool) -> Bool {
    guard isEnabled else { return false }
    guard isDown != fnWasDown else { return false }
    fnWasDown = isDown
    if isDown {
      warmModelSoon()
    }
    return dispatch(isDown ? .fnDown : .fnUp)
  }

  public func handleKeyDown(keyCode: Int64) -> Bool {
    dispatch(.keyDown(keyCode: keyCode))
  }

  public func handleOtherModifierChange() {
    _ = dispatch(.otherModifierChanged)
  }

  @discardableResult
  private func dispatch(_ event: FnStateMachine.Event) -> Bool {
    machine.config.holdEnabled = DictationSettings.holdEnabled
    machine.config.doubleTapEnabled = DictationSettings.doubleTapEnabled

    let stateBefore = machine.state
    let output = machine.handle(event, at: ProcessInfo.processInfo.systemUptime)
    if machine.state != stateBefore {
      log.info(
        "\(String(describing: event), privacy: .public) -> \(String(describing: self.machine.state), privacy: .public), effects: \(String(describing: output.effects), privacy: .public)"
      )
    }
    for effect in output.effects {
      perform(effect)
    }
    return output.consumeEvent
  }

  private func perform(_ effect: FnStateMachine.Effect) {
    switch effect {
    case .startCapture:
      startCaptureSoon()
    case .discardCapture:
      if capture.isRunning {
        capture.stop()
      }
    case .showHoldOverlay:
      overlay.show(expanded: false)
    case .showToggleOverlay:
      overlay.show(expanded: true)
    case .hideOverlay:
      overlay.hide()
    case .armHoldTimer(let delay):
      holdTimer = arm(replacing: holdTimer, delay: delay, event: .holdTimerFired)
    case .cancelHoldTimer:
      holdTimer?.cancel()
      holdTimer = nil
    case .armTapTimer(let delay):
      tapTimer = arm(replacing: tapTimer, delay: delay, event: .tapTimerFired)
    case .cancelTapTimer:
      tapTimer?.cancel()
      tapTimer = nil
    case .armMaxSessionTimer(let delay):
      maxSessionTimer = arm(replacing: maxSessionTimer, delay: delay, event: .maxSessionTimerFired)
    case .cancelMaxSessionTimer:
      maxSessionTimer?.cancel()
      maxSessionTimer = nil
    case .beginToggleSession:
      beginToggleSession()
    case .finishHoldSession:
      finishSession(toggle: false)
    case .finishToggleSession:
      finishSession(toggle: true)
    case .cancelToggleSession:
      previewTask?.cancel()
      previewTask = nil
      capture.stop()
      overlay.hide()
    }
  }

  private func arm(
    replacing current: DispatchWorkItem?, delay: TimeInterval, event: FnStateMachine.Event
  ) -> DispatchWorkItem {
    current?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.dispatch(event)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    return work
  }

  private func startCaptureIfPermitted() {
    switch MicPermission.status {
    case .granted:
      DictationFeedbackSound.shared.playStart()
      capture.start()
    case .undetermined:
      MicPermission.request { [weak self] granted in
        if granted {
          self?.startCaptureIfPermitted()
        } else {
          self?.fail("Microphone access denied")
        }
      }
    case .denied:
      MicPermission.openSystemSettings()
      fail("Microphone access denied — enable in System Settings")
    }
  }

  private func startCaptureSoon() {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.machine.isEngaged, !self.capture.isRunning else { return }
      self.startCaptureIfPermitted()
    }
  }

  private func warmModelSoon() {
    let precision = DictationSettings.encoderPrecision
    if ModelDownloader.modelsPresent(precision: precision) {
      Task {
        try? await ParakeetTranscriber.shared.prepare(precision: precision)
      }
    }
  }

  private func beginToggleSession() {
    DispatchQueue.main.async { [weak self] in
      guard let self, case .toggleActive = self.machine.state else { return }
      if self.capture.isRunning {
        self.capture.resetBuffer()
      } else {
        self.startCaptureIfPermitted()
      }
      self.startPreviewLoop()
    }
  }

  private func finishSession(toggle: Bool) {
    previewTask?.cancel()
    previewTask = nil
    overlay.setPhase(.transcribing)
    capture.stop { [weak self] samples in
      DictationFeedbackSound.shared.playStop()
      self?.transcribe(samples, toggle: toggle)
    }
  }

  private func transcribe(_ samples: [Float], toggle: Bool) {
    guard samples.count >= Self.minSpeechSamples else {
      overlay.hide()
      dispatch(.sessionCompleted)
      return
    }
    transcribeTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.ensureModelsReady()
        let text =
          toggle
          ? try await ParakeetTranscriber.shared.finishPreviewSession(samples: samples)
          : try await ParakeetTranscriber.shared.transcribe(samples)
        await MainActor.run {
          if text.isEmpty {
            self.overlay.hide()
          } else {
            TextInserter.insert(text)
            self.overlay.flashSuccessAndHide()
          }
          self.dispatch(.sessionCompleted)
        }
      } catch {
        await MainActor.run {
          self.overlay.showErrorAndHide(self.shortMessage(for: error))
          self.dispatch(.sessionCompleted)
        }
      }
    }
  }

  private func ensureModelsReady() async throws {
    let precision = DictationSettings.encoderPrecision
    if await ParakeetTranscriber.shared.isPrepared {
      return
    }
    if !ModelDownloader.modelsPresent(precision: precision) {
      let overlay = self.overlay
      try await ModelDownloader.shared.download(precision: precision) { fraction, _ in
        let percent = Int(fraction * 100)
        DispatchQueue.main.async {
          overlay.setPhase(.downloading(percent))
        }
      }
      await MainActor.run {
        overlay.setPhase(.transcribing)
      }
    }
    try await ParakeetTranscriber.shared.prepare(precision: precision)
  }

  private func startPreviewLoop() {
    previewTask?.cancel()
    previewTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.ensureModelsReady()
      } catch {
        return
      }
      await ParakeetTranscriber.shared.beginPreviewSession()
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard case .toggleActive = self.machine.state else { return }
        let samples = self.capture.snapshot()
        guard
          let update = try? await ParakeetTranscriber.shared.previewUpdate(samples: samples)
        else { continue }
        await MainActor.run {
          guard case .toggleActive = self.machine.state else { return }
          self.overlay.model.committedText = update.committed
          self.overlay.model.volatileText = update.volatile
        }
      }
    }
  }

  private func fail(_ message: String) {
    holdTimer?.cancel()
    holdTimer = nil
    tapTimer?.cancel()
    tapTimer = nil
    maxSessionTimer?.cancel()
    maxSessionTimer = nil
    previewTask?.cancel()
    previewTask = nil
    if capture.isRunning {
      capture.stop()
    }
    overlay.showErrorAndHide(message)
    machine = FnStateMachine(config: machine.config)
  }

  private func shortMessage(for error: Error) -> String {
    if let dictationError = error as? DictationError {
      switch dictationError {
      case .modelsMissing: return "Model not available — run `kbdcmd dictation download`"
      case .downloadFailed: return "Model download failed"
      case .invalidAudio(let detail): return detail
      case .processingFailed: return "Transcription failed"
      }
    }
    return error.localizedDescription
  }

  private func warnAboutGlobeSettingIfNeeded() {
    let usage = UserDefaults(suiteName: "com.apple.HIToolbox")?
      .object(forKey: "AppleFnUsageType") as? Int
    if let usage, usage != 0 {
      debugLog(
        "dictation: 'Press Globe key to' is set (AppleFnUsageType=\(usage)); "
          + "set it to 'Do Nothing' in System Settings > Keyboard to avoid conflicts")
    }
  }
}
