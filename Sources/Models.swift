import Foundation

struct ContainerSnapshot: Equatable, Sendable {
  let runtime: RuntimeInfo
  let projects: [ContainerProject]

  var containers: [ContainerInfo] {
    projects.flatMap(\.containers)
  }
}

struct RuntimeInfo: Equatable, Sendable {
  enum State: Equatable, Sendable {
    case running
    case stopped
  }

  let state: State
  /// The VM's configured allocation. Colima omits these when Lima has not reported them.
  let cpus: Int?
  let memoryBytes: Int64?
  /// Memory the VM's kernel can't hand to new work, so including Docker's own daemons, not
  /// just the containers. Nil while the VM is stopped.
  let memoryUsedBytes: Int64?
  let engineVersion: String?

  /// No default Colima profile exists yet, so there is nothing to describe.
  static let notCreated = RuntimeInfo(
    state: .stopped, cpus: nil, memoryBytes: nil, memoryUsedBytes: nil, engineVersion: nil)

  var stateLabel: String {
    state == .running ? "Running" : "Stopped"
  }

  /// The allocation in Colima's units, or nil while Colima doesn't report it, as before the VM's
  /// first start.
  var resources: RuntimeResources? {
    guard let cpus, let memoryBytes else {
      return nil
    }
    return RuntimeResources(
      cpus: cpus, memoryGiB: Double(memoryBytes) / Double(RuntimeResources.bytesPerGiB))
  }

  /// Allocation and engine facts, without the state, so the UI can lead with a transition
  /// such as "Starting…" instead.
  var details: [String] {
    var parts: [String] = []
    if let cpus {
      parts.append("\(cpus) CPU\(cpus == 1 ? "" : "s")")
    }
    switch (memoryUsedBytes, memoryBytes) {
    case (let used?, let total?):
      parts.append("\(Self.bytes(used)) of \(Self.bytes(total))")
    case (let used?, nil):
      parts.append("\(Self.bytes(used)) used")
    case (nil, let total?):
      parts.append(Self.bytes(total))
    case (nil, nil):
      break
    }
    if let engineVersion {
      parts.append("Docker \(engineVersion)")
    }
    return parts
  }

  private static func bytes(_ count: Int64) -> String {
    count.formatted(.byteCount(style: .memory))
  }
}

/// The CPUs and memory Colima gives the VM, in the units its `start` flags take. Memory can be
/// a fraction of a GiB, such as 1.5.
struct RuntimeResources: Equatable, Sendable {
  var cpus: Int
  var memoryGiB: Double

  static let bytesPerGiB: Int64 = 1 << 30

  var memoryLabel: String {
    Int64((memoryGiB * Double(Self.bytesPerGiB)).rounded()).formatted(.byteCount(style: .memory))
  }

  /// The next whole GiB up, so a fractional allocation such as 1.5 GiB steps to 2.
  var memoryGiBAbove: Double {
    (memoryGiB + 1).rounded(.down)
  }

  /// The next whole GiB down, so a fractional allocation such as 1.5 GiB steps to 1.
  var memoryGiBBelow: Double {
    (memoryGiB - 1).rounded(.up)
  }
}

/// A container's live resource use, sampled by `docker stats`.
struct ContainerUsage: Equatable, Sendable {
  /// Docker's measure, where 100% is one full CPU core, so a busy container can exceed 100%.
  let cpuPercent: Double
  let memoryBytes: Int64

  var cpuLabel: String {
    // One decimal place for light loads, where the difference between 0.1% and 0.9% matters.
    (cpuPercent / 100).formatted(.percent.precision(.fractionLength(cpuPercent < 10 ? 1 : 0)))
  }

  var memoryLabel: String {
    memoryBytes.formatted(.byteCount(style: .memory))
  }
}

enum RuntimeTransition: Equatable, Sendable {
  case starting
  case stopping

  var label: String {
    switch self {
    case .starting: "Starting…"
    case .stopping: "Stopping…"
    }
  }
}

struct ContainerProject: Equatable, Identifiable, Sendable {
  let name: String
  let containers: [ContainerInfo]

  var id: String { name }

  /// Each container counts in exactly one group, so the numbers add up to the project's size.
  var summary: String {
    ContainerState.SummaryGroup.allCases
      .compactMap { group in
        let count = containers.count(where: { $0.state.summaryGroup == group })
        return count > 0 ? group.label(count: count) : nil
      }
      .joined(separator: " · ")
  }
}

struct ContainerInfo: Equatable, Identifiable, Sendable {
  let id: String
  let name: String
  let project: String
  /// The Compose service, or the container name for standalone containers and for
  /// replicas, which would otherwise share one service name.
  let displayName: String
  let ports: [PublishedPort]
  let state: ContainerState
  /// The code of the last exit, for containers Docker reports as exited or restarting.
  let exitCode: Int?
  /// Times the restart policy has brought the container back since it was last started by hand.
  let restartCount: Int
  let startedAt: Date?
  let finishedAt: Date?

