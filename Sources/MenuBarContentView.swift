import AppKit
import SwiftUI

struct MenuBarContentView: View {
  @Bindable var store: ContainerStore

  @State private var isRefreshingManually = false

  /// The space between the rules and the content between them. The project rows after the top
  /// rule are 24pt tall with their text set about 7pt in, hence the shorter top inset. The list
  /// keeps it inside its scroll view, so it scrolls right up to the rules.
  private static let contentInsets = EdgeInsets(top: 4, leading: 0, bottom: 10, trailing: 0)

  var body: some View {
    VStack(spacing: 0) {
      header

      if let actionError = store.actionError {
        errorView(actionError, onDismiss: store.dismissActionError)
      }
      if let refreshError = store.refreshError {
        errorView(refreshError, onDismiss: nil)
      }

      SectionDivider()
        .padding(.top, 10)
      containerContent
      SectionDivider()
        .padding(.bottom, 4)
      footer
    }
    .frame(width: 440)
    .task {
      await store.poll()
    }
    .task {
      await store.watchUsage()
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Text("Colima")
          .font(.title3.weight(.semibold))

        Spacer(minLength: 8)

        if let runtime = store.snapshot?.runtime {
          RuntimeToggle(
            isRunning: runtime.state == .running,
            transition: store.runtimeTransition,
            action: { Task { await store.toggleRuntime() } }
          )
          // Not disabled for polls: they are short, the store waits for them, and disabling on
          // every one makes the pill flicker.
          .disabled(store.isBusy)
        }
      }
      // The pill's height, so the header doesn't grow when the pill appears after loading.
      .frame(height: 24)

      // Full width below the controls so the allocation summary never wraps.
      runtimeLine
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 14)
    .padding(.top, 10)
  }

  @ViewBuilder
  private var runtimeLine: some View {
    if let runtime = store.snapshot?.runtime {
      HStack(spacing: 5) {
        StatusDot(state: runtimeDotState(runtime))
        Text(
          ([store.runtimeTransition?.label ?? runtime.stateLabel] + runtime.details)
            .joined(separator: " · ")
        )
      }
    } else {
      // Without a snapshot, the only alternative to loading is a failure shown above. The dot
      // holds the text where it sits once loaded.
      HStack(spacing: 5) {
        StatusDot(state: store.isRefreshing ? .exited : .failed)
        Text(store.isRefreshing ? "Connecting…" : "Unavailable")
      }
    }
  }

  private func runtimeDotState(_ runtime: RuntimeInfo) -> ContainerState {
    if store.runtimeTransition != nil {
      return .starting
    }
    return runtime.state == .running ? .healthy : .exited
  }

  @ViewBuilder
  private var containerContent: some View {
    if let snapshot = store.snapshot {
      if store.runtimeTransition == .starting {
        emptyState(
          title: "Starting Colima…",
          detail: "This can take a minute."
        ) {
          ScuttlingCrab()
        }
      } else if snapshot.runtime.state == .stopped {
        emptyState(
          title: "Colima is stopped",
          detail: "Start Colima to see its containers."
        )
      } else if snapshot.projects.isEmpty {
        emptyState(
          title: "No containers",
          detail: "Containers you create with Docker or Compose appear here."
        )
      } else {
        // Sized to the content, so collapsing a project shrinks the popover, up to a cap
        // beyond which the list scrolls.
        ScrollView {
          projectList(snapshot)
            .padding(Self.contentInsets)
        }
        .scrollBounceBehavior(.basedOnSize)
        .modifier(ScrollEdgeFade())
        .frame(maxHeight: 560)
        .fixedSize(horizontal: false, vertical: true)
      }
    } else if store.isRefreshing {
      emptyState(
        title: "Coming out of its shell…",
        detail: "Checking on Colima and your containers."
      ) {
        ScuttlingCrab()
      }
    } else {
      emptyState(
        title: "Container status unavailable",
        detail: "Refresh to try again."
      )
    }
  }

  private func projectList(_ snapshot: ContainerSnapshot) -> some View {
    GlassEffectContainer(spacing: 10) {
      VStack(spacing: 10) {
        ForEach(snapshot.projects) { project in
          ProjectSection(
            project: project,
            activeContainerID: store.activeContainerID,
            usage: store.usage,
            isUsageLive: store.isUsageLive,
            actionsEnabled: !store.isBusy,
            onAction: { action, container in
              Task { await store.perform(action, on: container) }
            }
          )
        }
      }
    }
    .padding(.horizontal, 10)
  }

  private func errorView(_ message: String, onDismiss: (() -> Void)?) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.callout)
        .foregroundStyle(.red)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Error: \(message)")

      if let onDismiss {
        Button(action: onDismiss) {
          Image(systemName: "xmark")
        }
        .buttonStyle(IconButtonStyle(size: 20))
        .help("Dismiss")
        .accessibilityLabel("Dismiss error")
      }
    }
    .padding(.horizontal, 14)
    .padding(.top, 10)
  }

  private func emptyState(title: String, detail: String) -> some View {
    emptyState(title: title, detail: detail) {
      PeekingCrab()
    }
  }

  private func emptyState(
    title: String,
    detail: String,
    @ViewBuilder glyph: () -> some View
  ) -> some View {
    VStack(spacing: 6) {
      glyph()
        .frame(width: 34, height: 34)
        .padding(.bottom, 4)
        .accessibilityHidden(true)
      Text(title)
        .font(.body.weight(.medium))
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 24)
    .padding(.vertical, 22)
    .padding(Self.contentInsets)
  }

  private var footer: some View {
    VStack(spacing: 0) {
      Button {
        Task {
          isRefreshingManually = true
          await store.refresh()
          isRefreshingManually = false
        }
      } label: {
        HStack {
          Text("Refresh")
          Spacer()
          if isRefreshingManually {
            ProgressView()
              .controlSize(.mini)
          } else {
            Text("⌘R")
              .foregroundStyle(.tertiary)
              .accessibilityHidden(true)
          }
        }
      }
      .buttonStyle(MenuRowButtonStyle())
      .keyboardShortcut("r")
      .disabled(store.isBusy || isRefreshingManually)

      SettingsLink {
        HStack {
          Text("Settings…")
          Spacer()
          Text("⌘,")
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
      }
      .buttonStyle(MenuRowButtonStyle())
      .keyboardShortcut(",")

      Button {
        NSApplication.shared.terminate(nil)
      } label: {
        HStack {
          Text("Quit")
          Spacer()
          Text("⌘Q")
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
      }
      .buttonStyle(MenuRowButtonStyle())
      .keyboardShortcut("q")
    }
    .padding(.horizontal, 5)
    .padding(.bottom, 5)
  }
}

/// The rule between the header, the container list and the footer.
private struct SectionDivider: View {
  var body: some View {
    Divider()
      // The text edge shared by the header, project names and footer rows.
      .padding(.horizontal, 14)
  }
}

/// Fades a scroll view's content out at each edge with more beyond it, so a row cut off at the
/// edge reads as "keep scrolling" rather than a hard clip. The fade stays inside the scroll view:
/// the header and footer around it stay clean.
struct ScrollEdgeFade: ViewModifier {
  @State private var fadedEdges: Edge.Set = []

  private let fadeHeight: CGFloat = 36

  func body(content: Content) -> some View {
    content
      .onScrollGeometryChange(for: Edge.Set.self, of: Self.fadedEdges) { _, edges in
        fadedEdges = edges
      }
      .mask {
        VStack(spacing: 0) {
          LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
            .frame(height: fadedEdges.contains(.top) ? fadeHeight : 0)
          Rectangle()
          LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: fadedEdges.contains(.bottom) ? fadeHeight : 0)
        }
        .animation(.easeOut(duration: 0.15), value: fadedEdges)
      }
  }

  /// The edges with content beyond them. Scrolling to an end can settle a hair short of it, so
  /// anything under half a point, less than a pixel on any display, doesn't count.
  static func fadedEdges(for geometry: ScrollGeometry) -> Edge.Set {
    let tolerance: CGFloat = 0.5
    var edges: Edge.Set = []
    if geometry.visibleRect.minY > tolerance {
      edges.insert(.top)
    }
    if geometry.visibleRect.maxY < geometry.contentSize.height - tolerance {
      edges.insert(.bottom)
    }
    return edges
  }
}

