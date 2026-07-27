import Accelerate
@preconcurrency import CoreML
import Foundation

public actor ParakeetTranscriber {
  public static let shared = ParakeetTranscriber()

  private var models: ParakeetModels?
  private let decoder = TdtDecoder()
  private var hotwordBias: TdtHotwordBias?

  public func prepare(precision: ParakeetEncoderPrecision = .int8) throws {
    guard models == nil else { return }
    let directory = ModelDownloader.modelsDirectory()
    guard ModelDownloader.modelsPresent(precision: precision) else {
      DictationModelStatus.shared.set(.notDownloaded)
      throw DictationError.modelsMissing(
        "run `kbdcmd dictation download` first (expected in \(directory.path))")
    }
    DictationModelStatus.shared.set(.loading)
    do {
      models = try ParakeetModels.load(from: directory, precision: precision)
      do {
        try setHotwords(DictationSettings.hotwords, boost: DictationSettings.hotwordBoost)
      } catch {
        // Invalid saved phrases must not prevent the speech model from loading.
        hotwordBias = nil
      }
      DictationModelStatus.shared.set(.loaded)
    } catch {
      DictationModelStatus.shared.set(.notLoaded)
      throw error
    }
  }

  public var isPrepared: Bool { models != nil }

  /// Configures decoder-time contextual biasing for names, acronyms, and
  /// domain-specific phrases. `boost` is added to matching token logits; 4 is
  /// a useful starting point, while larger values increase false positives.
  /// Call this after `prepare`. Passing an empty array disables biasing.
  public func setHotwords(_ phrases: [String], boost: Float = 4) throws {
    guard boost.isFinite, boost > 0 else {
      throw DictationError.processingFailed("Hotword boost must be a positive finite number")
    }
    guard let tokenizer = models?.tokenizer else {
      throw DictationError.modelsMissing("prepare the transcriber before setting hotwords")
    }

    if phrases.isEmpty {
      hotwordBias = nil
      return
    }

    var sequences: [[Int]] = []
    for phrase in phrases {
      guard let tokens = tokenizer.encodePhrase(phrase) else {
        throw DictationError.processingFailed(
          "Hotword cannot be represented by the Parakeet vocabulary: \(phrase)")
      }
      if !sequences.contains(tokens) {
        sequences.append(tokens)
      }
    }
    hotwordBias = TdtHotwordBias(tokenSequences: sequences, boost: boost)
  }

  public func clearHotwords() {
    hotwordBias = nil
  }

  public func warmUp() async throws {
    let silence = [Float](repeating: 0, count: ParakeetConstants.sampleRate)
    _ = try? await transcribe(silence)
  }

  public func transcribe(_ samples: [Float]) async throws -> String {
    guard let models else {
      throw DictationError.modelsMissing("transcriber not prepared")
    }
    guard samples.count >= ParakeetConstants.minimumSamples else {
      return ""
    }

    // Each chunk is cut at a silence boundary and decoded as an independent
    // utterance: carrying LSTM state across a hard cut (without the reference
    // library's 2s overlap + dedup) corrupts text at the seam.
    var pieces: [String] = []
    var start = 0

    while start < samples.count {
      try Task.checkCancellation()
      let remaining = samples.count - start
      let isLast = remaining <= ParakeetConstants.maxModelSamples
      let end = isLast ? samples.count : start + silenceAlignedCut(samples, chunkStart: start)
      var state = try TdtDecoderState()
      let hypothesis = try decodeChunk(
        Array(samples[start..<end]), models: models, state: &state, isLastChunk: true)
      let text = models.tokenizer.decode(hypothesis.ySequence)
      if !text.isEmpty {
        pieces.append(text)
      }
      start = end
    }

    return Self.normalized(pieces.joined(separator: " "))
  }

  static func normalized(_ text: String) -> String {
    guard DictationSettings.inverseTextNormalization else { return text }
    return InverseTextNormalizer.normalize(text)
  }

  public struct PreviewUpdate: Sendable {
    public let committed: String
    public let volatile: String
  }

  private var previewPieces: [String] = []
  private var previewBoundary = 0

  public func beginPreviewSession() {
    previewPieces = []
    previewBoundary = 0
  }

  // Live-preview pass for toggle mode: decode the uncommitted tail with fresh
  // state; once the tail outgrows ~12 s, commit it at a silence boundary so
  // each preview pass stays bounded.
  public func previewUpdate(samples: [Float]) async throws -> PreviewUpdate {
    guard let models else {
      throw DictationError.modelsMissing("transcriber not prepared")
    }

    let commitThreshold = 12 * ParakeetConstants.sampleRate
    while samples.count - previewBoundary > commitThreshold {
      try Task.checkCancellation()
      let cut = previewBoundary + silenceAlignedCut(samples, chunkStart: previewBoundary)
      var state = try TdtDecoderState()
      let hypothesis = try decodeChunk(
        Array(samples[previewBoundary..<cut]), models: models, state: &state, isLastChunk: true)
      let text = models.tokenizer.decode(hypothesis.ySequence)
      if !text.isEmpty {
        previewPieces.append(text)
      }
      previewBoundary = cut
    }

    var volatileText = ""
    let tail = Array(samples[previewBoundary...])
    if tail.count >= ParakeetConstants.minimumSamples {
      var state = try TdtDecoderState()
      let hypothesis = try decodeChunk(tail, models: models, state: &state, isLastChunk: true)
      volatileText = models.tokenizer.decode(hypothesis.ySequence)
    }

    return PreviewUpdate(
      committed: previewPieces.joined(separator: " "), volatile: volatileText)
  }

  // Final text for a toggle session: committed pieces plus a last decode of
  // the remaining tail, so the paste matches what the preview showed.
  public func finishPreviewSession(samples: [Float]) async throws -> String {
    guard models != nil else {
      throw DictationError.modelsMissing("transcriber not prepared")
    }
    let tail = Array(samples[min(previewBoundary, samples.count)...])
    var pieces = previewPieces.map { Self.normalized($0) }
    previewPieces = []
    previewBoundary = 0
    if tail.count >= ParakeetConstants.minimumSamples {
      let text = try await transcribe(tail)
      if !text.isEmpty {
        pieces.append(text)
      }
    }
    return pieces.joined(separator: " ")
  }

  private func decodeChunk(
    _ chunk: [Float], models: ParakeetModels, state: inout TdtDecoderState, isLastChunk: Bool
  ) throws -> TdtHypothesis {
    let frameAligned = frameAlignedLength(chunk.count)
    let padded = pad(chunk, to: ParakeetConstants.maxModelSamples)

    let audioArray = try MLMultiArray(
      shape: [1, NSNumber(value: padded.count)], dataType: .float32)
    padded.withUnsafeBufferPointer { buffer in
      let dest = audioArray.dataPointer.bindMemory(to: Float.self, capacity: padded.count)
      memcpy(dest, buffer.baseAddress!, padded.count * MemoryLayout<Float>.stride)
    }
    let lengthArray = try MLMultiArray(shape: [1], dataType: .int32)
    lengthArray[0] = NSNumber(value: frameAligned)

    let preprocessorInput = try MLDictionaryFeatureProvider(dictionary: [
      "audio_signal": MLFeatureValue(multiArray: audioArray),
      "audio_length": MLFeatureValue(multiArray: lengthArray),
    ])
    let preprocessorOutput = try models.preprocessor.prediction(from: preprocessorInput)

    let encoderInput = try prepareEncoderInput(
      encoder: models.encoder, preprocessorOutput: preprocessorOutput,
      originalInput: preprocessorInput)
    let encoderOutput = try models.encoder.prediction(from: encoderInput)

    guard let encoderArray = encoderOutput.featureValue(for: "encoder")?.multiArrayValue,
      let encoderLength = encoderOutput.featureValue(for: "encoder_length")?.multiArrayValue
    else {
      throw DictationError.processingFailed("Missing encoder output")
    }

    return try decoder.decode(
      encoderOutput: encoderArray,
      encoderSequenceLength: encoderLength[0].intValue,
      actualAudioFrames: ParakeetConstants.encoderFrames(fromSamples: chunk.count),
      decoderModel: models.decoder,
      jointModel: models.joint,
      decoderState: &state,
      isLastChunk: isLastChunk,
      hotwordBias: hotwordBias
    )
  }

  private func prepareEncoderInput(
    encoder: MLModel, preprocessorOutput: MLFeatureProvider, originalInput: MLFeatureProvider
  ) throws -> MLFeatureProvider {
    let inputNames = encoder.modelDescription.inputDescriptionsByName.keys
    let missing = inputNames.filter { preprocessorOutput.featureValue(for: $0) == nil }
    if missing.isEmpty {
      return preprocessorOutput
    }

    var features: [String: MLFeatureValue] = [:]
    for name in inputNames {
      if let value = preprocessorOutput.featureValue(for: name) ?? originalInput.featureValue(for: name) {
        features[name] = value
      } else {
        let available = preprocessorOutput.featureNames.sorted().joined(separator: ", ")
        throw DictationError.processingFailed(
          "Missing encoder input \(name); preprocessor provides: \(available)")
      }
    }
    return try MLDictionaryFeatureProvider(dictionary: features)
  }

  // Cut long audio at the quietest 200 ms within the last 2 s of the window so
  // chunk boundaries fall in pauses rather than mid-word.
  private func silenceAlignedCut(_ samples: [Float], chunkStart: Int) -> Int {
    let windowEnd = min(chunkStart + ParakeetConstants.maxModelSamples, samples.count)
    let searchSpan = 2 * ParakeetConstants.sampleRate
    let searchStart = max(windowEnd - searchSpan, chunkStart)
    let hop = ParakeetConstants.sampleRate / 50
    let quietSpan = ParakeetConstants.sampleRate / 5

    var bestOffset = windowEnd - chunkStart
    var bestEnergy = Float.greatestFiniteMagnitude
    var position = searchStart
    while position + quietSpan <= windowEnd {
      var energy: Float = 0
      samples.withUnsafeBufferPointer { buffer in
        vDSP_rmsqv(buffer.baseAddress! + position, 1, &energy, vDSP_Length(quietSpan))
      }
      if energy < bestEnergy {
        bestEnergy = energy
        bestOffset = position + quietSpan / 2 - chunkStart
      }
      position += hop
    }

    let aligned = bestOffset / ParakeetConstants.samplesPerEncoderFrame * ParakeetConstants.samplesPerEncoderFrame
    return max(aligned, ParakeetConstants.samplesPerEncoderFrame)
  }

  private func frameAlignedLength(_ length: Int) -> Int {
    let frame = ParakeetConstants.samplesPerEncoderFrame
    let aligned = (length + frame - 1) / frame * frame
    return min(aligned, ParakeetConstants.maxModelSamples)
  }

  private func pad(_ samples: [Float], to targetLength: Int) -> [Float] {
    guard samples.count < targetLength else { return samples }
    return samples + [Float](repeating: 0, count: targetLength - samples.count)
  }
}
