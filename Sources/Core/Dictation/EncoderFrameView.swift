import CoreML
import Foundation

// Stride-aware view over encoder output frames; the encoder may emit either
// [1, T, 1024] or [1, 1024, T], so axis roles are resolved from the shape.
struct EncoderFrameView {
  let hiddenSize: Int
  let count: Int

  private let timeStride: Int
  private let hiddenStride: Int
  private let timeBaseOffset: Int
  private let basePointer: UnsafeMutablePointer<Float>

  init(encoderOutput: MLMultiArray, validLength: Int, expectedHiddenSize: Int) throws {
    let shape = encoderOutput.shape.map { $0.intValue }
    guard shape.count == 3 else {
      throw DictationError.processingFailed("Invalid encoder output shape: \(shape)")
    }
    guard shape[0] == 1 else {
      throw DictationError.processingFailed("Unsupported encoder batch dimension: \(shape[0])")
    }
    guard encoderOutput.dataType == .float32 else {
      throw DictationError.processingFailed("Unsupported encoder output type: \(encoderOutput.dataType)")
    }

    let axis1MatchesHidden = shape[1] == expectedHiddenSize
    let axis2MatchesHidden = shape[2] == expectedHiddenSize
    guard axis1MatchesHidden || axis2MatchesHidden else {
      throw DictationError.processingFailed(
        "Encoder hidden size mismatch: \(shape), expected \(expectedHiddenSize)")
    }
    let hiddenAxis = axis1MatchesHidden ? 1 : 2
    let timeAxis = axis1MatchesHidden ? 2 : 1
    hiddenSize = expectedHiddenSize

    let strides = encoderOutput.strides.map { $0.intValue }
    hiddenStride = strides[hiddenAxis]
    timeStride = strides[timeAxis]

    let availableFrames = shape[timeAxis]
    count = min(validLength, availableFrames)
    guard count > 0 else {
      throw DictationError.processingFailed("Encoder output has no frames")
    }

    basePointer = encoderOutput.dataPointer.bindMemory(to: Float.self, capacity: encoderOutput.count)
    timeBaseOffset = timeStride >= 0 ? 0 : (availableFrames - 1) * timeStride
  }

  func copyFrame(at index: Int, into destination: UnsafeMutablePointer<Float>, destinationStride: Int) throws {
    guard index >= 0 && index < count else {
      throw DictationError.processingFailed("Encoder frame index out of range: \(index)")
    }
    guard hiddenStride != 0 else {
      throw DictationError.processingFailed("Invalid encoder hidden stride: 0")
    }

    let frameStart = basePointer.advanced(by: timeBaseOffset + index * timeStride)
    if hiddenStride == 1 && destinationStride == 1 {
      destination.update(from: frameStart, count: hiddenSize)
    } else {
      for i in 0..<hiddenSize {
        destination[i * destinationStride] = frameStart[i * hiddenStride]
      }
    }
  }
}
