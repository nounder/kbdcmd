import CoreAudio
import Foundation

/// Temporarily mutes the default system output and restores the mute state that
/// was in effect before dictation began.
final class SystemAudioMuter {
  static let shared = SystemAudioMuter()

  private struct SavedState {
    let deviceID: AudioDeviceID
    let wasMuted: UInt32
  }

  private var savedState: SavedState?
  private var lock = os_unfair_lock_s()

  private init() {}

  /// Returns true when the output is muted (including when it was already
  /// muted), and false when the current output device does not support mute.
  @discardableResult
  func mute() -> Bool {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }

    if savedState != nil {
      return true
    }

    guard let deviceID = defaultOutputDevice(), let wasMuted = muteValue(for: deviceID) else {
      return false
    }

    if wasMuted == 0, !setMuteValue(1, for: deviceID) {
      return false
    }
    savedState = SavedState(deviceID: deviceID, wasMuted: wasMuted)
    return true
  }

  func restore() {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }

    guard let savedState else { return }
    self.savedState = nil
    _ = setMuteValue(savedState.wasMuted, for: savedState.deviceID)
  }

  private func defaultOutputDevice() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
  }

  private func muteValue(for deviceID: AudioDeviceID) -> UInt32? {
    var address = muteAddress
    guard AudioObjectHasProperty(deviceID, &address) else { return nil }

    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
    return status == noErr ? value : nil
  }

  private func setMuteValue(_ value: UInt32, for deviceID: AudioDeviceID) -> Bool {
    var address = muteAddress
    var settable = DarwinBoolean(false)
    guard
      AudioObjectHasProperty(deviceID, &address),
      AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
      settable.boolValue
    else { return false }

    var value = value
    let size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr
  }

  private var muteAddress: AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyMute,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
  }
}
