@preconcurrency import CoreML
import Foundation

struct TdtHotwordBias: Sendable {
  let tokenSequences: [[Int]]
  let boost: Float

  func selectToken(
    defaultToken: Int,
    history: [Int],
    candidateIDs: MLMultiArray?,
    candidateLogits: MLMultiArray?
  ) -> Int {
    guard boost > 0,
      !tokenSequences.isEmpty,
      let candidateIDs,
      let candidateLogits,
      candidateIDs.count == candidateLogits.count
    else { return defaultToken }

    var selectedToken = defaultToken
    var selectedScore = -Float.greatestFiniteMagnitude

    for index in 0..<candidateIDs.count {
      let token = candidateIDs[index].intValue
      var score = candidateLogits[index].floatValue
      if token != ParakeetConstants.blankId && advancesHotword(history: history, token: token) {
        score += boost
      }
      if score > selectedScore {
        selectedScore = score
        selectedToken = token
      }
    }
    return selectedToken
  }

  // A candidate receives a bonus when appending it makes the output suffix a
  // non-empty prefix of any configured phrase. Full phrases count too.
  private func advancesHotword(history: [Int], token: Int) -> Bool {
    for phrase in tokenSequences {
      let maximumPrefix = min(phrase.count, history.count + 1)
      guard maximumPrefix > 0 else { continue }
      for prefixLength in stride(from: maximumPrefix, through: 1, by: -1) {
        guard phrase[prefixLength - 1] == token else { continue }
        let historyLength = prefixLength - 1
        if historyLength == 0
          || history.suffix(historyLength).elementsEqual(phrase.prefix(historyLength))
        {
          return true
        }
      }
    }
    return false
  }
}

struct TdtHypothesis {
  var ySequence: [Int] = []
  var decState: TdtDecoderState?
  var lastToken: Int?

  init(decState: TdtDecoderState) {
    self.decState = decState
  }
}

private final class JointInputProvider: NSObject, MLFeatureProvider {
  let encoderStep: MLMultiArray
  let decoderStep: MLMultiArray

  init(encoderStep: MLMultiArray, decoderStep: MLMultiArray) {
    self.encoderStep = encoderStep
    self.decoderStep = decoderStep
    super.init()
  }

  var featureNames: Set<String> { ["encoder_step", "decoder_step"] }

  func featureValue(for featureName: String) -> MLFeatureValue? {
    switch featureName {
    case "encoder_step": return MLFeatureValue(multiArray: encoderStep)
    case "decoder_step": return MLFeatureValue(multiArray: decoderStep)
    default: return nil
    }
  }
}

// Greedy Token-and-Duration Transducer decoding for Parakeet TDT v3.
// The joint network predicts a token plus how many 80 ms encoder frames to
// skip; blank tokens intentionally reuse the cached decoder projection since
// silence must not advance the language-model context.
struct TdtDecoder {

