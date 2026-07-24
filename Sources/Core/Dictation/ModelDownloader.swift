import Foundation

public actor ModelDownloader {
  public static let shared = ModelDownloader()

  private struct TreeEntry: Decodable {
    struct Lfs: Decodable {
      let size: Int
    }
    let type: String
    let path: String
    let size: Int
    let lfs: Lfs?

    var byteSize: Int { lfs?.size ?? size }
  }

  public static func modelsDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("kbdcmd/models/parakeet-tdt-0.6b-v3")
  }

  public static func modelsPresent(precision: ParakeetEncoderPrecision) -> Bool {
    let directory = modelsDirectory()
    let marker = directory.appendingPathComponent(".complete-\(precision.rawValue)")
    guard FileManager.default.fileExists(atPath: marker.path) else { return false }
    return ParakeetModelFiles.required(precision: precision).allSatisfy {
      FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
    }
  }

  public func download(
    precision: ParakeetEncoderPrecision = .int8,
    force: Bool = false,
    progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
  ) async throws {
    let directory = Self.modelsDirectory()
    let marker = directory.appendingPathComponent(".complete-\(precision.rawValue)")

    if force {
      try? FileManager.default.removeItem(at: directory)
    } else if Self.modelsPresent(precision: precision) {
      progress(1.0, "already downloaded")
      return
    }
    DictationModelStatus.shared.set(.downloading(0))
    defer {
      DictationModelStatus.shared.set(
        Self.modelsPresent(precision: precision) ? .notLoaded : .notDownloaded)
    }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    var files: [TreeEntry] = []
    for name in ParakeetModelFiles.required(precision: precision) {
      if name.hasSuffix(".mlmodelc") {
        files.append(contentsOf: try await listFiles(under: name))
      } else {
        files.append(TreeEntry(type: "file", path: name, size: 0, lfs: nil))
      }
    }

    let totalBytes = files.reduce(0) { $0 + $1.byteSize }
    var downloadedBytes = 0

    for file in files {
      try Task.checkCancellation()
      let destination = directory.appendingPathComponent(file.path)

      if !force, file.byteSize > 0,
        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
        (attributes[.size] as? Int) == file.byteSize
      {
        downloadedBytes += file.byteSize
        progress(fraction(downloadedBytes, of: totalBytes), file.path)
        continue
      }

      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

      let url = URL(string: "https://huggingface.co/\(ParakeetModelFiles.repo)/resolve/main/\(file.path)")!
      let (temporary, response) = try await URLSession.shared.download(from: url)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        try? FileManager.default.removeItem(at: temporary)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        throw DictationError.downloadFailed("HTTP \(status) for \(file.path)")
      }
      if file.byteSize > 0,
        let attributes = try? FileManager.default.attributesOfItem(atPath: temporary.path),
        let size = attributes[.size] as? Int, size != file.byteSize
      {
        try? FileManager.default.removeItem(at: temporary)
        throw DictationError.downloadFailed(
          "size mismatch for \(file.path): got \(size), expected \(file.byteSize)")
      }

      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: temporary, to: destination)

      downloadedBytes += file.byteSize
      let completed = fraction(downloadedBytes, of: totalBytes)
      DictationModelStatus.shared.set(.downloading(Int(completed * 100)))
      progress(completed, file.path)
    }

    FileManager.default.createFile(atPath: marker.path, contents: Data())
    progress(1.0, "done")
  }

  private func listFiles(under path: String) async throws -> [TreeEntry] {
    let url = URL(
      string: "https://huggingface.co/api/models/\(ParakeetModelFiles.repo)/tree/main/\(path)?recursive=true")!
    let (data, response) = try await URLSession.shared.data(from: url)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let status = (response as? HTTPURLResponse)?.statusCode ?? -1
      throw DictationError.downloadFailed("HTTP \(status) listing \(path)")
    }
    let entries = try JSONDecoder().decode([TreeEntry].self, from: data)
    let files = entries.filter { $0.type == "file" }
    guard !files.isEmpty else {
      throw DictationError.downloadFailed("no files listed under \(path)")
    }
    return files
  }

  private func fraction(_ part: Int, of total: Int) -> Double {
    total > 0 ? Double(part) / Double(total) : 0
  }
}
