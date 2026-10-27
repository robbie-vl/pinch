import Foundation

struct DockerClient: Sendable {
  private let locator: ExecutableLocator
  private let runner: CommandRunner
  private let parser: DockerSnapshotParser

  init(
    locator: ExecutableLocator = ExecutableLocator(),
    runner: CommandRunner = CommandRunner(),
    parser: DockerSnapshotParser = DockerSnapshotParser()
  ) {
    self.locator = locator
    self.runner = runner
    self.parser = parser
  }

  func loadSnapshot() async throws -> ContainerSnapshot {
    let colima = try locator.locate("colima")
    let colimaOutput = try await runner.run(
      executable: colima, arguments: Self.colimaArguments(["list", "--json"]))
    guard let profile = try Self.defaultProfile(in: colimaOutput) else {
      return ContainerSnapshot(runtime: .notCreated, projects: [])
    }
    guard profile.isRunning else {
      return ContainerSnapshot(
        runtime: profile.runtimeInfo(engineVersion: nil, memoryUsedBytes: nil), projects: [])
    }

    let host = try await dockerHost(colima: colima)
    async let meminfo = runner.run(
      executable: colima, arguments: Self.colimaArguments(["ssh", "--", "cat", "/proc/meminfo"]))

    let docker = try locator.locate("docker")
    async let engineVersion = runner.run(
      executable: docker,
      arguments: Self.dockerArguments(["version", "--format", "{{.Server.Version}}"], host: host)
    )
    async let containerOutput = runner.run(
      executable: docker,
      arguments: Self.dockerArguments(
        [
          // Full IDs, so they match the ones `inspect` returns.
          "container", "ls", "--all", "--no-trunc", "--format", Self.containerFormat,
        ], host: host)
    )

    let records = try await parser.parse(containerOutput)
    let details = try await details(of: records.map(\.id), docker: docker, host: host)
    return try await ContainerSnapshot(
      runtime: profile.runtimeInfo(
        engineVersion: engineVersion,
        // Supplementary: if the VM can't be reached over SSH, the header shows the allocation
        // alone rather than the whole refresh failing and hiding the container list.
        memoryUsedBytes: try? Self.memoryUsedBytes(inMeminfo: await meminfo)
      ),
      projects: parser.projects(from: records, details: details)
    )
  }

  /// Start and finish times, OOM kills and restarts, which `docker container ls` cannot report.
  private func details(of containerIDs: [String], docker: URL, host: String) async throws
    -> [String: ContainerDetail]
  {
    guard !containerIDs.isEmpty else {
      return [:]
    }
    let output = try await runner.run(
      executable: docker,
      arguments: Self.dockerArguments(
        ["container", "inspect", "--format", Self.detailFormat] + containerIDs, host: host)
    )
    return try parser.parseDetails(output)
  }

  /// One CPU and memory sample per running container, keyed by container name. Takes about
  /// two seconds, because Docker measures CPU over an interval.
  func loadUsage() async throws -> [String: ContainerUsage] {
    let host = try await dockerHost(colima: locator.locate("colima"))
    let docker = try locator.locate("docker")
    let output = try await runner.run(
      executable: docker,
      // A single sample: the streaming form redraws a terminal screen with escape codes,
      // even when its output isn't a terminal.
      arguments: Self.dockerArguments(
        ["stats", "--no-stream", "--format", Self.usageFormat], host: host)
    )
    return try parser.parseUsage(output)
  }

  /// The most recent lines a container has written, stdout and stderr interleaved, as plain
  /// text.
  func loadLogs(of containerID: String) async throws -> String {
    let host = try await dockerHost(colima: locator.locate("colima"))
    let docker = try locator.locate("docker")
    let output = try await runner.run(
      executable: docker,
      arguments: Self.dockerArguments(
        ["logs", "--tail", String(Self.logLineLimit), containerID], host: host)
    )
    return Self.removingTerminalEscapes(from: output)
  }

  func setRuntimeRunning(_ shouldRun: Bool) async throws {
    let colima = try locator.locate("colima")
    let action = shouldRun ? "start" : "stop"
    _ = try await runner.run(
      executable: colima, arguments: Self.colimaArguments([action]), timeout: .seconds(300))
  }

  func perform(_ action: ContainerAction, on containerID: String) async throws {
    let host = try await dockerHost(colima: locator.locate("colima"))
    let docker = try locator.locate("docker")
    _ = try await runner.run(
      executable: docker,
      arguments: Self.dockerArguments([action.rawValue, containerID], host: host),
      timeout: .seconds(60)
    )
  }

  static func defaultProfile(in output: String) throws -> ColimaProfile? {
    try output
      .split(whereSeparator: \.isNewline)
      .enumerated()
      .map { index, line in
        do {
          return try JSONDecoder().decode(ColimaProfile.self, from: Data(line.utf8))
        } catch {
          throw ColimaStatusParsingError.invalidRecord(line: index + 1, underlying: error)
        }
      }
      .first(where: { $0.name == colimaProfile })
  }

