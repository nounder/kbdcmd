@preconcurrency import CoreML
import Foundation

public enum ParakeetEncoderPrecision: String, Sendable, CaseIterable {
  case int8
  case int4

  var encoderFileName: String {
    switch self {
    case .int8: return "Encoder.mlmodelc"
    case .int4: return "EncoderInt4.mlmodelc"
    }
  }
}

enum ParakeetModelFiles {
  static let repo = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
  static let preprocessor = "Preprocessor.mlmodelc"
  static let decoder = "Decoder.mlmodelc"
  static let joint = "JointDecisionv3.mlmodelc"
  static let vocabulary = "parakeet_vocab.json"

  static func required(precision: ParakeetEncoderPrecision) -> [String] {
    [preprocessor, precision.encoderFileName, decoder, joint, vocabulary]
  }
}

struct ParakeetModels {
  let preprocessor: MLModel
  let encoder: MLModel
  let decoder: MLModel
  let joint: MLModel
  let tokenizer: ParakeetTokenizer

  static func load(from directory: URL, precision: ParakeetEncoderPrecision) throws -> ParakeetModels {
    let preprocessorConfig = MLModelConfiguration()
    preprocessorConfig.computeUnits = .cpuOnly
    let aneConfig = MLModelConfiguration()
    aneConfig.computeUnits = .cpuAndNeuralEngine

    let preprocessor = try loadModel(named: ParakeetModelFiles.preprocessor, in: directory, config: preprocessorConfig)
    let encoder = try loadModel(named: precision.encoderFileName, in: directory, config: aneConfig)
    let decoder = try loadModel(named: ParakeetModelFiles.decoder, in: directory, config: aneConfig)
    let joint = try loadModel(named: ParakeetModelFiles.joint, in: directory, config: aneConfig)
    let tokenizer = try ParakeetTokenizer(
      vocabularyFile: directory.appendingPathComponent(ParakeetModelFiles.vocabulary))

    try validate(model: preprocessor, name: "preprocessor", inputs: ["audio_signal", "audio_length"])
    try validate(model: decoder, name: "decoder", inputs: ["targets", "target_length", "h_in", "c_in"])
    try validate(model: joint, name: "joint", inputs: ["encoder_step", "decoder_step"])

    return ParakeetModels(
      preprocessor: preprocessor, encoder: encoder, decoder: decoder, joint: joint,
      tokenizer: tokenizer)
  }

  private static func loadModel(named name: String, in directory: URL, config: MLModelConfiguration) throws -> MLModel {
    let url = directory.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw DictationError.modelsMissing("\(name) not found in \(directory.path)")
    }
    do {
      return try MLModel(contentsOf: url, configuration: config)
    } catch {
      throw DictationError.modelsMissing("failed to load \(name): \(error.localizedDescription)")
    }
  }

  private static func validate(model: MLModel, name: String, inputs: [String]) throws {
    let available = Set(model.modelDescription.inputDescriptionsByName.keys)
    let missing = inputs.filter { !available.contains($0) }
    guard missing.isEmpty else {
      throw DictationError.modelsMissing(
        "\(name) model schema mismatch, missing inputs \(missing) (has: \(available.sorted()))")
    }
  }
}
