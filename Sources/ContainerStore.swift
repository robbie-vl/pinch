import Foundation
import Observation

@MainActor
@Observable
final class ContainerStore {
  private(set) var snapshot: ContainerSnapshot?
  private(set) var activeContainerID: String?
  private(set) var runtimeTransition: RuntimeTransition?
  /// The last refresh failed. The next successful refresh clears it.
  private(set) var refreshError: String?
  /// A command the user ran failed. It stays until dismissed or the next command, so a
  /// background refresh can't hide it before it's read.
  private(set) var actionError: String?
  /// CPU and memory per running container, keyed by name. Kept when the popover closes, so it
  /// reopens with the last figures instead of blank columns.
  private(set) var usage: [String: ContainerUsage] = [:]
  /// `usage` comes from a sample taken since the popover opened. False while it still shows the
  /// figures from the last time it was open.
  private(set) var isUsageLive = false

  private var refreshTask: Task<Void, Never>?
  private let client: DockerClient

  init(client: DockerClient = DockerClient()) {
    self.client = client
  }

  var isRefreshing: Bool {
    refreshTask != nil
  }

  /// A command is running; the UI disables the other controls rather than queueing clicks.
  var isBusy: Bool {
    activeContainerID != nil || runtimeTransition != nil
  }

  func poll() async {
    await refresh()
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: .seconds(5))
      } catch {
        return
      }
      await refresh()
    }
  }

  /// Samples container usage back to back while the popover is open. Each sample takes about
  /// two seconds, so this runs beside `poll()` rather than slowing the list refresh.
  func watchUsage() async {
    defer { isUsageLive = false }
    while !Task.isCancelled {
      if snapshot?.runtime.state == .running, runtimeTransition == nil {
        // Supplementary: the list refresh already reports Docker failures, so a failed sample
        // clears the numbers instead of raising a second error.
        let sample = try? await client.loadUsage()
        guard !Task.isCancelled else { return }
        usage = sample ?? [:]
        isUsageLive = sample != nil
      } else {
        usage = [:]
      }
      do {
        try await Task.sleep(for: .seconds(1))
      } catch {
        return
      }
    }
  }

  /// Joins a refresh already in flight rather than starting a second one, so a manual refresh
  /// always waits for current data.
  func refresh() async {
    // The running command reloads the snapshot itself when it finishes.
    guard !isBusy else {
      return
    }
    if let refreshTask {
      await refreshTask.value
      return
    }

    let task = Task { await load() }
    refreshTask = task
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    refreshTask = nil
  }

  func toggleRuntime() async {
    guard !isBusy, let shownState = snapshot?.runtime.state else {
      return
    }

    let shouldRun = shownState == .stopped
    runtimeTransition = shouldRun ? .starting : .stopping
    actionError = nil
    defer { runtimeTransition = nil }

    // The popover may be showing the snapshot from when it last closed.
    await refreshTask?.value
    guard snapshot?.runtime.state == shownState else {
      return
    }

    do {
      try await client.setRuntimeRunning(shouldRun)
    } catch {
      actionError = error.localizedDescription
    }
    await load()
  }

  func perform(_ action: ContainerAction, on container: ContainerInfo) async {
    guard !isBusy else {
      return
    }

    activeContainerID = container.id
    actionError = nil
    defer { activeContainerID = nil }

    // The row may come from the snapshot taken when the popover last closed. Let the opening
    // refresh land, and skip the command if the container has changed since.
    await refreshTask?.value
    guard snapshot?.containers.first(where: { $0.id == container.id })?.state == container.state
    else {
      return
    }

    do {
      try await client.perform(action, on: container.id)
    } catch {
      actionError = error.localizedDescription
    }
    await load()
  }

  func dismissActionError() {
    actionError = nil
  }

  private func load() async {
    do {
      snapshot = try await client.loadSnapshot()
      refreshError = nil
    } catch is CancellationError {
      // Closing the popover cancels its refresh without replacing the last snapshot or error.
      return
    } catch {
      refreshError = error.localizedDescription
    }
  }
}
