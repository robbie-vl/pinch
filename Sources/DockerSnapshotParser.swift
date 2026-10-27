import Foundation

struct DockerSnapshotParser: Sendable {
  func parse(_ output: String) throws -> [DockerContainerRecord] {
    try output
      .split(whereSeparator: \.isNewline)
      .enumerated()
      .map { index, line in
        do {
          let raw = try JSONDecoder().decode(RawContainerLine.self, from: Data(line.utf8))
          return try DockerContainerRecord(raw)
        } catch {
          throw DockerSnapshotParsingError.invalidRecord(line: index + 1, underlying: error)
        }
      }
  }

  /// Decodes the client's `docker container inspect` format, keyed by full container ID.
  func parseDetails(_ output: String) throws -> [String: ContainerDetail] {
    let details =
      try output
      .split(whereSeparator: \.isNewline)
      .enumerated()
      .map { index, line in
        do {
          let raw = try JSONDecoder().decode(RawDetailLine.self, from: Data(line.utf8))
          return try ContainerDetail(raw)
        } catch {
          throw DockerSnapshotParsingError.invalidRecord(line: index + 1, underlying: error)
        }
      }
    return Dictionary(details.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  /// Decodes the client's `docker stats` format, keyed by container name. Docker shows "--"
  /// for a container it has no sample for yet, such as one that is still starting; those are
  /// left out rather than shown as zero.
  func parseUsage(_ output: String) throws -> [String: ContainerUsage] {
    let samples =
      try output
      .split(whereSeparator: \.isNewline)
      .enumerated()
      .compactMap { index, line -> (String, ContainerUsage)? in
        do {
          let raw = try JSONDecoder().decode(RawUsageLine.self, from: Data(line.utf8))
          guard raw.cpu != "--" else {
            return nil
          }
          return (raw.name, try ContainerUsage(raw))
        } catch {
          throw DockerSnapshotParsingError.invalidRecord(line: index + 1, underlying: error)
        }
      }
    return Dictionary(samples, uniquingKeysWith: { first, _ in first })
  }

  /// Groups records into projects, adding what only `inspect` reports: timestamps, OOM kills and
  /// restarts.
  func projects(
    from records: [DockerContainerRecord],
    details: [String: ContainerDetail]
  ) -> [ContainerProject] {
    let grouped = Dictionary(grouping: records) { record in
      record.project.isEmpty ? Self.standaloneProjectName : record.project
    }

    return
      grouped
      .map { project, records in
        let serviceCounts = Dictionary(records.map { ($0.service, 1) }, uniquingKeysWith: +)
        let containers = records.map { record in
          ContainerInfo(
            record: record,
            project: project,
            isReplica: serviceCounts[record.service, default: 0] > 1,
            detail: details[record.id]
          )
        }
        return ContainerProject(
          name: project,
          containers: containers.sorted(
            using: KeyPathComparator(\.displayName, comparator: .localizedStandard))
        )
      }
      .sorted { lhs, rhs in
        if lhs.name == Self.standaloneProjectName {
          return false
        }
        if rhs.name == Self.standaloneProjectName {
          return true
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
  }

  static func publishedPorts(from rawPorts: String) throws -> [PublishedPort] {
    var seen = Set<PublishedPort>()

    return try rawPorts.split(separator: ",").compactMap { rawMapping in
      let mapping = rawMapping.trimmingCharacters(in: .whitespaces)
      guard let arrow = mapping.range(of: "->") else {
        return nil
      }

      let publishedAddress = mapping[..<arrow.lowerBound]
      guard let separator = publishedAddress.lastIndex(of: ":") else {
        throw DockerSnapshotParsingError.invalidPorts(mapping)
      }

      let bounds = publishedAddress[publishedAddress.index(after: separator)...]
        .split(separator: "-", omittingEmptySubsequences: false)
      guard (1...2).contains(bounds.count),
        let first = Int(bounds[0]), let last = Int(bounds[bounds.count - 1]),
        first >= 1, first <= last, last <= 65535
      else {
        throw DockerSnapshotParsingError.invalidPorts(mapping)
      }

      let port = PublishedPort(range: first...last)
      return seen.insert(port).inserted ? port : nil
    }
  }

  private static let standaloneProjectName = "Standalone"
}

/// One validated line of `docker container ls`.
struct DockerContainerRecord: Equatable, Sendable {
  let id: String
  let name: String
  let project: String
  let service: String
  let replicaNumber: String
  let ports: [PublishedPort]
  let state: String
  let status: String
  let health: String
  /// Set for exited and restarting containers only.
  let exitCode: Int?

  fileprivate init(_ raw: RawContainerLine) throws {
    id = raw.id
    name = raw.name
    project = raw.project
    service = raw.service
    replicaNumber = raw.number
    ports = try DockerSnapshotParser.publishedPorts(from: raw.ports)
    state = raw.state.lowercased()
    status = raw.status
    health = raw.health.lowercased()

    // Docker writes the last exit code into both statuses, as in "Restarting (1) 2 seconds ago".
    if state == "exited" || state == "restarting" {
      guard let match = raw.status.firstMatch(of: #/^(?:Exited|Restarting) \((\d+)\)/#),
        let code = Int(match.1)
      else {
        throw DockerSnapshotParsingError.missingExitCode(status: raw.status)
      }
      exitCode = code
    } else {
      exitCode = nil
    }
  }
}

enum DockerSnapshotParsingError: LocalizedError {
  case invalidRecord(line: Int, underlying: Error)
  case missingExitCode(status: String)
  case invalidUsage(String)
  case invalidPorts(String)

  var errorDescription: String? {
    switch self {
    case .invalidRecord(let line, let underlying):
      "Docker returned invalid container data on line \(line): \(underlying.localizedDescription)"
    case .missingExitCode(let status):
      "Docker reported a stopped or restarting container without an exit code: \(status)"
    case .invalidUsage(let value):
      "Docker reported resource usage in an unexpected form: \(value)"
    case .invalidPorts(let value):
      "Docker reported an invalid published port: \(value)"
    }
  }
}

/// What `docker container ls` cannot report for a container.
struct ContainerDetail: Equatable, Sendable {
  let id: String
  /// Nil until the container first starts.
  let startedAt: Date?
  /// Nil until the container first stops.
  let finishedAt: Date?
  let isOutOfMemory: Bool
  /// Times the restart policy has brought the container back since it was last started by hand.
  let restartCount: Int

  fileprivate init(_ raw: RawDetailLine) throws {
    id = raw.id
    startedAt = try Self.date(raw.startedAt)
    finishedAt = try Self.date(raw.finishedAt)
    isOutOfMemory = raw.oomKilled
    restartCount = raw.restartCount
  }

  /// Docker writes Go's zero time for events that haven't happened.
  private static func date(_ value: String) throws -> Date? {
    value == "0001-01-01T00:00:00Z"
      ? nil : try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)
  }
}

private struct RawDetailLine: Decodable {
  let id: String
  let startedAt: String
  let finishedAt: String
  let oomKilled: Bool
  let restartCount: Int
}

private struct RawUsageLine: Decodable {
  let name: String
  let cpu: String
  /// Used and limit, as in "84.31MiB / 1.913GiB".
  let memory: String
}

extension ContainerUsage {
  /// Docker writes sizes with binary units, as Go's `units.BytesSize` does.
  private static let unitMultipliers: [String: Double] = [
    "B": 1, "KiB": 1024, "MiB": 1024 * 1024, "GiB": 1024 * 1024 * 1024,
    "TiB": 1024 * 1024 * 1024 * 1024,
  ]

  fileprivate init(_ raw: RawUsageLine) throws {
    guard raw.cpu.hasSuffix("%"), let cpu = Double(raw.cpu.dropLast()), cpu.isFinite, cpu >= 0
    else {
      throw DockerSnapshotParsingError.invalidUsage(raw.cpu)
    }
    let used = raw.memory.split(separator: " / ").first.map(String.init) ?? raw.memory
    guard let match = used.firstMatch(of: #/^([0-9.]+)([A-Za-z]+)$/#),
      let value = Double(match.1), value.isFinite, value >= 0,
      let multiplier = Self.unitMultipliers[String(match.2)],
      let memoryBytes = Int64(exactly: (value * multiplier).rounded(.towardZero))
    else {
      throw DockerSnapshotParsingError.invalidUsage(raw.memory)
    }
    self.init(cpuPercent: cpu, memoryBytes: memoryBytes)
  }
}

private struct RawContainerLine: Decodable {
  let id: String
  let name: String
  let project: String
  let service: String
  let number: String
  let ports: String
  let state: String
  let status: String
  let health: String
}

extension ContainerInfo {
  fileprivate init(
    record: DockerContainerRecord,
    project: String,
    isReplica: Bool,
    detail: ContainerDetail?
  ) {
    self.init(
      id: record.id,
      name: record.name,
      project: project,
      displayName: Self.displayName(for: record, isReplica: isReplica),
      ports: record.ports,
      state: ContainerState(
        record: record,
        isOutOfMemory: detail?.isOutOfMemory ?? false,
        restartCount: detail?.restartCount ?? 0),
      exitCode: record.exitCode,
      restartCount: detail?.restartCount ?? 0,
      startedAt: detail?.startedAt,
      finishedAt: detail?.finishedAt
    )
  }

  /// Replicas share a service name, so they take Compose's replica number, as in `web-2`.
  private static func displayName(for record: DockerContainerRecord, isReplica: Bool) -> String {
    if record.service.isEmpty {
      return record.name
    }
    if isReplica {
      // Only Compose sets the number; containers labelled by other tools keep their own name.
      return record.replicaNumber.isEmpty
        ? record.name : "\(record.service)-\(record.replicaNumber)"
    }
    return record.service
  }
}

extension ContainerState {
  /// The codes `docker stop` produces: a clean exit, or death by the signal it sends. That is
  /// SIGTERM or the image's STOPSIGNAL (often SIGINT), then SIGKILL after the timeout.
  private static let stopExitCodes: Set<Int> = [0, 130, 137, 143]

  fileprivate init(record: DockerContainerRecord, isOutOfMemory: Bool, restartCount: Int) {
    switch (record.state, record.health) {
    case ("running", "unhealthy"):
      self = .unhealthy
    // Docker resets the count whenever someone starts the container, so any restart since
    // means it exited when it was meant to keep running, even if it looks healthy again now.
    case ("running", _) where restartCount > 0:
      self = .restarted
    case ("running", "healthy"):
      self = .healthy
    case ("running", "starting"):
      self = .starting
    case ("running", _):
      self = .running
    case ("restarting", _):
      self = .restarting
    case ("paused", _):
      self = .paused
    case ("created", _):
      self = .created
    case ("removing", _):
      self = .exited
    case ("exited", _):
      if isOutOfMemory {
        self = .outOfMemory
      } else if let exitCode = record.exitCode, Self.stopExitCodes.contains(exitCode) {
        self = .exited
      } else {
        self = .failed
      }
    default:
      // "dead": Docker could not finish removing or stopping the container.
      self = .failed
    }
  }
}
