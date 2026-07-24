import AppKit
import AVFoundation
import Foundation

enum MicPermission {
  enum Status {
    case granted
    case denied
    case undetermined
  }

  static var status: Status {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return .granted
    case .notDetermined: return .undetermined
    default: return .denied
    }
  }

  static func request(completion: @escaping (Bool) -> Void) {
    AVCaptureDevice.requestAccess(for: .audio) { granted in
      DispatchQueue.main.async {
        completion(granted)
      }
    }
  }

  static func openSystemSettings() {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    {
      NSWorkspace.shared.open(url)
    }
  }
}