  var portSummary: String? {
    ports.isEmpty ? nil : ports.map(\.label).joined(separator: ", ")
  }

  /// What the row says about the container, as separate parts so the UI can space them like
  /// the figures beside them: how long a running container has been up, when a stopped one
  /// stopped, the state wherever the dot can't say it alone, and the exit code behind a failure.
  func activity(at now: Date) -> [String] {
    switch state {
    case .healthy, .running:
      [startedAt.map { "up \(Self.age(since: $0, now: now))" }].compactMap(\.self)
    case .unhealthy:
      [state.label, startedAt.map { "up \(Self.age(since: $0, now: now))" }].compactMap(\.self)
    case .restarted:
      [
        "\(restartCount) restart\(restartCount == 1 ? "" : "s")",
        startedAt.map { "up \(Self.age(since: $0, now: now))" },
      ].compactMap(\.self)
    case .restarting:
      [state.label, exitCodeLabel].compactMap(\.self)
    case .starting, .paused, .created:
      [state.label]
    case .exited, .outOfMemory:
      [stoppedLabel(at: now)]
    case .failed:
      [stoppedLabel(at: now), exitCodeLabel].compactMap(\.self)
    }
  }

  /// The state and how long ago the container stopped, as in "failed 2d ago".
  private func stoppedLabel(at now: Date) -> String {
    [state.label, finishedAt.map { "\(Self.age(since: $0, now: now)) ago" }]
      .compactMap(\.self)
      .joined(separator: " ")
  }

  private var exitCodeLabel: String? {
    exitCode.map { "exit code \($0)" }
  }

  /// One unit, narrow, as in "3h" or "50m". A clock that runs ahead of Docker's reads as zero.
  private static func age(since date: Date, now: Date) -> String {
    Duration.seconds(max(0, now.timeIntervalSince(date)))
      .formatted(
        .units(
          allowed: [.days, .hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 1))
  }
}

/// A host port, or a contiguous range of them, published by one container binding.
struct PublishedPort: Hashable, Sendable {
  let range: ClosedRange<Int>

  var label: String {
    range.count == 1 ? "\(range.lowerBound)" : "\(range.lowerBound)–\(range.upperBound)"
  }

  /// The first `limit` bindings, then a count of the ports left over, as in "8080, 8443 +3".
  /// Ranges count by the ports they cover, matching the menu, which lists each port.
  static func summary(_ ports: [PublishedPort], limit: Int) -> String {
    let shown = ports.prefix(limit).map(\.label).joined(separator: ", ")
    let hidden = ports.dropFirst(limit).reduce(0) { $0 + $1.range.count }
    return hidden == 0 ? shown : "\(shown) +\(hidden)"
  }
}

enum ContainerState: Equatable, Sendable {
  case healthy
  case running
  case starting
  case restarting
  /// Running again after its restart policy brought it back from an exit.
  case restarted
  case unhealthy
  case paused
  /// Created but never started.
  case created
  /// Stopped normally: a clean exit, or the signal `docker stop` sends.
  case exited
  /// Exited with an error code.
  case failed
  case outOfMemory

  enum SummaryGroup: CaseIterable {
    case running
    case paused
    case stopped
    case issue

    func label(count: Int) -> String {
      switch self {
      case .running: "\(count) running"
      case .paused: "\(count) paused"
      case .stopped: "\(count) stopped"
      case .issue: "\(count) issue\(count == 1 ? "" : "s")"
      }
    }
  }

  var isRunning: Bool {
    switch self {
    case .healthy, .running, .starting, .restarting, .restarted, .unhealthy:
      true
    case .paused, .created, .exited, .failed, .outOfMemory:
      false
    }
  }

  var summaryGroup: SummaryGroup {
    switch self {
    case .healthy, .running, .starting:
      .running
    case .paused:
      .paused
    case .created, .exited:
      .stopped
    // Docker reports a container as restarting only while its restart policy brings it back
    // after an exit, so it is crashing, or exiting when it is meant to keep running.
    case .unhealthy, .restarting, .restarted, .failed, .outOfMemory:
      .issue
    }
  }

  var label: String {
    switch self {
    case .healthy: "healthy"
    case .running: "running"
    case .starting: "starting"
    case .restarting: "restarting"
    case .restarted: "restarted"
    case .unhealthy: "unhealthy"
    case .paused: "paused"
    case .created: "created"
    case .exited: "stopped"
    case .failed: "failed"
    case .outOfMemory: "out of memory"
    }
  }
}

enum ContainerAction: String, Sendable {
  case start
  case stop
  case restart
  case pause
  case unpause
}