  /// The VM's used memory, as `free` computes it: total less what the kernel could still hand
  /// out, which counts reclaimable cache as available.
  static func memoryUsedBytes(inMeminfo output: String) throws -> Int64 {
    var kilobytes: [String: Int64] = [:]
    for line in output.split(whereSeparator: \.isNewline) {
      let fields = line.split(whereSeparator: \.isWhitespace)
      if fields.count == 3, fields[2] == "kB", let value = Int64(fields[1]) {
        kilobytes[String(fields[0].dropLast())] = value
      }
    }
    guard let total = kilobytes["MemTotal"], let available = kilobytes["MemAvailable"] else {
      throw ColimaStatusParsingError.missingMemoryInfo
    }
    guard total >= 0, available >= 0, available <= total, total <= Int64.max / 1024 else {
      throw ColimaStatusParsingError.invalidMemoryInfo
    }
    return (total - available) * 1024
  }

  /// Drops the ECMA-48 escape sequences that colour text, move the cursor or set the title:
  /// control sequences (`ESC [`), operating system commands (`ESC ]`, ended by BEL or `ESC \`),
  /// and the two-byte escapes such as a character set switch.
  static func removingTerminalEscapes(from output: String) -> String {
    output.replacing(#/\e(?:\[[0-?]*[ -/]*[@-~]|\][^\a\e]*(?:\a|\e\\)|[ -/]*[0-~])/#, with: "")
  }

  /// How far back `loadLogs` reaches, so a chatty container can't flood the window.
  static let logLineLimit = 200

  private static let colimaProfile = "default"

  private static func colimaArguments(_ arguments: [String]) -> [String] {
    ["--profile", colimaProfile] + arguments
  }

  /// Resolve the socket from Colima itself, so a mutable Docker context cannot redirect controls.
  private func dockerHost(colima: URL) async throws -> String {
    let output = try await runner.run(
      executable: colima, arguments: Self.colimaArguments(["status", "--json"]))
    let status: ColimaRuntimeStatus
    do {
      status = try JSONDecoder().decode(ColimaRuntimeStatus.self, from: Data(output.utf8))
    } catch {
      throw ColimaStatusParsingError.invalidRecord(line: 1, underlying: error)
    }
    guard status.runtime == "docker",
      status.dockerSocket.hasPrefix("unix:///"),
      let socket = URLComponents(string: status.dockerSocket),
      socket.scheme == "unix", socket.host == nil || socket.host == "",
      socket.path.hasPrefix("/"), socket.path != "/",
      socket.user == nil, socket.password == nil, socket.port == nil,
      socket.query == nil, socket.fragment == nil
    else {
      throw ColimaStatusParsingError.invalidDockerSocket
    }
    return status.dockerSocket
  }

  private static func dockerArguments(_ arguments: [String], host: String) -> [String] {
    ["--host", host] + arguments
  }

  private static let usageFormat =
    #"{"name":{{json .Name}},"cpu":{{json .CPUPerc}},"memory":{{json .MemUsage}}}"#

  private static let detailFormat =
    #"{"id":{{json .Id}},"startedAt":{{json .State.StartedAt}},"finishedAt":{{json .State.FinishedAt}},"oomKilled":{{json .State.OOMKilled}},"restartCount":{{json .RestartCount}}}"#

  private static let containerFormat =
    #"{"id":{{json .ID}},"name":{{json .Names}},"project":{{json (.Label "com.docker.compose.project")}},"service":{{json (.Label "com.docker.compose.service")}},"number":{{json (.Label "com.docker.compose.container-number")}},"ports":{{json .Ports}},"state":{{json .State}},"status":{{json .Status}},"health":{{json .HealthStatus}}}"#
}

private struct ColimaRuntimeStatus: Decodable {
  let runtime: String
  let dockerSocket: String

  enum CodingKeys: String, CodingKey {
    case runtime
    case dockerSocket = "docker_socket"
  }
}

/// One line of `colima list --json`.
struct ColimaProfile: Decodable, Equatable {
  let name: String
  let status: String
  let cpus: Int?
  let memory: Int64?

  var isRunning: Bool {
    status.lowercased() == "running"
  }

  func runtimeInfo(engineVersion: String?, memoryUsedBytes: Int64?) -> RuntimeInfo {
    RuntimeInfo(
      state: isRunning ? .running : .stopped,
      cpus: cpus,
      memoryBytes: memory,
      memoryUsedBytes: memoryUsedBytes,
      engineVersion: engineVersion
    )
  }
}

enum ColimaStatusParsingError: LocalizedError {
  case invalidRecord(line: Int, underlying: Error)
  case missingMemoryInfo
  case invalidMemoryInfo
  case invalidDockerSocket

  var errorDescription: String? {
    switch self {
    case .invalidRecord(let line, let underlying):
      "Colima returned invalid status data on line \(line): \(underlying.localizedDescription)"
    case .missingMemoryInfo:
      "Colima's VM did not report its total and available memory."
    case .invalidMemoryInfo:
      "Colima's VM reported memory values outside the supported range."
    case .invalidDockerSocket:
      "Colima's default profile did not report a local Docker Unix socket. Container controls are unavailable."
    }
  }
}