  func decode(
    encoderOutput: MLMultiArray,
    encoderSequenceLength: Int,
    actualAudioFrames: Int,
    decoderModel: MLModel,
    jointModel: MLModel,
    decoderState: inout TdtDecoderState,
    isLastChunk: Bool,
    hotwordBias: TdtHotwordBias? = nil
  ) throws -> TdtHypothesis {
    guard encoderSequenceLength > 1 else {
      return TdtHypothesis(decState: decoderState)
    }

    let encoderFrames = try EncoderFrameView(
      encoderOutput: encoderOutput,
      validLength: encoderSequenceLength,
      expectedHiddenSize: ParakeetConstants.encoderHiddenSize
    )

    var hypothesis = TdtHypothesis(decState: decoderState)
    hypothesis.lastToken = decoderState.lastToken

    // Chunks are cut back-to-back (no overlap), so a chunk always starts at the
    // frame the previous chunk's decoder overshot to (timeJump), or at zero.
    var timeIndices = max(0, decoderState.timeJump ?? 0)

    let effectiveSequenceLength = min(encoderSequenceLength, actualAudioFrames)
    let lastTimestep = effectiveSequenceLength - 1
    var safeTimeIndices = min(timeIndices, lastTimestep)
    var activeMask = timeIndices < effectiveSequenceLength

    if timeIndices >= effectiveSequenceLength && !isLastChunk {
      decoderState.timeJump = timeIndices - effectiveSequenceLength
      return TdtHypothesis(decState: decoderState)
    }

    var timeIndicesCurrentLabels = timeIndices

    let targetArray = try MLMultiArray(shape: [1, 1], dataType: .int32)
    let targetLengthArray = try MLMultiArray(shape: [1], dataType: .int32)
    targetLengthArray[0] = 1

    let encoderStep = try MLMultiArray(
      shape: [1, NSNumber(value: ParakeetConstants.encoderHiddenSize), 1], dataType: .float32)
    let decoderStep = try MLMultiArray(
      shape: [1, NSNumber(value: ParakeetConstants.decoderHiddenSize), 1], dataType: .float32)
    let jointInput = JointInputProvider(encoderStep: encoderStep, decoderStep: decoderStep)
    let encoderDestStride = encoderStep.strides[1].intValue
    let encoderDestPtr = encoderStep.dataPointer.bindMemory(
      to: Float.self, capacity: ParakeetConstants.encoderHiddenSize)

    if decoderState.lastToken == nil && decoderState.predictorOutput == nil {
      decoderState.hiddenState.zeroFill()
      decoderState.cellState.zeroFill()
    }

    if decoderState.predictorOutput == nil && hypothesis.lastToken == nil {
      let primed = try runDecoder(
        token: ParakeetConstants.blankId,
        state: decoderState,
        model: decoderModel,
        targetArray: targetArray,
        targetLengthArray: targetLengthArray
      )
      decoderState.predictorOutput = try extractFeatureValue(from: primed.output, key: "decoder")
      hypothesis.decState = primed.newState
    }

    var lastEmissionTimestamp = -1
    var emissionsAtThisTimestamp = 0
    var tokensProcessedThisChunk = 0

    while activeMask {
      try Task.checkCancellation()
      var label = hypothesis.lastToken ?? ParakeetConstants.blankId
      let stateToUse = hypothesis.decState ?? decoderState

      let decoderResult: (output: MLFeatureProvider, newState: TdtDecoderState)
      if let cached = decoderState.predictorOutput {
        let provider = try MLDictionaryFeatureProvider(dictionary: [
          "decoder": MLFeatureValue(multiArray: cached)
        ])
        decoderResult = (output: provider, newState: stateToUse)
      } else {
        decoderResult = try runDecoder(
          token: label,
          state: stateToUse,
          model: decoderModel,
          targetArray: targetArray,
          targetLengthArray: targetLengthArray
        )
      }

      let decoderProjection = try extractFeatureValue(from: decoderResult.output, key: "decoder")
      try normalizeDecoderProjection(decoderProjection, into: decoderStep)

      var decision = try runJoint(
        encoderFrames: encoderFrames,
        timeIndex: safeTimeIndices,
        model: jointModel,
        inputProvider: jointInput,
        encoderDestPtr: encoderDestPtr,
        encoderDestStride: encoderDestStride,
        hotwordBias: hotwordBias,
        history: hypothesis.ySequence
      )

      label = decision.token
      var duration = try mapDurationBin(decision.durationBin)
      var blankMask = label == ParakeetConstants.blankId

      let currentTimeIndex = timeIndices
      if !blankMask && duration == 0
        && currentTimeIndex == lastEmissionTimestamp
        && emissionsAtThisTimestamp >= 1
      {
        duration = 1
      }
      if blankMask && duration == 0 {
        duration = 1
      }

      timeIndicesCurrentLabels = timeIndices
      timeIndices += duration
      safeTimeIndices = min(timeIndices, lastTimestep)
      activeMask = timeIndices < effectiveSequenceLength
      var advanceMask = activeMask && blankMask

      while advanceMask {
        try Task.checkCancellation()
        timeIndicesCurrentLabels = timeIndices

        decision = try runJoint(
          encoderFrames: encoderFrames,
          timeIndex: safeTimeIndices,
          model: jointModel,
          inputProvider: jointInput,
          encoderDestPtr: encoderDestPtr,
          encoderDestStride: encoderDestStride,
          hotwordBias: hotwordBias,
          history: hypothesis.ySequence
        )

        label = decision.token
        duration = try mapDurationBin(decision.durationBin)
        blankMask = label == ParakeetConstants.blankId
        if blankMask && duration == 0 {
          duration = 1
        }

        timeIndices += duration
        safeTimeIndices = min(timeIndices, lastTimestep)
        activeMask = timeIndices < effectiveSequenceLength
        advanceMask = activeMask && blankMask
      }

      if activeMask && label != ParakeetConstants.blankId {
        tokensProcessedThisChunk += 1
        if tokensProcessedThisChunk > ParakeetConstants.maxTokensPerChunk {
          break
        }

        hypothesis.ySequence.append(label)
        hypothesis.lastToken = label

        let step = try runDecoder(
          token: label,
          state: decoderResult.newState,
          model: decoderModel,
          targetArray: targetArray,
          targetLengthArray: targetLengthArray
        )
        hypothesis.decState = step.newState
        decoderState.predictorOutput = try extractFeatureValue(from: step.output, key: "decoder")

        if timeIndicesCurrentLabels == lastEmissionTimestamp {
          emissionsAtThisTimestamp += 1
        } else {
          lastEmissionTimestamp = timeIndicesCurrentLabels
          emissionsAtThisTimestamp = 1
        }

        if emissionsAtThisTimestamp >= ParakeetConstants.maxSymbolsPerStep {
          timeIndices = min(timeIndices + 1, lastTimestep)
          safeTimeIndices = min(timeIndices, lastTimestep)
          emissionsAtThisTimestamp = 0
          lastEmissionTimestamp = -1
        }
      }

      activeMask = timeIndices < effectiveSequenceLength
    }

    if isLastChunk {
      try flushLastChunk(
        hypothesis: &hypothesis,
        decoderState: &decoderState,
        encoderFrames: encoderFrames,
        effectiveSequenceLength: effectiveSequenceLength,
        timeIndices: timeIndices,
        decoderModel: decoderModel,
        jointModel: jointModel,
        targetArray: targetArray,
        targetLengthArray: targetLengthArray,
        jointInput: jointInput,
        decoderStep: decoderStep,
        encoderDestPtr: encoderDestPtr,
        encoderDestStride: encoderDestStride,
        hotwordBias: hotwordBias
      )
      decoderState.finalizeLastChunk()
    }

    if let finalState = hypothesis.decState {
      decoderState = finalState
    }
    decoderState.lastToken = hypothesis.lastToken

    if let lastToken = hypothesis.lastToken,
      ParakeetConstants.punctuationTokens.contains(lastToken)
    {
      decoderState.predictorOutput = nil
    }

    decoderState.timeJump = isLastChunk ? nil : timeIndices - effectiveSequenceLength

    return hypothesis
  }