private struct RuntimeToggle: View {
  let isRunning: Bool
  let transition: RuntimeTransition?
  let action: () -> Void

  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        if transition != nil {
          ProgressView()
            .controlSize(.mini)
        } else {
          Image(systemName: isRunning ? "stop.fill" : "play.fill")
            .font(.system(size: 9, weight: .bold))
        }
        Text(transition?.label ?? (isRunning ? "Stop" : "Start"))
      }
      .font(.callout.weight(.semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, 9)
      .frame(height: 24)
      .background(tint.opacity(0.15), in: Capsule())
      .contentShape(Capsule())
      // The pill stays at full strength while it shows its own transition, and dims while
      // another command is running.
      .opacity(isEnabled || transition != nil ? 1 : 0.4)
    }
    .buttonStyle(.plain)
    .help(isRunning ? "Stop Colima" : "Start Colima")
  }

  private var tint: Color {
    switch transition {
    case .starting: .green
    case .stopping: .red
    case nil: isRunning ? .red : .green
    }
  }
}

private struct ProjectSection: View {
  let project: ContainerProject
  let activeContainerID: String?
  let usage: [String: ContainerUsage]
  let isUsageLive: Bool
  let actionsEnabled: Bool
  let onAction: (ContainerAction, ContainerInfo) -> Void

