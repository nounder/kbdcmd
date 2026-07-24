import Core
import SwiftUI

class SettingsStore: ObservableObject {
  static let shared = SettingsStore()

  @Published var includeMinimizedWindows: Bool {
    didSet { UserDefaults.standard.set(includeMinimizedWindows, forKey: "includeMinimizedWindows") }
  }

  @Published var includeOtherSpacesWindows: Bool {
    didSet {
      UserDefaults.standard.set(includeOtherSpacesWindows, forKey: "includeOtherSpacesWindows")
    }
  }

  @Published var dictationEnabled: Bool {
    didSet { DictationSettings.enabled = dictationEnabled }
  }

  private init() {
    self.includeMinimizedWindows = UserDefaults.standard.bool(forKey: "includeMinimizedWindows")
    self.includeOtherSpacesWindows = UserDefaults.standard.bool(forKey: "includeOtherSpacesWindows")
    self.dictationEnabled = DictationSettings.enabled
  }
}

struct SettingsView: View {
  @ObservedObject private var settings = SettingsStore.shared
  @ObservedObject private var modelStatus = DictationModelStatus.shared

  var body: some View {
    Form {
      Section {
        LabeledContent("Window cycling") {
          VStack(alignment: .leading, spacing: 6) {
            Toggle("Include minimized windows", isOn: $settings.includeMinimizedWindows)
            Toggle("Include windows from other Spaces", isOn: $settings.includeOtherSpacesWindows)
          }
        }
      }

      Section("Dictation") {
        Toggle("Enable dictation (hold Fn, or double-tap Fn)", isOn: $settings.dictationEnabled)
        LabeledContent("Model") {
          modelRow
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 450, height: 240)
    .onAppear { modelStatus.refresh() }
  }

  @ViewBuilder
  private var modelRow: some View {
    switch modelStatus.state {
    case .notDownloaded:
      HStack {
        Text("Not downloaded (~500 MB)")
          .foregroundStyle(.secondary)
        Button("Download") { downloadAndLoad() }
      }
    case .downloading(let percent):
      HStack {
        ProgressView().controlSize(.small)
        Text("Downloading… \(percent)%")
          .foregroundStyle(.secondary)
      }
    case .notLoaded:
      HStack {
        Text("Downloaded, not loaded")
          .foregroundStyle(.secondary)
        Button("Load") { load() }
      }
    case .loading:
      HStack {
        ProgressView().controlSize(.small)
        Text("Loading into memory…")
          .foregroundStyle(.secondary)
      }
    case .loaded:
      HStack(spacing: 6) {
        Circle().fill(.green).frame(width: 8, height: 8)
        Text("Loaded in memory")
          .foregroundStyle(.secondary)
      }
    }
  }

  private func downloadAndLoad() {
    Task {
      try? await ModelDownloader.shared.download(
        precision: DictationSettings.encoderPrecision) { _, _ in }
      load()
    }
  }

  private func load() {
    Task {
      try? await ParakeetTranscriber.shared.prepare(precision: DictationSettings.encoderPrecision)
      try? await ParakeetTranscriber.shared.warmUp()
    }
  }
}
