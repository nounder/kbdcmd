import AVFoundation
import Foundation

/// Short dictation cues synthesized in Swift so the app does not need bundled
/// audio files. The rising cue marks recording start; the falling cue marks
/// recording stop.
final class DictationFeedbackSound {
  static let shared = DictationFeedbackSound()

  private let startPlayer: AVAudioPlayer?
  private let stopPlayer: AVAudioPlayer?

  private init() {
    startPlayer = try? AVAudioPlayer(data: Self.makeWaveFile(direction: .rising))
    stopPlayer = try? AVAudioPlayer(data: Self.makeWaveFile(direction: .falling))
    startPlayer?.volume = 0.35
    stopPlayer?.volume = 0.35
    startPlayer?.prepareToPlay()
    stopPlayer?.prepareToPlay()
  }

  func playStart() {
    play(startPlayer)
  }

  func playStop() {
    play(stopPlayer)
  }

  private func play(_ player: AVAudioPlayer?) {
    guard let player else { return }
    player.currentTime = 0
    player.play()
  }

  private enum Direction {
    case rising
    case falling
  }

  /// Produces a warm, percussive pitch sweep similar in purpose to Handy's
  /// bundled start/stop WAV cues, while keeping our cue entirely procedural.
  private static func makeWaveFile(direction: Direction) -> Data {
    let sampleRate = 44_100
    let duration = 0.22
    let frameCount = Int(Double(sampleRate) * duration)
    let startFrequency = direction == .rising ? 620.0 : 880.0
    let endFrequency = direction == .rising ? 930.0 : 520.0
    var phase = 0.0
    var pcm = Data(capacity: frameCount * 4)

    for frame in 0..<frameCount {
      let progress = Double(frame) / Double(frameCount - 1)
      let easedProgress = progress * progress * (3 - 2 * progress)
      let frequency = startFrequency + (endFrequency - startFrequency) * easedProgress
      phase += 2 * Double.pi * frequency / Double(sampleRate)

      let attack = min(1, progress / 0.018)
      let decay = pow(1 - progress, 2.4)
      let envelope = attack * decay
      let tone =
        sin(phase) + 0.28 * sin(phase * 2 + 0.15) + 0.10 * sin(phase * 3 + 0.4)
      let sample = Int16(clamping: Int(tone * envelope * 15_000))
      pcm.appendLittleEndian(sample)
      pcm.appendLittleEndian(sample)
    }

    var wave = Data(capacity: pcm.count + 44)
    wave.append(contentsOf: "RIFF".utf8)
    wave.appendLittleEndian(UInt32(36 + pcm.count))
    wave.append(contentsOf: "WAVEfmt ".utf8)
    wave.appendLittleEndian(UInt32(16))
    wave.appendLittleEndian(UInt16(1))  // PCM
    wave.appendLittleEndian(UInt16(2))  // stereo
    wave.appendLittleEndian(UInt32(sampleRate))
    wave.appendLittleEndian(UInt32(sampleRate * 4))
    wave.appendLittleEndian(UInt16(4))
    wave.appendLittleEndian(UInt16(16))
    wave.append(contentsOf: "data".utf8)
    wave.appendLittleEndian(UInt32(pcm.count))
    wave.append(pcm)
    return wave
  }
}

private extension Data {
  mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndianValue = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
      append(contentsOf: bytes)
    }
  }
}
