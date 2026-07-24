import Foundation

// Observable model lifecycle state for UI. Updated from the transcriber and
// downloader; always mutated on the main queue.
public final class DictationModelStatus: ObservableObject, @unchecked Sendable {
  public static let shared = DictationModelStatus()

  public enum State: Equatable {
    case notDownloaded
    case downloading(Int)
    case notLoaded
    case loading
    case loaded
  }

  @Published public private(set) var state: State = .notDownloaded

  private init() {
    refresh()
  }

  // Sync disk state without downgrading an active download/load/loaded state.
  public func refresh() {
    onMain {
      switch self.state {
      case .downloading, .loading, .loaded:
        return
      case .notDownloaded, .notLoaded:
        self.state =
          ModelDownloader.modelsPresent(precision: DictationSettings.encoderPrecision)
          ? .notLoaded : .notDownloaded
      }
    }
  }

  func set(_ newState: State) {
    onMain { self.state = newState }
  }

  private func onMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }
}
