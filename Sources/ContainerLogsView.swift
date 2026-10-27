import SwiftUI

/// The container a logs window shows. Windows are keyed by it, so asking for the same
/// container's logs again brings its window forward instead of opening another.
struct ContainerLogsTarget: Codable, Hashable {
  let id: String
  let name: String
}

struct ContainerLogsView: View {
  let target: ContainerLogsTarget

  @State private var logs: Result<String, any Error>?
  @State private var isLoading = false

  @Environment(\.appearsActive) private var appearsActive

  private let client = DockerClient()

  var body: some View {
    content
      .frame(minWidth: 480, minHeight: 240)
      .navigationTitle(target.name)
      .navigationSubtitle("Last \(DockerClient.logLineLimit) lines")
      .toolbar {
        Button {
          Task { await load() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r")
        .disabled(isLoading)
      }
      .task {
        await load()
      }
      // Show Logs on a container whose window is already open only brings it forward, so
      // reload whenever the window comes back, rather than showing lines from when it opened.
      .onChange(of: appearsActive) { _, isActive in
        if isActive {
          Task { await load() }
        }
      }
  }

  @ViewBuilder
  private var content: some View {
    switch logs {
    case nil:
      ProgressView()
    case .failure(let error):
      ContentUnavailableView {
        Label("Logs Unavailable", systemImage: "exclamationmark.triangle")
      } description: {
        Text(error.localizedDescription)
          .textSelection(.enabled)
      }
    case .success(let text) where text.isEmpty:
      ContentUnavailableView(
        "No Logs", systemImage: "text.alignleft",
        description: Text("This container hasn't written any output."))
    case .success(let text):
      ScrollView {
        Text(verbatim: text)
          .font(.body.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
      }
      // Opens on the newest lines, where a failure usually explains itself.
      .defaultScrollAnchor(.bottom)
    }
  }

  private func load() async {
    guard !isLoading else {
      return
    }

    isLoading = true
    defer { isLoading = false }

    do {
      logs = .success(try await client.loadLogs(of: target.id))
    } catch is CancellationError {
      // Closing the window cancels the load; there is nothing left to show it in.
      return
    } catch {
      logs = .failure(error)
    }
  }
}
