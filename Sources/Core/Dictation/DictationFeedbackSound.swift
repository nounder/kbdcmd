import AVFoundation
import Foundation

/// Short dictation cues synthesized directly into PCM buffers. The rising cue
/// marks recording start; the falling cue marks recording stop.
final class DictationFeedbackSound {
  static let shared = DictationFeedbackSound()

  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let startBuffer: AVAudioPCMBuffer
  private let stopBuffer: AVAudioPCMBuffer

  private init() {
    let format = AVAudioFormat(
      standardFormatWithSampleRate: Self.sampleRate,
      channels: Self.channelCount
    )!
    startBuffer = Self.makeBuffer(direction: .rising, format: format)
    stopBuffer = Self.makeBuffer(direction: .falling, format: format)

    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    player.volume = 0.35
    engine.prepare()
    try? engine.start()
  }

  func playStart(completion: (() -> Void)? = nil) {
    play(startBuffer, completion: completion)
  }

  func playStop() {
    play(stopBuffer)
  }

  private func play(_ buffer: AVAudioPCMBuffer, completion: (() -> Void)? = nil) {
    if !engine.isRunning {
      try? engine.start()
    }
    guard engine.isRunning else {
      completion?()
      return
    }

    player.stop()
    player.scheduleBuffer(
      buffer,
      at: nil,
      options: .interrupts,
      completionCallbackType: .dataPlayedBack
    ) { _ in
      guard let completion else { return }
      DispatchQueue.main.async(execute: completion)
    }
    player.play()
  }

  private enum Direction {
    case rising
    case falling
  }

  private static let sampleRate = 44_100.0
  private static let channelCount: AVAudioChannelCount = 2
  private static let duration = 0.22

  /// Fills a native floating-point audio buffer with a warm, percussive pitch
  /// sweep, ready for AVAudioPlayerNode without a file container or decoder.
  private static func makeBuffer(
    direction: Direction,
    format: AVAudioFormat
  ) -> AVAudioPCMBuffer {
    let frameCount = AVAudioFrameCount(sampleRate * duration)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount

    let startFrequency = direction == .rising ? 620.0 : 880.0
    let endFrequency = direction == .rising ? 930.0 : 520.0
    var phase = 0.0

    for frame in 0..<Int(frameCount) {
      let progress = Double(frame) / Double(frameCount - 1)
      let easedProgress = progress * progress * (3 - 2 * progress)
      let frequency = startFrequency + (endFrequency - startFrequency) * easedProgress
      phase += 2 * Double.pi * frequency / sampleRate

      let attack = min(1, progress / 0.018)
      let decay = pow(1 - progress, 2.4)
      let envelope = attack * decay
      let tone =
        sin(phase) + 0.28 * sin(phase * 2 + 0.15) + 0.10 * sin(phase * 3 + 0.4)
      let sample = Float(tone * envelope)

      for channel in 0..<Int(channelCount) {
        buffer.floatChannelData![channel][frame] = sample
      }
    }

    return buffer
  }
}
