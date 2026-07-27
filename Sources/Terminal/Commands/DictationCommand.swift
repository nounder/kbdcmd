import ArgumentParser
import AVFoundation
import Core
import Foundation

struct DictationCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "dictation",
    abstract: "Local speech-to-text with the Parakeet model",
    subcommands: [Download.self, Status.self, Transcribe.self, Normalize.self]
  )

  struct Normalize: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Apply inverse text normalization to spoken-form text")

    @Argument(help: "Spoken-form text; reads stdin when omitted")
    var text: [String] = []

    func run() throws {
      let input =
        text.isEmpty
        ? (readLines() ?? "")
        : text.joined(separator: " ")
      for line in input.split(separator: "\n", omittingEmptySubsequences: false) {
        print(InverseTextNormalizer.normalize(String(line)))
      }
    }

    private func readLines() -> String? {
      var buffer = ""
      while let line = readLine(strippingNewline: false) {
        buffer += line
      }
      return buffer.isEmpty ? nil : buffer
    }
  }

  struct Download: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Download the Parakeet CoreML models from Hugging Face")

    @Option(help: "Encoder precision: int8 or int4")
    var precision: String = "int8"

    @Flag(help: "Re-download even if models are present")
    var force: Bool = false

    func run() async throws {
      let precision = try parsePrecision(self.precision)
      try await ModelDownloader.shared.download(precision: precision, force: force) { fraction, file in
        let percent = Int(fraction * 100)
        print("\r[\(percent)%] \(file)", terminator: percent == 100 ? "\n" : "")
        fflush(stdout)
      }
      print("Models ready in \(ModelDownloader.modelsDirectory().path)")
    }
  }

  struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show dictation model cache status")

    func run() throws {
      let directory = ModelDownloader.modelsDirectory()
      print("Cache: \(directory.path)")
      for precision in ParakeetEncoderPrecision.allCases {
        let present = ModelDownloader.modelsPresent(precision: precision)
        print("\(precision.rawValue): \(present ? "downloaded" : "not downloaded")")
      }
    }
  }

  struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Transcribe an audio file (for testing the pipeline)")

    @Argument(help: "Path to an audio file (wav/m4a/aiff/mp3)")
    var file: String

    @Option(help: "Encoder precision: int8 or int4")
    var precision: String = "int8"

    @Option(
      name: .customLong("hotword"),
      help: "Phrase to contextually bias; repeat for multiple phrases")
    var hotwords: [String] = []

    @Option(help: "Logit boost for --hotword (default: 4)")
    var hotwordBoost: Float = 4

    func run() async throws {
      let precision = try parsePrecision(self.precision)
      let samples = try loadSamples16kMono(path: file)
      let audioSeconds = Double(samples.count) / 16000.0
      print("Loaded \(String(format: "%.1f", audioSeconds))s of audio, preparing models...")

      let transcriber = ParakeetTranscriber.shared
      let loadStart = Date()
      try await transcriber.prepare(precision: precision)
      if !hotwords.isEmpty {
        try await transcriber.setHotwords(hotwords, boost: hotwordBoost)
      }
      print("Models loaded in \(String(format: "%.2f", -loadStart.timeIntervalSinceNow))s")

      let start = Date()
      let text = try await transcriber.transcribe(samples)
      let elapsed = -start.timeIntervalSinceNow
      let rtf = audioSeconds / max(elapsed, 0.001)

      print("Transcribed in \(String(format: "%.2f", elapsed))s (\(String(format: "%.0f", rtf))x realtime)")
      print(text)
    }
  }
}

private func parsePrecision(_ raw: String) throws -> ParakeetEncoderPrecision {
  guard let precision = ParakeetEncoderPrecision(rawValue: raw) else {
    throw ValidationError("precision must be int8 or int4")
  }
  return precision
}

private func loadSamples16kMono(path: String) throws -> [Float] {
  let url = URL(fileURLWithPath: path)
  let file = try AVAudioFile(forReading: url)

  guard
    let targetFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
  else {
    throw DictationError.invalidAudio("could not create target format")
  }

  guard
    let inputBuffer = AVAudioPCMBuffer(
      pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
  else {
    throw DictationError.invalidAudio("could not allocate read buffer")
  }
  try file.read(into: inputBuffer)

  if file.processingFormat == targetFormat {
    return samplesFromBuffer(inputBuffer)
  }

  guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
    throw DictationError.invalidAudio("unsupported audio format \(file.processingFormat)")
  }
  let ratio = 16000.0 / file.processingFormat.sampleRate
  let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1024
  guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
    throw DictationError.invalidAudio("could not allocate conversion buffer")
  }

  var fed = false
  var conversionError: NSError?
  converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
    if fed {
      outStatus.pointee = .endOfStream
      return nil
    }
    fed = true
    outStatus.pointee = .haveData
    return inputBuffer
  }
  if let conversionError {
    throw DictationError.invalidAudio("conversion failed: \(conversionError.localizedDescription)")
  }
  return samplesFromBuffer(outputBuffer)
}

private func samplesFromBuffer(_ buffer: AVAudioPCMBuffer) -> [Float] {
  guard let channelData = buffer.floatChannelData else { return [] }
  return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
}
