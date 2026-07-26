import AppKit
import SwiftUI

final class DictationOverlayModel: ObservableObject {
  enum Phase: Equatable {
    case listening
    case transcribing
    case error(String)
    case downloading(Int)
  }

  @Published var phase: Phase = .listening
  @Published var levels: [Float] = Array(repeating: 0, count: DictationOverlayModel.barCount)
  @Published var committedText: String = ""
  @Published var volatileText: String = ""
  // Changes per session so the view can drop layout state carried over from the
  // previous one.
  @Published var sessionID: Int = 0

  static let barCount = 28

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

  func show() {
    model.phase = .listening
    model.committedText = ""
    model.volatileText = ""
    model.sessionID &+= 1
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
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 170),
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
  @State private var textHeight: CGFloat = 0

  var body: some View {
    VStack {
      Spacer()
      content
        .frame(width: Self.capsuleWidth, height: capsuleHeight)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
          RoundedRectangle(cornerRadius: 20)
            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.32), radius: 18, y: 6)
        .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
      Spacer(minLength: 8)
    }
    .frame(maxWidth: .infinity)
    .animation(.easeInOut(duration: 0.15), value: model.phase)
  }

  static let capsuleWidth: CGFloat = 210

  private static let rowSpacing: CGFloat = 6
  private static let verticalPadding: CGFloat = 9
  private static let waveformHeight: CGFloat = 22

  private var capsuleHeight: CGFloat {
    transcriptHeight + Self.rowSpacing + Self.waveformHeight + Self.verticalPadding
  }

  @ViewBuilder
  private var content: some View {
    switch model.phase {
    case .listening, .transcribing:
      VStack(alignment: .leading, spacing: Self.rowSpacing) {
        transcriptText
        HStack(spacing: 8) {
          statusDot
          WaveformBars(levels: model.levels, frozen: model.phase == .transcribing)
            .frame(height: Self.waveformHeight)
        }
        .padding(.bottom, Self.verticalPadding)
      }
      .padding(.horizontal, 12)
    case .error(let message):
      centered {
        Circle().fill(.red).frame(width: 10, height: 10)
        Text(message)
          .font(.caption)
          .foregroundStyle(.primary)
          .lineLimit(2)
      }
    case .downloading(let percent):
      centered {
        ProgressView().controlSize(.small)
        Text("Downloading model… \(percent)%").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func centered<Content: View>(@ViewBuilder _ items: () -> Content) -> some View {
    HStack(spacing: 8, content: items)
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
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

  private static let transcriptLines: CGFloat = 3

  // Measured from the actual font; a hardcoded guess desynchronises the
  // overflow test from where the text really wraps.
  private static let transcriptLineHeight: CGFloat = {
    let font = NSFont.preferredFont(forTextStyle: .callout)
    return NSLayoutManager().defaultLineHeight(for: font).rounded(.up)
  }()

  // The transcript runs to the capsule's top edge so overflowing text fades
  // against the border instead of stopping short at a padded inset.
  private var transcriptHeight: CGFloat {
    Self.transcriptLineHeight * Self.transcriptLines + Self.verticalPadding
  }

  // Bottom-anchored rather than scrolled: the text is offset by however much it
  // overflows, so the newest line is in view on the same layout pass that grows
  // it. A ScrollViewProxy would scroll against the previous frame's geometry and
  // lag a line behind.
  private var transcriptText: some View {
    let visibleTextHeight = Self.transcriptLineHeight * Self.transcriptLines

    // fixedSize lets the text lay out every line at its natural height; without
    // it the enclosing frame constrains it and Text truncates with an ellipsis
    // instead of overflowing, so there is nothing to scroll.
    return transcriptContent
      .font(.callout)
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .background(
        GeometryReader { geo in
          Color.clear.preference(key: TranscriptHeightKey.self, value: geo.size.height)
        }
      )
      .offset(y: -max(0, textHeight - visibleTextHeight))
      .animation(.easeOut(duration: 0.12), value: textHeight)
      .frame(height: visibleTextHeight, alignment: .topLeading)
      .clipped()
      .padding(.top, Self.verticalPadding)
      .frame(height: transcriptHeight, alignment: .bottom)
      .mask(transcriptFade)
      .onPreferenceChange(TranscriptHeightKey.self) { textHeight = $0 }
      .onChange(of: model.sessionID) { textHeight = 0 }
  }

  private var transcriptContent: Text {
    let text = [model.committedText, model.volatileText]
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    if text.isEmpty {
      return Text("Listening…").foregroundStyle(.tertiary)
    }
    return Text(text).foregroundStyle(.primary)
  }

  // Only fade once text is actually scrolled out of view; a first line with
  // nothing above it must stay at full opacity. Compares against the text box
  // rather than transcriptHeight, which includes the top padding.
  private var isOverflowing: Bool {
    textHeight > Self.transcriptLineHeight * Self.transcriptLines + 1
  }

  @ViewBuilder
  private var transcriptFade: some View {
    if isOverflowing {
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0),
          .init(color: .black.opacity(0.5), location: 0.28),
          .init(color: .black, location: 0.62),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    } else {
      Color.black
    }
  }
}

private struct TranscriptHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

struct WaveformBars: View {
  let levels: [Float]
  let frozen: Bool

  var body: some View {
    GeometryReader { geo in
      let count = max(levels.count, 1)
      let spacing = max(geo.size.width / CGFloat(count) * 0.34, 1.5)
      let barWidth = max((geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count), 1)
      let minHeight = min(barWidth, geo.size.height)

      HStack(alignment: .center, spacing: spacing) {
        ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
          Capsule()
            .fill(frozen ? Color.secondary.opacity(0.4) : Color.accentColor)
            .frame(
              width: barWidth,
              height: minHeight + CGFloat(level) * (geo.size.height - minHeight))
        }
      }
      .frame(width: geo.size.width, height: geo.size.height)
    }
    .animation(.linear(duration: 0.08), value: levels)
  }
}
