import Foundation

public enum DictationSettings {
  public enum InsertMode: String {
    case paste
    case type
  }

  private static var defaults: UserDefaults { .standard }

  public static var enabled: Bool {
    get { defaults.object(forKey: "dictation.enabled") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "dictation.enabled") }
  }

  public static var holdEnabled: Bool {
    get { defaults.object(forKey: "dictation.holdEnabled") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "dictation.holdEnabled") }
  }

  public static var doubleTapEnabled: Bool {
    get { defaults.object(forKey: "dictation.doubleTapEnabled") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "dictation.doubleTapEnabled") }
  }

  public static var muteSystemAudioWhileListening: Bool {
    get {
      defaults.object(forKey: "dictation.muteSystemAudioWhileListening") as? Bool ?? true
    }
    set { defaults.set(newValue, forKey: "dictation.muteSystemAudioWhileListening") }
  }

  public static var insertMode: InsertMode {
    get { InsertMode(rawValue: defaults.string(forKey: "dictation.insertMode") ?? "") ?? .paste }
    set { defaults.set(newValue.rawValue, forKey: "dictation.insertMode") }
  }

  public static var encoderPrecision: ParakeetEncoderPrecision {
    get {
      ParakeetEncoderPrecision(rawValue: defaults.string(forKey: "dictation.encoderPrecision") ?? "")
        ?? .int8
    }
    set { defaults.set(newValue.rawValue, forKey: "dictation.encoderPrecision") }
  }

  public static var hotwords: [String] {
    get { defaults.stringArray(forKey: "dictation.hotwords") ?? [] }
    set { defaults.set(newValue, forKey: "dictation.hotwords") }
  }

  public static var hotwordBoost: Float {
    get {
      guard defaults.object(forKey: "dictation.hotwordBoost") != nil else { return 4 }
      return defaults.float(forKey: "dictation.hotwordBoost")
    }
    set { defaults.set(newValue, forKey: "dictation.hotwordBoost") }
  }
}