  @State private var isExpanded = true
  @State private var isHeaderHovered = false

  var body: some View {
    VStack(spacing: 4) {
      Button {
        withAnimation(.snappy(duration: 0.2)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 6) {
          Text(project.name)
            .font(.body.weight(.semibold))
          Spacer()
          if isExpanded {
            Text(project.summary)
              .font(.callout)
              .foregroundStyle(.secondary)
          } else {
            // Collapsed groups keep the at-a-glance status of every container.
            StatusStrip(containers: project.containers)
          }
          // Trailing, as on macOS sidebar sections: a chevron straight after the name reads as
          // a pop-up menu.
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(isHeaderHovered ? .secondary : .tertiary)
            .rotationEffect(isExpanded ? .degrees(90) : .zero)
            .frame(width: 12)
        }
        .padding(.horizontal, 4)
        .frame(height: 24)
        .contentShape(.rect)
        .onHover { isHeaderHovered = $0 }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(project.name), \(project.summary)")
      .accessibilityHint(isExpanded ? "Collapse" : "Expand")

      if isExpanded {
        VStack(spacing: 0) {
          ForEach(project.containers) { container in
            ContainerRow(
              container: container,
              isBusy: activeContainerID == container.id,
              usage: usage[container.name],
              isUsageLive: isUsageLive,
              actionsEnabled: actionsEnabled,
              onAction: { action in onAction(action, container) }
            )
          }
        }
        .padding(4)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
      }
    }
  }
}

private struct StatusStrip: View {
  let containers: [ContainerInfo]

  private let limit = 10

  var body: some View {
    HStack(spacing: 3) {
      ForEach(containers.prefix(limit)) { container in
        StatusDot(state: container.state)
      }
      if containers.count > limit {
        Text("+\(containers.count - limit)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct ContainerRow: View {
  let container: ContainerInfo
  let isBusy: Bool
  let usage: ContainerUsage?
  let isUsageLive: Bool
  let actionsEnabled: Bool
  let onAction: (ContainerAction) -> Void

  /// Lines up the detail line with the name: the dot's width plus the gap after it.
  private static let detailIndent: CGFloat = 15

  /// Two lines, so nothing has to be hidden: the name and its controls, then how the container
  /// is doing. Each line has the full row width to itself.
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        StatusDot(state: container.state)

        Text(container.displayName)
          .font(.body)
          .lineLimit(1)
          .truncationMode(.middle)

        Spacer(minLength: 6)

        ContainerActionRail(
          state: container.state,
          isBusy: isBusy,
          onAction: onAction
        )
        // Only container commands wait for a running one; the port menu stays usable.
        .disabled(!actionsEnabled)
      }
      .frame(height: 24)

      // One left-to-right line, read under the name, so nothing floats across empty space.
      HStack(spacing: 6) {
        // Ticks every second so a container that just started counts up; rows whose text
        // hasn't changed don't redraw.
        TimelineView(.periodic(from: .now, by: 1)) { context in
          HStack(spacing: 6) {
            ForEach(Array(detailParts(at: context.date).enumerated()), id: \.offset) {
              index, part in
              if index > 0 {
                DetailSeparator()
              }
              switch part {
              case .text(let text):
                Text(text)
              case .figure(let label, let value):
                UsageFigure(label: label, value: value, isLive: isUsageLive)
              case .ports:
                PortMenu(ports: container.ports)
              }
            }
          }
          // Its natural width: the longest line fits the row, and the port menu otherwise
          // under-reports its width and squeezes the labels beside it.
          .fixedSize()
        }

        Spacer(minLength: 0)
      }
      .font(.subheadline)
      .monospacedDigit()
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .frame(height: 18)
      .padding(.leading, Self.detailIndent)
    }
    .padding(.leading, 8)
    .padding(.trailing, 2)
    .padding(.vertical, 3)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityLabel)
  }

  private enum DetailPart {
    case text(String)
    case figure(label: String, value: String?)
    case ports
  }