  private func flushLastChunk(
    hypothesis: inout TdtHypothesis,
    decoderState: inout TdtDecoderState,
    encoderFrames: EncoderFrameView,
    effectiveSequenceLength: Int,
    timeIndices: Int,
    decoderModel: MLModel,
    jointModel: MLModel,
    targetArray: MLMultiArray,
    targetLengthArray: MLMultiArray,
    jointInput: MLFeatureProvider,
    decoderStep: MLMultiArray,
    encoderDestPtr: UnsafeMutablePointer<Float>,
    encoderDestStride: Int,
    hotwordBias: TdtHotwordBias?
  ) throws {
    var additionalSteps = 0
    var consecutiveBlanks = 0
    var lastToken = hypothesis.lastToken ?? ParakeetConstants.blankId
    var finalProcessingTimeIndices = timeIndices

    while additionalSteps < ParakeetConstants.maxSymbolsPerStep
      && consecutiveBlanks < ParakeetConstants.consecutiveBlankLimit
    {
      try Task.checkCancellation()
      let stateToUse = hypothesis.decState ?? decoderState

      let decoderResult: (output: MLFeatureProvider, newState: TdtDecoderState)
      if let cached = decoderState.predictorOutput {
        let provider = try MLDictionaryFeatureProvider(dictionary: [
          "decoder": MLFeatureValue(multiArray: cached)
        ])
        decoderResult = (output: provider, newState: stateToUse)
      } else {
        decoderResult = try runDecoder(
          token: lastToken,
          state: stateToUse,
          model: decoderModel,
          targetArray: targetArray,
          targetLengthArray: targetLengthArray
        )
      }

      let frameVariations = [
        min(finalProcessingTimeIndices, encoderFrames.count - 1),
        min(effectiveSequenceLength - 1, encoderFrames.count - 1),
        min(max(0, effectiveSequenceLength - 2), encoderFrames.count - 1),
      ]
      let frameIndex = frameVariations[additionalSteps % frameVariations.count]

      let projection = try extractFeatureValue(from: decoderResult.output, key: "decoder")
      try normalizeDecoderProjection(projection, into: decoderStep)

      let decision = try runJoint(
        encoderFrames: encoderFrames,
        timeIndex: frameIndex,
        model: jointModel,
        inputProvider: jointInput,
        encoderDestPtr: encoderDestPtr,
        encoderDestStride: encoderDestStride,
        hotwordBias: hotwordBias,
        history: hypothesis.ySequence
      )
      let duration = try mapDurationBin(decision.durationBin)

      if decision.token == ParakeetConstants.blankId {
        consecutiveBlanks += 1
      } else {
        consecutiveBlanks = 0
        hypothesis.ySequence.append(decision.token)
        hypothesis.lastToken = decision.token

        let step = try runDecoder(
          token: decision.token,
          state: decoderResult.newState,
          model: decoderModel,
          targetArray: targetArray,
          targetLengthArray: targetLengthArray
        )
        hypothesis.decState = step.newState
        decoderState.predictorOutput = try extractFeatureValue(from: step.output, key: "decoder")
        lastToken = decision.token
      }

      finalProcessingTimeIndices = min(
        finalProcessingTimeIndices + max(1, duration), effectiveSequenceLength)
      additionalSteps += 1
    }
  }

