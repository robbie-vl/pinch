import XCTest

@testable import Pinch

@MainActor
final class DockerClientTests: XCTestCase {
  func testRuntimeLifecycleExplicitlySelectsTheDefaultProfile() async throws {
    let fixture = try DockerCommandFixture()

    try await fixture.client.setRuntimeRunning(true)
    try await fixture.client.setRuntimeRunning(false)

    XCTAssertEqual(
      try fixture.commands(),
      [
        "colima --profile default start", "colima --profile default stop",
      ])
  }

  func testEveryDockerOperationUsesTheSocketReportedByTheDefaultProfile() async throws {
    let fixture = try DockerCommandFixture()

    let snapshot = try await fixture.client.loadSnapshot()
    _ = try await fixture.client.loadUsage()
    try await fixture.client.perform(.stop, on: "abc123")

    XCTAssertEqual(snapshot.containers.map(\.id), ["abc123"])
    let commands = try fixture.commands()
    let dockerCommands = commands.filter { $0.hasPrefix("docker ") }
    XCTAssertEqual(dockerCommands.count, 5)
    XCTAssertTrue(
      dockerCommands.allSatisfy { $0.hasPrefix("docker --host unix:///tmp/pinch-test.sock ") })
    XCTAssertTrue(commands.contains("colima --profile default ssh -- cat /proc/meminfo"))
    XCTAssertTrue(commands.contains("colima --profile default status --json"))
  }

  func testRejectsNonlocalOrInvalidEndpointsBeforeCallingDocker() async throws {
    let invalidStatuses = [
      #"{"runtime":"docker","docker_socket":"tcp://production.example:2376"}"#,
      #"{"runtime":"docker","docker_socket":"ssh://production.example"}"#,
      #"{"runtime":"docker","docker_socket":"unix://remote/tmp/docker.sock"}"#,
      #"{"runtime":"docker","docker_socket":"unix:///tmp/docker.sock?other=1"}"#,
      #"{"runtime":"docker","docker_socket":"unix:///tmp/docker.sock#fragment"}"#,
      #"{"runtime":"docker","docker_socket":"unix://"}"#,
      #"{"runtime":"docker","docker_socket":"unix:/tmp/docker.sock"}"#,
      #"{"runtime":"docker","docker_socket":"unix:///"}"#,
      #"{"runtime":"docker","docker_socket":"unix://user@/tmp/docker.sock"}"#,
      #"{"runtime":"containerd","docker_socket":"unix:///tmp/docker.sock"}"#,
      #"{"runtime":"docker"}"#,
      "not-json",
    ]
    for status in invalidStatuses {
      let fixture = try DockerCommandFixture(status: status)
      let operations: [() async throws -> Void] = [
        { _ = try await fixture.client.loadSnapshot() },
        { _ = try await fixture.client.loadUsage() },
        { try await fixture.client.perform(.stop, on: "abc123") },
      ]
      for operation in operations {
        do {
          try await operation()
          XCTFail("Accepted invalid Colima status: \(status)")
        } catch {
          XCTAssertFalse(try fixture.commands().contains { $0.hasPrefix("docker ") })
        }
      }
    }
  }

  func testCancellingRefreshStopsTheCommandAndClearsTheInFlightState() async throws {
    let fixture = try DockerCommandFixture()
    let script = #"""
      #!/bin/sh
      fixture="$(dirname "$0")"
      printf ready > "$fixture/ready"
      exec /bin/sleep 2
      """#
    try script.write(
      to: fixture.directory.appendingPathComponent("colima"), atomically: false, encoding: .utf8)
    let store = ContainerStore(client: fixture.client)
    let started = ContinuousClock.now
    let task = Task { await store.refresh() }
    defer { task.cancel() }
    while !FileManager.default.fileExists(
      atPath: fixture.directory.appendingPathComponent("ready").path),
      started.duration(to: .now) < .seconds(1)
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(store.isRefreshing)

    task.cancel()
    await task.value

    XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    XCTAssertFalse(store.isRefreshing)
    XCTAssertNil(store.snapshot)
    XCTAssertNil(store.refreshError)
  }
}

private final class DockerCommandFixture {
  let directory: URL
  let client: DockerClient

  init(status: String = #"{"runtime":"docker","docker_socket":"unix:///tmp/pinch-test.sock"}"#)
    throws
  {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try status.write(
      to: directory.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
    let scripts = [
      "colima": #"""
      #!/bin/sh
      fixture="$(dirname "$0")"
      printf 'colima %s\n' "$*" >> "$fixture/commands"
      if [ "$1" = '--profile' ]; then shift 2; fi
      case "$1" in
        list) printf '%s\n' '{"name":"default","status":"Running"}' ;;
        status) /bin/cat "$fixture/status.json" ;;
        ssh) printf 'MemTotal: 1024 kB\nMemAvailable: 512 kB\n' ;;
        start|stop) ;;
        *) exit 64 ;;
      esac
      """#,
      "docker": #"""
      #!/bin/sh
      fixture="$(dirname "$0")"
      printf 'docker %s\n' "$*" >> "$fixture/commands"
      shift 2
      case "$1 $2" in
        'version --format') printf '29.5.2\n' ;;
        'container ls') printf '%s\n' '{"id":"abc123","name":"test","project":"","service":"","number":"","ports":"","state":"running","status":"Up 1 minute","health":""}' ;;
        'container inspect') printf '%s\n' '{"id":"abc123","startedAt":"2026-10-26T15:00:00Z","finishedAt":"0001-01-01T00:00:00Z","oomKilled":false}' ;;
        'stats --no-stream') printf '%s\n' '{"name":"test","cpu":"1%","memory":"1MiB / 2MiB"}' ;;
        'stop abc123') ;;
        *) exit 64 ;;
      esac
      """#,
    ]
    for (name, script) in scripts {
      let executable = directory.appendingPathComponent(name)
      try script.write(to: executable, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = directory.path + ":/usr/bin:/bin"
    environment["COLIMA_PROFILE"] = "other-vm"
    environment["DOCKER_CONTEXT"] = "production"
    environment["DOCKER_HOST"] = "tcp://production.example:2376"
    environment["DOCKER_CONFIG"] = directory.appendingPathComponent("other-docker-config").path
    client = DockerClient(
      locator: ExecutableLocator(environment: environment),
      runner: CommandRunner(environment: environment))
  }

  deinit {
    try? FileManager.default.removeItem(at: directory)
  }

  func commands() throws -> [String] {
    try String(contentsOf: directory.appendingPathComponent("commands"), encoding: .utf8)
      .split(whereSeparator: \.isNewline).map(String.init)
  }
}
