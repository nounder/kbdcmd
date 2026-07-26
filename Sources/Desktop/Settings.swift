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

  @Published var muteSystemAudioWhileListening: Bool {
    didSet {
      DictationSettings.muteSystemAudioWhileListening = muteSystemAudioWhileListening
    }
  }

  @Published var hotwordsText: String {
    didSet {
      DictationSettings.hotwords = Self.parseHotwords(hotwordsText)
      applyHotwordsToLoadedModel()
    }
  }

  @Published var hotwordBoost: Float {
    didSet {
      DictationSettings.hotwordBoost = hotwordBoost
      applyHotwordsToLoadedModel()
    }
  }

  private init() {
    self.includeMinimizedWindows = UserDefaults.standard.bool(forKey: "includeMinimizedWindows")
    self.includeOtherSpacesWindows = UserDefaults.standard.bool(forKey: "includeOtherSpacesWindows")
    self.dictationEnabled = DictationSettings.enabled
    self.muteSystemAudioWhileListening = DictationSettings.muteSystemAudioWhileListening
    self.hotwordsText = DictationSettings.hotwords.joined(separator: "\n")
    self.hotwordBoost = DictationSettings.hotwordBoost
  }

  private static func parseHotwords(_ text: String) -> [String] {
    text.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  private func applyHotwordsToLoadedModel() {
    let phrases = Self.parseHotwords(hotwordsText)
    let boost = hotwordBoost
    Task {
      guard await ParakeetTranscriber.shared.isPrepared else { return }
      try? await ParakeetTranscriber.shared.setHotwords(phrases, boost: boost)
    }
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
        Toggle(
          "Mute system audio while listening",
          isOn: $settings.muteSystemAudioWhileListening
        )
        .disabled(!settings.dictationEnabled)
        LabeledContent("Model") {
          modelRow
        }
      }

      Section("Custom vocabulary") {
        VStack(alignment: .leading, spacing: 5) {
          Text("Hotwords")
            .font(.headline)
          TextEditor(text: $settings.hotwordsText)
            .font(.body)
            .frame(maxWidth: .infinity, minHeight: 82)
            .padding(4)
            .overlay {
              RoundedRectangle(cornerRadius: 5)
                .stroke(.separator, lineWidth: 1)
            }
          Text("One name, acronym, or phrase per line")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        VStack(alignment: .leading, spacing: 4) {
          Text("Recognition strength")
            .font(.headline)
          Slider(value: $settings.hotwordBoost, in: 0.5...8, step: 0.5)
            .accessibilityValue(recognitionStrengthLabel)
          HStack {
            Text("Subtle")
            Spacer()
            Text("Balanced")
            Spacer()
            Text("Aggressive")
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
          Text("Higher strength recognizes configured terms more often, but may increase false positives.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .formStyle(.grouped)
    .frame(width: 500, height: 430)
    .onAppear { modelStatus.refresh() }
  }

  private var recognitionStrengthLabel: String {
    switch settings.hotwordBoost {
    case ..<2: return "Subtle"
    case ..<6: return "Balanced"
    default: return "Aggressive"
    }
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
