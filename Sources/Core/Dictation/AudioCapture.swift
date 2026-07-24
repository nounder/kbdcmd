import Accelerate
import AVFoundation
import Foundation

// Captures the default input device, converts to 16 kHz mono Float32, and
// accumulates samples.
//
// All engine work happens on a private serial queue: a cold AVAudioEngine
// start can take hundreds of milliseconds, and blocking the main thread stalls
// the CGEvent tap past its watchdog, silently dropping keyboard events.
// A fresh AVAudioEngine is created per engine start: reusing an engine across
// a device change leaves it with stale IO state, and installTap then raises an
// NSException that Swift cannot catch. On a configuration change mid-recording
// the engine is rebuilt and accumulated samples are kept.
final class AudioCapture {
  var onLevel: ((Float) -> Void)?
  var onFailure: ((String) -> Void)?

  private let queue = DispatchQueue(label: "org.libred.kbdcmd.audio", qos: .userInitiated)
  private var engine: AVAudioEngine?
  private var configurationObserver: NSObjectProtocol?
  private var samples: [Float] = []
  private var desired = false
  private var lock = os_unfair_lock_s()

  private static let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

  var isRunning: Bool {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    return desired
  }

  func start() {
    os_unfair_lock_lock(&lock)
    let alreadyRunning = desired
    if !alreadyRunning {
      desired = true
      samples.removeAll(keepingCapacity: true)
    }
    os_unfair_lock_unlock(&lock)
    guard !alreadyRunning else { return }

    queue.async { [weak self] in
      self?.startEngineOnQueue(retriesLeft: 3)
    }
  }

  func stop(_ completion: (([Float]) -> Void)? = nil) {
    os_unfair_lock_lock(&lock)
    desired = false
    os_unfair_lock_unlock(&lock)

    queue.async { [weak self] in
      guard let self else { return }
      self.teardownEngineOnQueue()
      let collected = self.snapshot()
      if let completion {
        DispatchQueue.main.async { completion(collected) }
      }
    }
  }

  func snapshot() -> [Float] {
    os_unfair_lock_lock(&lock)
    let copy = samples
    os_unfair_lock_unlock(&lock)
    return copy
  }

  func resetBuffer() {
    os_unfair_lock_lock(&lock)
    samples.removeAll(keepingCapacity: true)
    os_unfair_lock_unlock(&lock)
  }

  private func startEngineOnQueue(retriesLeft: Int) {
    guard isRunning, engine == nil else { return }
    do {
      try buildEngineOnQueue()
    } catch {
      guard retriesLeft > 0 else {
        os_unfair_lock_lock(&lock)
        desired = false
        os_unfair_lock_unlock(&lock)
        let message =
          (error as? DictationError).map { _ in "microphone unavailable" }
          ?? error.localizedDescription
        DispatchQueue.main.async { [weak self] in
          self?.onFailure?(message)
        }
        return
      }
      queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        self?.startEngineOnQueue(retriesLeft: retriesLeft - 1)
      }
    }
  }

  private func buildEngineOnQueue() throws {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      throw DictationError.invalidAudio("no input device available")
    }
    guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
      throw DictationError.invalidAudio("unsupported input format \(inputFormat)")
    }

    input.installTap(onBus: 0, bufferSize: 1600, format: inputFormat) { [weak self] buffer, _ in
      self?.process(buffer, converter: converter)
    }

    do {
      engine.prepare()
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      throw DictationError.invalidAudio("could not start audio engine: \(error.localizedDescription)")
    }

    self.engine = engine
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
    ) { [weak self] _ in
      self?.handleConfigurationChange()
    }
  }

  private func handleConfigurationChange() {
    queue.async { [weak self] in
      guard let self, self.isRunning else { return }
      self.teardownEngineOnQueue()
      self.startEngineOnQueue(retriesLeft: 3)
    }
  }

  private func teardownEngineOnQueue() {
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
      self.configurationObserver = nil
    }
    if let engine {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    engine = nil
  }

  private func process(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
    let ratio = 16000.0 / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
    guard
      let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity)
    else { return }

    var consumed = false
    var conversionError: NSError?
    converter.convert(to: output, error: &conversionError) { _, outStatus in
      if consumed {
        outStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      outStatus.pointee = .haveData
      return buffer
    }
    guard conversionError == nil, output.frameLength > 0,
      let channelData = output.floatChannelData
    else { return }

    let frameCount = Int(output.frameLength)
    os_unfair_lock_lock(&lock)
    samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameCount))
    os_unfair_lock_unlock(&lock)

    if let onLevel {
      var rms: Float = 0
      vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(frameCount))
      DispatchQueue.main.async {
        onLevel(rms)
      }
    }
  }
}