  private func runDecoder(
    token: Int,
    state: TdtDecoderState,
    model: MLModel,
    targetArray: MLMultiArray,
    targetLengthArray: MLMultiArray
  ) throws -> (output: MLFeatureProvider, newState: TdtDecoderState) {
    targetArray[0] = NSNumber(value: token)
    let input = try MLDictionaryFeatureProvider(dictionary: [
      "targets": MLFeatureValue(multiArray: targetArray),
      "target_length": MLFeatureValue(multiArray: targetLengthArray),
      "h_in": MLFeatureValue(multiArray: state.hiddenState),
      "c_in": MLFeatureValue(multiArray: state.cellState),
    ])
    let output = try model.prediction(from: input)
    var newState = state
    newState.update(from: output)
    return (output, newState)
  }

  private struct JointDecision {
    let token: Int
    let durationBin: Int
  }

  private func runJoint(
    encoderFrames: EncoderFrameView,
    timeIndex: Int,
    model: MLModel,
    inputProvider: MLFeatureProvider,
    encoderDestPtr: UnsafeMutablePointer<Float>,
    encoderDestStride: Int,
    hotwordBias: TdtHotwordBias?,
    history: [Int]
  ) throws -> JointDecision {
    try encoderFrames.copyFrame(
      at: timeIndex, into: encoderDestPtr, destinationStride: encoderDestStride)

    let output = try model.prediction(from: inputProvider)

    let tokenArray = try extractFeatureValue(from: output, key: "token_id")
    let durationArray = try extractFeatureValue(from: output, key: "duration")
    guard tokenArray.count == 1, durationArray.count == 1 else {
      throw DictationError.processingFailed("Joint decision returned unexpected tensor shapes")
    }

    let defaultToken = Int(tokenArray.dataPointer.bindMemory(to: Int32.self, capacity: 1)[0])
    let token = hotwordBias?.selectToken(
      defaultToken: defaultToken,
      history: history,
      candidateIDs: output.featureValue(for: "top_k_ids")?.multiArrayValue,
      candidateLogits: output.featureValue(for: "top_k_logits")?.multiArrayValue
    ) ?? defaultToken
    let durationBin = Int(durationArray.dataPointer.bindMemory(to: Int32.self, capacity: 1)[0])
    return JointDecision(token: token, durationBin: durationBin)
  }

  private func mapDurationBin(_ binIndex: Int) throws -> Int {
    let bins = ParakeetConstants.durationBins
    guard binIndex >= 0 && binIndex < bins.count else {
      throw DictationError.processingFailed("Duration bin index out of range: \(binIndex)")
    }
    return bins[binIndex]
  }

  private func normalizeDecoderProjection(
    _ projection: MLMultiArray, into destination: MLMultiArray
  ) throws {
    let hiddenSize = ParakeetConstants.decoderHiddenSize
    let shape = projection.shape.map { $0.intValue }

    guard shape.count == 3, shape[0] == 1, projection.dataType == .float32 else {
      throw DictationError.processingFailed("Invalid decoder projection: \(shape)")
    }

    let hiddenAxis: Int
    if shape[2] == hiddenSize {
      hiddenAxis = 2
    } else if shape[1] == hiddenSize {
      hiddenAxis = 1
    } else {
      throw DictationError.processingFailed("Decoder projection hidden size mismatch: \(shape)")
    }
    let timeAxis = hiddenAxis == 2 ? 1 : 2
    guard shape[timeAxis] == 1 else {
      throw DictationError.processingFailed("Decoder projection time axis must be 1: \(shape)")
    }

    let sourcePtr = projection.dataPointer.bindMemory(to: Float.self, capacity: projection.count)
    let destPtr = destination.dataPointer.bindMemory(to: Float.self, capacity: hiddenSize)
    let sourceStride = projection.strides[hiddenAxis].intValue
    let destStride = destination.strides[1].intValue
    if sourceStride == 1 && destStride == 1 {
      destPtr.update(from: sourcePtr, count: hiddenSize)
    } else {
      for i in 0..<hiddenSize {
        destPtr[i * destStride] = sourcePtr[i * sourceStride]
      }
    }
  }

  private func extractFeatureValue(from provider: MLFeatureProvider, key: String) throws -> MLMultiArray {
    guard let value = provider.featureValue(for: key)?.multiArrayValue else {
      throw DictationError.processingFailed("Missing model output: \(key)")
    }
    return value
  }
}
