import XCTest

@testable import Pinch

final class DockerSnapshotParserTests: XCTestCase {
  func testReadsTheDefaultColimaProfile() throws {
    let output = """
      {"name":"work","status":"Running","cpus":8,"memory":17179869184}
      {"name":"default","status":"Stopped","arch":"aarch64","cpus":2,"memory":2147483648,"disk":107374182400,"runtime":"docker"}
      """

    let profile = try XCTUnwrap(DockerClient.defaultProfile(in: output))
    XCTAssertEqual(profile.name, "default")
    XCTAssertFalse(profile.isRunning)
    XCTAssertEqual(profile.cpus, 2)
    XCTAssertEqual(profile.memory, 2_147_483_648)
    XCTAssertNil(try DockerClient.defaultProfile(in: ""))
  }

  func testAcceptsColimaProfilesWithoutAllocation() throws {
    let profile = try XCTUnwrap(
      DockerClient.defaultProfile(in: #"{"name":"default","status":"Running"}"#))

    XCTAssertTrue(profile.isRunning)
    XCTAssertEqual(
      profile.runtimeInfo(engineVersion: "29.5.2", memoryUsedBytes: 536_870_912).details,
      ["512 MB used", "Docker 29.5.2"])
  }

  func testDescribesRuntimeAllocationUsageAndEngine() {
    let running = RuntimeInfo(
      state: .running, cpus: 4, memoryBytes: 8_589_934_592, memoryUsedBytes: 1_073_741_824,
      engineVersion: "29.5.2")
    let stopped = RuntimeInfo(
      state: .stopped, cpus: 1, memoryBytes: 2_147_483_648, memoryUsedBytes: nil,
      engineVersion: nil)

    XCTAssertEqual(running.stateLabel, "Running")
    XCTAssertEqual(running.details, ["4 CPUs", "1 GB of 8 GB", "Docker 29.5.2"])
    XCTAssertEqual(stopped.stateLabel, "Stopped")
    XCTAssertEqual(stopped.details, ["1 CPU", "2 GB"])
  }

  /// Colima takes memory in fractions of a GiB, so Settings shows 1.5 GiB as the popover does,
  /// not rounded to a value Colima would then save.
  func testKeepsAFractionalMemoryAllocation() throws {
    let runtime = RuntimeInfo(
      state: .stopped, cpus: 2, memoryBytes: 1_610_612_736, memoryUsedBytes: nil,
      engineVersion: nil)

    let resources = try XCTUnwrap(runtime.resources)
    XCTAssertEqual(resources.memoryGiB, 1.5)
    XCTAssertEqual(runtime.details, ["2 CPUs", resources.memoryLabel])
  }

  func testStepsMemoryToTheNearestWholeGiBEitherSide() {
    let fractional = RuntimeResources(cpus: 2, memoryGiB: 1.5)
    XCTAssertEqual(fractional.memoryGiBAbove, 2)
    XCTAssertEqual(fractional.memoryGiBBelow, 1)

    let whole = RuntimeResources(cpus: 2, memoryGiB: 2)
    XCTAssertEqual(whole.memoryGiBAbove, 3)
    XCTAssertEqual(whole.memoryGiBBelow, 1)

    XCTAssertEqual(RuntimeResources(cpus: 2, memoryGiB: 0.25).memoryGiBAbove, 1)
  }

  func testReadsUsedMemoryFromTheVM() throws {
    let meminfo = """
      MemTotal:        2005448 kB
      MemFree:          405928 kB
      MemAvailable:    1571696 kB
      HugePages_Total:       0
      """

    XCTAssertEqual(
      try DockerClient.memoryUsedBytes(inMeminfo: meminfo), (2_005_448 - 1_571_696) * 1024)
    XCTAssertThrowsError(try DockerClient.memoryUsedBytes(inMeminfo: "MemTotal: 1 kB"))
  }

  func testReadsContainerUsageFromDockerStats() throws {
    let usage = try DockerSnapshotParser().parseUsage(
      """
      {"name":"rustfs","cpu":"0.04%","memory":"84.31MiB / 1.913GiB"}
      {"name":"builder","cpu":"143.20%","memory":"1.2GiB / 1.913GiB"}
      {"name":"warming-up","cpu":"--","memory":"-- / --"}
      """)

    XCTAssertEqual(usage.count, 2)
    XCTAssertEqual(usage["rustfs"]?.memoryBytes, Int64(84.31 * 1024 * 1024))
    XCTAssertEqual(usage["rustfs"]?.cpuLabel, "0.0%")
    XCTAssertEqual(usage["builder"]?.cpuLabel, "143%")
    XCTAssertEqual(usage["builder"]?.memoryLabel, "1.2 GB")
    XCTAssertThrowsError(
      try DockerSnapshotParser().parseUsage(#"{"name":"odd","cpu":"lots","memory":"1MiB / 2GiB"}"#)
    )
  }

  func testRejectsMalformedColimaStatus() {
    XCTAssertThrowsError(try DockerClient.defaultProfile(in: "not-json")) { error in
      guard case ColimaStatusParsingError.invalidRecord(let line, _) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(line, 1)
    }
  }

  func testRejectsNonfiniteAndNegativeCPUUsage() {
    for cpu in ["NaN%", "inf%", "-1%"] {
      XCTAssertThrowsError(
        try DockerSnapshotParser().parseUsage(
          "{\"name\":\"test\",\"cpu\":\"\(cpu)\",\"memory\":\"1MiB / 2MiB\"}"), cpu)
    }
  }

  func testRejectsMemoryUsageThatCannotBeRepresentedAsBytes() {
    for memory in [
      "99999999999999999999TiB", "9223372036854775808B", String(repeating: "9", count: 400) + "TiB",
    ] {
      XCTAssertThrowsError(
        try DockerSnapshotParser().parseUsage(
          "{\"name\":\"test\",\"cpu\":\"1%\",\"memory\":\"\(memory) / 2MiB\"}"), memory)
    }
  }

  func testRejectsInvalidOrOverflowingVMMemory() {
    for (total, available) in [("-1", "0"), ("1", "-1"), ("1", "2"), ("9223372036854775807", "0")] {
      XCTAssertThrowsError(
        try DockerClient.memoryUsedBytes(
          inMeminfo: "MemTotal: \(total) kB\nMemAvailable: \(available) kB"))
    }
  }

  func testAcceptsTheLargestRepresentableVMMemoryAllocation() throws {
    XCTAssertEqual(
      try DockerClient.memoryUsedBytes(
        inMeminfo: "MemTotal: 9007199254740991 kB\nMemAvailable: 0 kB"),
      9_223_372_036_854_774_784)
  }

  func testRejectsMalformedPublishedPortRangesAtTheContainerBoundary() {
    for range in ["0", "65536", "1-9223372036854775807", "80-x", "80--81", "-1", "1-2-3", "90-80"] {
      XCTAssertThrowsError(
        try DockerSnapshotParser().parse(line(id: "bad-port", ports: "0.0.0.0:\(range)->80/tcp")),
        range)
    }
  }

  func testGroupsComposeAndStandaloneContainersWithOperationalState() throws {
    let input = [
      line(
        id: "postgres-id", name: "agent-postgres-1", project: "agent", service: "postgres",
        ports: "0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp", status: "Up 2 hours (healthy)",
        health: "healthy"),
      line(
        id: "bucket-id", name: "agent-minio-bucket-1", project: "agent", service: "minio-bucket",
        state: "exited", status: "Exited (0) 2 hours ago"),
      line(
        id: "standalone-id", name: "scratch", state: "exited", status: "Exited (1) 5 minutes ago"),
    ]

    let projects = try projects(input)

    XCTAssertEqual(projects.map(\.name), ["agent", "Standalone"])
    XCTAssertEqual(projects[0].containers.map(\.displayName), ["minio-bucket", "postgres"])
    XCTAssertEqual(projects[0].containers[0].state, .exited)
    XCTAssertEqual(projects[0].containers[1].state, .healthy)
    XCTAssertEqual(projects[0].containers[1].ports, [PublishedPort(range: 5432...5432)])
    XCTAssertEqual(projects[1].containers[0].displayName, "scratch")
    XCTAssertEqual(projects[1].containers[0].state, .failed)
  }

  func testMapsDockerHealthAndLifecycleStates() throws {
    let input = [
      line(id: "starting", status: "Up 2 seconds (health: starting)", health: "starting"),
      line(id: "unhealthy", status: "Up 2 hours (unhealthy)", health: "unhealthy"),
      line(id: "paused", state: "paused", status: "Up 2 hours (Paused)"),
      line(id: "restarting", state: "restarting", status: "Restarting (1) 2 seconds ago"),
      line(id: "created", state: "created", status: "Created"),
      line(id: "dead", state: "dead", status: "Dead"),
    ]

    XCTAssertEqual(
      try states(input),
      [
        "starting": .starting, "unhealthy": .unhealthy, "paused": .paused,
        "restarting": .restarting, "created": .created, "dead": .failed,
      ])
  }

  /// `docker stop` ends a container with whatever its process does on the stop signal, so
  /// only codes outside that set are failures.
  func testTreatsStopSignalExitsAsStoppedAndOtherCodesAsFailures() throws {
    let input = [0, 130, 137, 143, 1, 2, 139].map { code in
      line(id: "exit-\(code)", state: "exited", status: "Exited (\(code)) 3 minutes ago")
    }

    XCTAssertEqual(
      try states(input),
      [
        "exit-0": .exited, "exit-130": .exited, "exit-137": .exited, "exit-143": .exited,
        "exit-1": .failed, "exit-2": .failed, "exit-139": .failed,
      ])
  }

  func testKeepsTheExitCodeOfExitedAndRestartingContainers() throws {
    let input = [
      line(id: "failed", state: "exited", status: "Exited (139) 3 minutes ago"),
      line(id: "restarting", state: "restarting", status: "Restarting (1) 2 seconds ago"),
      line(id: "running"),
    ]

    let exitCodes = Dictionary(
      uniqueKeysWithValues: try projects(input).flatMap(\.containers).map { ($0.id, $0.exitCode) })
    XCTAssertEqual(exitCodes, ["failed": 139, "restarting": 1, "running": nil])
  }

  func testReadsTimesAndOutOfMemoryKillsFromInspect() throws {
    let parser = DockerSnapshotParser()
    let records = try parser.parse(
      [
        line(id: "oom", state: "exited", status: "Exited (137) 1 minute ago"),
        line(id: "stopped", state: "exited", status: "Exited (137) 1 minute ago"),
        line(id: "new", state: "created", status: "Created"),
      ].joined(separator: "\n"))
    let details = try parser.parseDetails(
      """
      {"id":"oom","startedAt":"2026-10-26T15:00:00.123456789Z","finishedAt":"2026-10-26T16:00:00Z","oomKilled":true,"restartCount":0}
      {"id":"stopped","startedAt":"2026-10-26T15:00:00Z","finishedAt":"2026-10-26T16:00:00Z","oomKilled":false,"restartCount":0}
      {"id":"new","startedAt":"0001-01-01T00:00:00Z","finishedAt":"0001-01-01T00:00:00Z","oomKilled":false,"restartCount":0}
      """)

    let containers = Dictionary(
      uniqueKeysWithValues: parser.projects(from: records, details: details)[0].containers.map {
        ($0.id, $0)
      })
    XCTAssertEqual(containers["oom"]?.state, .outOfMemory)
    XCTAssertEqual(containers["stopped"]?.state, .exited)
    XCTAssertEqual(
      containers["stopped"]?.finishedAt, try Date("2026-10-26T16:00:00Z", strategy: .iso8601))
    XCTAssertNil(containers["new"]?.startedAt)
    XCTAssertNil(containers["new"]?.finishedAt)
  }

  /// A container that crashes after running for a while is back up before the next refresh,
  /// so Docker shows it as running. Its restart count, which Docker resets whenever someone
  /// starts the container, is what gives it away.
  func testCountsRunningContainersTheirRestartPolicyBroughtBackAsIssues() throws {
    let parser = DockerSnapshotParser()
    let records = try parser.parse(
      [
        line(id: "looping", status: "Up 8 seconds (healthy)", health: "healthy"),
        line(id: "steady", status: "Up 2 hours"),
        line(id: "unhealthy", status: "Up 8 seconds (unhealthy)", health: "unhealthy"),
      ].joined(separator: "\n"))
    let details = try parser.parseDetails(
      """
      {"id":"looping","startedAt":"2026-10-26T15:00:00Z","finishedAt":"2026-10-26T14:59:59Z","oomKilled":false,"restartCount":3}
      {"id":"steady","startedAt":"2026-10-26T13:00:00Z","finishedAt":"0001-01-01T00:00:00Z","oomKilled":false,"restartCount":0}
      {"id":"unhealthy","startedAt":"2026-10-26T15:00:00Z","finishedAt":"2026-10-26T14:59:59Z","oomKilled":false,"restartCount":1}
      """)

    let containers = Dictionary(
      uniqueKeysWithValues: parser.projects(from: records, details: details)[0].containers.map {
        ($0.id, $0)
      })
    XCTAssertEqual(containers["looping"]?.state, .restarted)
    XCTAssertEqual(containers["looping"]?.restartCount, 3)
    XCTAssertEqual(containers["steady"]?.state, .running)
    XCTAssertEqual(containers["unhealthy"]?.state, .unhealthy)
  }

  func testDescribesActivityBesideTheName() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func activity(
      _ state: ContainerState, exitCode: Int? = nil, restartCount: Int = 0,
      started: TimeInterval?, finished: TimeInterval?
    ) -> [String] {
      ContainerInfo(
        id: "id", name: "name", project: "project", displayName: "name", ports: [],
        state: state, exitCode: exitCode, restartCount: restartCount,
        startedAt: started.map { now.addingTimeInterval(-$0) },
        finishedAt: finished.map { now.addingTimeInterval(-$0) }
      ).activity(at: now)
    }

    XCTAssertEqual(activity(.healthy, started: 3 * 3600 + 900, finished: nil), ["up 3h"])
    XCTAssertEqual(activity(.running, started: 8, finished: nil), ["up 8s"])
    XCTAssertEqual(activity(.unhealthy, started: 120, finished: nil), ["unhealthy", "up 2m"])
    XCTAssertEqual(
      activity(.restarted, restartCount: 1, started: 8, finished: 9), ["1 restart", "up 8s"])
    XCTAssertEqual(
      activity(.restarted, restartCount: 3, started: 8, finished: 9), ["3 restarts", "up 8s"])
    XCTAssertEqual(activity(.exited, started: nil, finished: 3600), ["stopped 1h ago"])
    XCTAssertEqual(
      activity(.failed, exitCode: 1, started: nil, finished: 2 * 86400),
      ["failed 2d ago", "exit code 1"])
    // Docker reports no exit code for a dead container.
    XCTAssertEqual(activity(.failed, started: nil, finished: 2 * 86400), ["failed 2d ago"])
    XCTAssertEqual(
      activity(.restarting, exitCode: 3, started: 1, finished: 2), ["restarting", "exit code 3"])
    XCTAssertEqual(
      activity(.outOfMemory, exitCode: 137, started: nil, finished: 60), ["out of memory 1m ago"])
    XCTAssertEqual(activity(.paused, started: 3600, finished: nil), ["paused"])
    XCTAssertEqual(activity(.created, started: nil, finished: nil), ["created"])
    XCTAssertEqual(activity(.running, started: nil, finished: nil), [])
  }

  func testRejectsExitedAndRestartingContainersWithoutAnExitCode() {
    for (state, status) in [("exited", "Exited"), ("restarting", "Restarting")] {
      XCTAssertThrowsError(
        try DockerSnapshotParser().parse(line(id: "odd", state: state, status: status))
      ) { error in
        guard case DockerSnapshotParsingError.invalidRecord(let line, _) = error else {
          return XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(line, 1)
      }
    }
  }

  /// Every container counts once, so paused containers show up and unhealthy or crash-looping
  /// ones are not also counted as running.
  func testProjectSummaryCountsEachContainerInOneGroup() {
    func project(_ states: [ContainerState]) -> ContainerProject {
      ContainerProject(
        name: "project",
        containers: states.enumerated().map { index, state in
          ContainerInfo(
            id: "\(index)", name: "\(index)", project: "project", displayName: "\(index)",
            ports: [], state: state, exitCode: nil, restartCount: 0, startedAt: nil,
            finishedAt: nil)
        })
    }

    XCTAssertEqual(project([.paused, .paused]).summary, "2 paused")
    XCTAssertEqual(
      project([
        .healthy, .unhealthy, .restarting, .restarted, .paused, .exited, .created, .outOfMemory,
      ])
      .summary,
      "1 running · 1 paused · 2 stopped · 4 issues")
  }

  func testNamesComposeReplicasByNumber() throws {
    let input = [
      line(id: "web-1", name: "shop-web-1", project: "shop", service: "web", number: "1"),
      line(id: "web-2", name: "shop-web-2", project: "shop", service: "web", number: "2"),
      line(id: "db", name: "shop-db-1", project: "shop", service: "db", number: "1"),
    ]

    XCTAssertEqual(
      try projects(input)[0].containers.map(\.displayName), ["db", "web-1", "web-2"])
  }

  func testSummarisesPortsBeyondTheFirstTwo() {
    let ports = [8080...8080, 8443...8443, 9000...9002, 5432...5432].map(PublishedPort.init)

    XCTAssertEqual(PublishedPort.summary(Array(ports.prefix(2)), limit: 2), "8080, 8443")
    XCTAssertEqual(PublishedPort.summary(ports, limit: 2), "8080, 8443 +4")
  }

  func testPublishedPortsDeduplicateIPv4AndIPv6Bindings() throws {
    let ports = try DockerSnapshotParser.publishedPorts(
      from: "0.0.0.0:9000-9001->9000-9001/tcp, [::]:9000-9001->9000-9001/tcp, 6379/tcp"
    )

    XCTAssertEqual(ports, [PublishedPort(range: 9000...9001)])
    XCTAssertEqual(ports.map(\.label), ["9000–9001"])
  }

  func testAcceptsTheFullValidPublishedPortRange() throws {
    XCTAssertEqual(
      try DockerSnapshotParser.publishedPorts(from: "0.0.0.0:1-65535->1-65535/tcp"),
      [PublishedPort(range: 1...65535)])
  }

  func testRejectsMalformedDockerOutput() {
    XCTAssertThrowsError(try DockerSnapshotParser().parse("not-json")) { error in
      guard case DockerSnapshotParsingError.invalidRecord(let line, _) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(line, 1)
    }
  }

  private func projects(_ lines: [String]) throws -> [ContainerProject] {
    let parser = DockerSnapshotParser()
    return parser.projects(
      from: try parser.parse(lines.joined(separator: "\n")), details: [:])
  }

  private func states(_ lines: [String]) throws -> [String: ContainerState] {
    Dictionary(
      uniqueKeysWithValues: try projects(lines).flatMap(\.containers).map { ($0.id, $0.state) })
  }

  /// One line of the client's `docker container ls` format.
  private func line(
    id: String,
    name: String? = nil,
    project: String = "",
    service: String = "",
    number: String = "",
    ports: String = "",
    state: String = "running",
    status: String = "Up 2 hours",
    health: String = ""
  ) -> String {
    let fields: [String: String] = [
      "id": id, "name": name ?? id, "project": project, "service": service, "number": number,
      "ports": ports, "state": state, "status": status, "health": health,
    ]
    let data = try! JSONSerialization.data(withJSONObject: fields)
    return String(decoding: data, as: UTF8.self)
  }
}
