@preconcurrency import CoreML
import Foundation

struct TdtDecoderState {
  var hiddenState: MLMultiArray
  var cellState: MLMultiArray
  var lastToken: Int?
  var predictorOutput: MLMultiArray?
  var timeJump: Int?

  init() throws {
    let shape: [NSNumber] = [
      NSNumber(value: ParakeetConstants.decoderLayers),
      1,
      NSNumber(value: ParakeetConstants.decoderHiddenSize),
    ]
    hiddenState = try MLMultiArray(shape: shape, dataType: .float32)
    cellState = try MLMultiArray(shape: shape, dataType: .float32)
    hiddenState.zeroFill()
    cellState.zeroFill()
  }

  init(copying other: TdtDecoderState) throws {
    hiddenState = try MLMultiArray(shape: other.hiddenState.shape, dataType: .float32)
    cellState = try MLMultiArray(shape: other.cellState.shape, dataType: .float32)
    hiddenState.copyFloatData(from: other.hiddenState)
    cellState.copyFloatData(from: other.cellState)
    lastToken = other.lastToken
    timeJump = other.timeJump
  }

  mutating func update(from decoderOutput: MLFeatureProvider) {
    hiddenState = decoderOutput.featureValue(for: "h_out")?.multiArrayValue ?? hiddenState
    cellState = decoderOutput.featureValue(for: "c_out")?.multiArrayValue ?? cellState
  }

  mutating func reset() {
    hiddenState.zeroFill()
    cellState.zeroFill()
    lastToken = nil
    predictorOutput = nil
    timeJump = nil
  }

  mutating func finalizeLastChunk() {
    predictorOutput = nil
    timeJump = nil
  }
}

extension MLMultiArray {
  func zeroFill() {
    memset(dataPointer, 0, count * MemoryLayout<Float>.stride)
  }

  func copyFloatData(from source: MLMultiArray) {
    memcpy(dataPointer, source.dataPointer, count * MemoryLayout<Float>.stride)
  }
}