  private func detailParts(at now: Date) -> [DetailPart] {
    var parts = container.activity(at: now).map(DetailPart.text)
    if container.state.isRunning {
      parts += [
        .figure(label: "CPU", value: usage?.cpuLabel),
        .figure(label: "Memory", value: usage?.memoryLabel),
      ]
    }
    if !container.ports.isEmpty {
      parts.append(.ports)
    }
    return parts
  }

  private var accessibilityLabel: String {
    let parts = container.activity(at: .now)
    let activity = parts.isEmpty ? container.state.label : parts.joined(separator: ", ")
    let usage = usage.map { ", CPU \($0.cpuLabel), memory \($0.memoryLabel)" } ?? ""
    let port = container.portSummary.map { ", port \($0)" } ?? ""
    return "\(container.displayName), \(activity)\(usage)\(port)"
  }
}

private struct DetailSeparator: View {
  var body: some View {
    Text("·")
      .foregroundStyle(.tertiary)
      .accessibilityHidden(true)
  }
}

/// A labelled figure such as "CPU 2.2%". The label is a shade lighter so the eye lands on the
/// number. Until the first sample the value reads "–", which holds roughly the figure's place;
/// figures from the last time the popover was open show dimmed until the first fresh sample,
/// which takes about two seconds.
private struct UsageFigure: View {
  let label: String
  let value: String?
  let isLive: Bool

  var body: some View {
    HStack(spacing: 3) {
      Text(label)
        .foregroundStyle(.tertiary)
      Text(value ?? "–")
        .foregroundStyle(isLive ? .secondary : .quaternary)
        .animation(.easeOut(duration: 0.3), value: isLive)
    }
    .accessibilityHidden(true)
  }
}

/// Published ports, labelled like the figures beside them. The number is drawn in the accent
/// colour, the way macOS marks clickable text, and opens a menu to copy or open each address.
private struct PortMenu: View {
  let ports: [PublishedPort]

  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 3) {
      Text(hostPorts.count == 1 ? "Port" : "Ports")
        .foregroundStyle(.tertiary)

      Menu {
        ForEach(hostPorts, id: \.self) { port in
          // Verbatim: a number interpolated into a localized string is formatted as one,
          // which turns 5432 into "5,432".
          Section {
            Button("Copy Address") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(Self.address(port), forType: .string)
            }
            if let url = URL(string: "http://\(Self.address(port))") {
              Button("Open in Browser") {
                NSWorkspace.shared.open(url)
              }
            }
          } header: {
            Text(verbatim: Self.address(port))
          }
        }
      } label: {
        // Two bindings is what fits beside the other figures; the menu lists every port.
        Text(verbatim: PublishedPort.summary(ports, limit: 2))
          .foregroundStyle(.tint)
          .underline(isHovered)
          .onHover { isHovered = $0 }
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .pointerStyle(.link)
      .help("Copy or open this address")
      .accessibilityLabel("Port \(ports.map(\.label).joined(separator: ", "))")
    }
  }

  /// Every host port, with ranges expanded: each port in a range is usually its own service.
  private var hostPorts: [Int] {
    Array(Set(ports.flatMap(\.range))).sorted()
  }

  private static func address(_ port: Int) -> String {
    "localhost:\(port)"
  }
}

/// Three fixed slots — pause/resume, restart, start/stop — so each action sits in the same
/// column on every row and the rails read as one aligned group down the card.
private struct ContainerActionRail: View {
  let state: ContainerState
  let isBusy: Bool
  let onAction: (ContainerAction) -> Void

  var body: some View {
    HStack(spacing: 0) {
      if isBusy {
        ProgressView()
          .controlSize(.mini)
          .frame(maxWidth: .infinity)
      } else {
        slot(suspendAction)
        slot(state.isRunning ? .restart : nil)
        slot(state.isRunning || state == .paused ? .stop : .start)
      }
    }
    .frame(width: 72)
  }

  private var suspendAction: ContainerAction? {
    switch state {
    case .healthy, .running, .starting, .unhealthy:
      .pause
    case .paused:
      .unpause
    case .restarting, .created, .exited, .failed, .outOfMemory:
      nil
    }
  }

  @ViewBuilder
  private func slot(_ action: ContainerAction?) -> some View {
    if let action {
      Button {
        onAction(action)
      } label: {
        Image(systemName: action.systemImage)
      }
      .buttonStyle(IconButtonStyle(size: 24))
      .help(action.label)
      .accessibilityLabel(action.label)
    } else {
      Color.clear
        .frame(width: 24, height: 24)
    }
  }
}

private struct StatusDot: View {
  let state: ContainerState

