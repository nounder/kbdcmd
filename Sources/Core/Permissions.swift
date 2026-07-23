import ApplicationServices
import Cocoa
import Foundation

enum PermissionError: Error {
  case accessibilityNotGranted
}

public struct Permissions {
  public static func checkAccessibility() throws {
    if !AXIsProcessTrusted() {
      print("Error: This application doesn't have the required accessibility permissions.")
      print(
        "Please grant accessibility permissions to Terminal (or your development environment) in:"
      )
      print("System Preferences > Security & Privacy > Privacy > Accessibility")
      openSystemPreferencesToAccessibility()
      throw PermissionError.accessibilityNotGranted
    }
    Ax.setGlobalMessagingTimeout(1.0)
  }

  private static func openSystemPreferencesToAccessibility() {
    let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    NSWorkspace.shared.open(url)
  }
}
