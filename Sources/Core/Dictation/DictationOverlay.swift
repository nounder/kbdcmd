import AppKit
import SwiftUI

final class DictationOverlayModel: ObservableObject {
  enum Phase: Equatable {
    case listening
    case transcribing
    case success
    case error(String)
    case downloading(Int)
  }

  @Published var phase: Phase = .listening
  @Published var levels: [Float] = Array(repeating: 0, count: DictationOverlayModel.barCount)
  @Published var committedText: String = ""
  @Published var volatileText: String = ""
  @Published var expanded: Bool = false

  static let barCount = 24

  func pushLevel(_ level: Float) {
    levels.removeFirst()
    levels.append(min(level * 12, 1.0))
  }

  func resetLevels() {
    levels = Array(repeating: 0, count: Self.barCount)
  }
}

// Main-thread confined; every method must be called on the main queue.
final class DictationOverlayController: @unchecked Sendable {
  static let shared = DictationOverlayController()

  let model = DictationOverlayModel()
  private var panel: NSPanel?

  private init() {}

  func show(expanded: Bool) {
    model.expanded = expanded
    model.phase = .listening
    model.committedText = ""
    model.volatileText = ""
    model.resetLevels()

    if panel == nil {
      panel = makePanel()
    }
    reposition()
    panel?.orderFrontRegardless()
  }

  func hide() {
    panel?.orderOut(nil)
  }

  func setPhase(_ phase: DictationOverlayModel.Phase) {
    model.phase = phase
  }

  func flashSuccessAndHide() {
    model.phase = .success
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      if self?.model.phase == .success {
        self?.hide()
      }
    }
  }

  func showErrorAndHide(_ message: String) {
    if panel == nil {
      panel = makePanel()
    }
    reposition()
    panel?.orderFrontRegardless()
    model.phase = .error(message)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
      if case .error = self?.model.phase {
        self?.hide()
      }
    }
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 120),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.contentView = NSHostingView(rootView: DictationOverlayView(model: model))
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    panel.ignoresMouseEvents = true
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    return panel
  }

  private func reposition() {
    guard let panel else { return }
    let screen = screenWithMouse() ?? NSScreen.main
    guard let screen else { return }
    let frame = screen.visibleFrame
    let size = panel.frame.size
    panel.setFrameOrigin(
      NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 60))
  }

  private func screenWithMouse() -> NSScreen? {
    let mouseLocation = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
  }
}

struct DictationOverlayView: View {
  @ObservedObject var model: DictationOverlayModel

  var body: some View {
    VStack {
      Spacer()
      content
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.1)))
      Spacer(minLength: 8)
    }
    .frame(maxWidth: .infinity)
    .animation(.easeInOut(duration: 0.15), value: model.phase)
  }

  @ViewBuilder
  private var content: some View {
    switch model.phase {
    case .listening, .transcribing:
      if model.expanded {
        VStack(alignment: .leading, spacing: 8) {
          transcriptText
          HStack(spacing: 10) {
            statusDot
            WaveformBars(levels: model.levels, frozen: model.phase == .transcribing)
          }
        }
      } else {
        HStack(spacing: 10) {
          statusDot
          WaveformBars(levels: model.levels, frozen: model.phase == .transcribing)
        }
      }
    case .success:
      HStack(spacing: 8) {
        Circle().fill(.green).frame(width: 10, height: 10)
        Text("Inserted").font(.caption).foregroundStyle(.secondary)
      }
    case .error(let message):
      HStack(spacing: 8) {
        Circle().fill(.red).frame(width: 10, height: 10)
        Text(message).font(.caption).foregroundStyle(.primary)
      }
    case .downloading(let percent):
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Downloading model… \(percent)%").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var statusDot: some View {
    Circle()
      .fill(model.phase == .transcribing ? Color.orange : Color.accentColor)
      .frame(width: 10, height: 10)
      .opacity(model.phase == .transcribing ? 0.6 : 1.0)
      .animation(
        model.phase == .transcribing
          ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true) : .default,
        value: model.phase
      )
  }

  @ViewBuilder
  private var transcriptText: some View {
    if model.committedText.isEmpty && model.volatileText.isEmpty {
      Text("Listening…").font(.callout).foregroundStyle(.tertiary)
    } else {
      (Text(model.committedText).foregroundStyle(.primary)
        + Text(model.committedText.isEmpty ? "" : " ")
        + Text(model.volatileText).foregroundStyle(.secondary))
        .font(.callout)
        .lineLimit(2)
        .truncationMode(.head)
    }
  }
}

struct WaveformBars: View {
  let levels: [Float]
  let frozen: Bool

  var body: some View {
    HStack(spacing: 2) {
      ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
        Capsule()
          .fill(frozen ? Color.secondary.opacity(0.4) : Color.accentColor)
          .frame(width: 2.5, height: CGFloat(4 + level * 18))
      }
    }
    .frame(height: 24)
    .animation(.linear(duration: 0.08), value: levels)
  }
}