  var body: some View {
    Group {
      if state.isRunning || state == .paused {
        Circle().fill(color)
      } else {
        // Not running: a ring, so "stopped" and "finished" read differently from "up".
        Circle().strokeBorder(color, lineWidth: 1.5)
      }
    }
    .frame(width: 7, height: 7)
    .accessibilityHidden(true)
  }

  private var color: Color {
    switch state {
    case .healthy, .running:
      .green
    case .starting, .restarting:
      .orange
    case .unhealthy, .failed, .outOfMemory:
      .red
    case .paused, .created, .exited:
      .secondary
    }
  }
}

/// The busy crab, shown while Pinch loads or Colima starts: a few quick sideways steps, a
/// pause, and back, the way a hermit crab tests the water before leaving its shell.
private struct ScuttlingCrab: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let crab = HermitGlyph().fill(.secondary)
    if reduceMotion {
      crab
    } else {
      crab.keyframeAnimator(initialValue: CGFloat(0), repeating: true) { content, x in
        // Steps are 2pt, and the lift peaks halfway through each, so the crab hops once a step.
        content.offset(x: x, y: -abs(sin(.pi * x / 2)))
      } keyframes: { _ in
        KeyframeTrack {
          LinearKeyframe(0, duration: 0.6)
          CubicKeyframe(-2, duration: 0.12)
          CubicKeyframe(-4, duration: 0.12)
          LinearKeyframe(-4, duration: 0.56)
          CubicKeyframe(-2, duration: 0.12)
          CubicKeyframe(0, duration: 0.12)
          CubicKeyframe(2, duration: 0.12)
          CubicKeyframe(4, duration: 0.12)
          LinearKeyframe(4, duration: 0.52)
          CubicKeyframe(2, duration: 0.12)
          CubicKeyframe(0, duration: 0.12)
        }
      }
    }
  }
}

/// The resting crab, for empty states: every few seconds it ducks into its shell and peeks
/// back out. Dimmer and mostly still, so it never reads as the busy crab's scuttle.
private struct PeekingCrab: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if reduceMotion {
      HermitGlyph().fill(.quaternary)
    } else {
      KeyframeAnimator(initialValue: CGFloat(0), repeating: true) { retraction in
        HermitGlyph(retraction: retraction).fill(.quaternary)
      } keyframes: { _ in
        KeyframeTrack {
          // Out first, so the popover doesn't open on a moving crab.
          LinearKeyframe(0, duration: 4)
          CubicKeyframe(1, duration: 0.2)
          LinearKeyframe(1, duration: 0.8)
          // Halfway up for a cautious look, then all the way out.
          CubicKeyframe(0.45, duration: 0.3)
          LinearKeyframe(0.45, duration: 0.6)
          CubicKeyframe(0, duration: 0.25)
        }
      }
    }
  }
}

/// A borderless symbol button that shows a soft highlight on hover, like toolbar controls.
private struct IconButtonStyle: ButtonStyle {
  let size: CGFloat

  func makeBody(configuration: Configuration) -> some View {
    IconButtonBody(configuration: configuration, size: size)
  }

  private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
      configuration.label
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(isHovered ? .primary : .secondary)
        .frame(width: size, height: size)
        .background(
          Color.primary.opacity(configuration.isPressed ? 0.14 : isHovered ? 0.08 : 0),
          in: Circle()
        )
        .contentShape(Circle())
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovered = $0 && isEnabled }
    }
  }
}

/// A full-width row that highlights in the accent colour, like a native menu item.
private struct MenuRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    MenuRowBody(configuration: configuration)
  }

  private struct MenuRowBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
      configuration.label
        .font(.body)
        // Hierarchical styles inside the label (the dimmed shortcut) derive from this, so they
        // turn white with the title, as in system menus.
        .foregroundStyle(foreground)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(isHighlighted ? Color.accentColor : .clear, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .onHover { isHovered = $0 }
    }

    /// Disabled items don't highlight, as in system menus.
    private var isHighlighted: Bool {
      isHovered && isEnabled
    }

    private var foreground: AnyShapeStyle {
      if !isEnabled {
        return AnyShapeStyle(.tertiary)
      }
      return isHighlighted
        ? AnyShapeStyle(Color(nsColor: .selectedMenuItemTextColor)) : AnyShapeStyle(.primary)
    }
  }
}

extension ContainerAction {
  fileprivate var label: String {
    switch self {
    case .start: "Start"
    case .stop: "Stop"
    case .restart: "Restart"
    case .pause: "Pause"
    case .unpause: "Resume"
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .start, .unpause: "play.fill"
    case .stop: "stop.fill"
    case .restart: "arrow.clockwise"
    case .pause: "pause.fill"
    }
  }
}
