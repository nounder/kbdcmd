import Foundation

public enum DictationError: Error, LocalizedError {
  case modelsMissing(String)
  case downloadFailed(String)
  case invalidAudio(String)
  case processingFailed(String)

  public var errorDescription: String? {
    switch self {
    case .modelsMissing(let detail): return "Dictation models missing: \(detail)"
    case .downloadFailed(let detail): return "Model download failed: \(detail)"
    case .invalidAudio(let detail): return "Invalid audio: \(detail)"
    case .processingFailed(let detail): return "Transcription failed: \(detail)"
    }
  }
}

enum ParakeetConstants {
  static let sampleRate = 16_000
  // The CoreML encoder is compiled for a fixed 15 s window.
  static let maxModelSamples = 240_000
  static let minimumSamples = 4_800
  static let melHopSize = 160
  static let encoderSubsampling = 8
  static let samplesPerEncoderFrame = melHopSize * encoderSubsampling
  static let encoderHiddenSize = 1024
  static let decoderHiddenSize = 640
  static let decoderLayers = 2
  static let blankId = 8192
  static let durationBins = [0, 1, 2, 3, 4]
  static let maxSymbolsPerStep = 10
  static let maxTokensPerChunk = 150
  static let consecutiveBlankLimit = 5
  static let punctuationTokens: Set<Int> = [7883, 7952, 7948]

  static func encoderFrames(fromSamples samples: Int) -> Int {
    Int(ceil(Double(samples) / Double(samplesPerEncoderFrame)))
  }
}
