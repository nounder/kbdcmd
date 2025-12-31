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

  private init() {
    self.includeMinimizedWindows = UserDefaults.standard.bool(forKey: "includeMinimizedWindows")
    self.includeOtherSpacesWindows = UserDefaults.standard.bool(forKey: "includeOtherSpacesWindows")
  }
}

struct SettingsView: View {
  @ObservedObject private var settings = SettingsStore.shared

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
    }
    .formStyle(.grouped)
    .frame(width: 450, height: 150)
  }
}
