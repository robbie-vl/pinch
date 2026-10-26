import Darwin
import XCTest

@testable import Pinch

@MainActor
final class CommandRunnerTests: XCTestCase {
  func testInheritsTheParentEnvironmentByDefault() async throws {
    let expectedPath = try XCTUnwrap(ProcessInfo.processInfo.environment["PATH"])
    let path = try await CommandRunner().run(
      executable: URL(fileURLWithPath: "/usr/bin/printenv"), arguments: ["PATH"])
    XCTAssertEqual(path, expectedPath)
  }

  func testCancellationStopsAndReapsTheChild() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("pid")
    let started = ContinuousClock.now
    let task = Task {
      try await CommandRunner().run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "echo $$ > \"$1\"; exec /bin/sleep 2", "pinch-test", pidFile.path])
    }
    defer { task.cancel() }
    while !FileManager.default.fileExists(atPath: pidFile.path),
      started.duration(to: .now) < .seconds(1)
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    let pid = try XCTUnwrap(
      Int32(
        String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
      ))

    task.cancel()
    let result = await task.result

    guard case .failure(let error) = result else {
      return XCTFail("A cancelled command succeeded")
    }
    XCTAssertTrue(error is CancellationError)
    XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    XCTAssertEqual(kill(pid, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }

  func testTimeoutStopsTheCommandWithADedicatedError() async throws {
    let started = ContinuousClock.now
    do {
      _ = try await CommandRunner().run(
        executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"],
        timeout: .milliseconds(50))
      XCTFail("A command past its deadline succeeded")
    } catch let error as CommandTimeoutError {
      XCTAssertEqual(error.executable, "sleep")
      XCTAssertEqual(error.timeout, .milliseconds(50))
    }
    XCTAssertLessThan(started.duration(to: .now), .seconds(2))
  }

  func testTimeoutKillsDescendantsHoldingThePipeAfterTheParentExits() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("pid")
    let started = ContinuousClock.now
    do {
      _ = try await CommandRunner().run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
          "-c", "(trap '' TERM; exec /bin/sleep 10) & echo $! > \"$1\"; exit 0", "pinch-test",
          pidFile.path,
        ],
        timeout: .milliseconds(100))
      XCTFail("A descendant held the pipe open past the deadline")
    } catch is CommandTimeoutError {
      let pid = try XCTUnwrap(
        Int32(
          String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(
            in: .whitespacesAndNewlines)))
      // An orphan may briefly remain a zombie until launchd reaps it.
      while kill(pid, 0) == 0, started.duration(to: .now) < .seconds(3) {
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertEqual(kill(pid, 0), -1)
      XCTAssertEqual(errno, ESRCH)
    }
    XCTAssertLessThan(started.duration(to: .now), .seconds(3))
  }

  func testAlreadyCancelledCallerDoesNotLaunchAChild() async {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await CommandRunner().run(
        executable: URL(fileURLWithPath: "/does-not-exist"), arguments: [])
    }
    guard case .failure(let error) = await task.result else {
      return XCTFail("An already cancelled command succeeded")
    }
    XCTAssertTrue(error is CancellationError)
  }

  func testPreservesOutputAndFailureStatus() async throws {
    do {
      _ = try await CommandRunner().run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf stdout; printf stderr >&2; exit 7"])
      XCTFail("A failed command succeeded")
    } catch let error as CommandExecutionError {
      XCTAssertEqual(error.exitCode, 7)
      XCTAssertEqual(error.output, "stdoutstderr")
    }
  }

  func testLargeOutputDoesNotBlockWaitingForExit() async throws {
    let output = try await CommandRunner().run(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "/bin/dd if=/dev/zero bs=65536 count=4 2>/dev/null"], timeout: .seconds(2))
    XCTAssertEqual(output.utf8.count, 262_144)
  }

  func testConcurrentCommandsHaveIndependentOutputAndDeadlines() async throws {
    let output = try await withThrowingTaskGroup(of: String.self) { group in
      for index in 0..<8 {
        group.addTask {
          try await CommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/echo"), arguments: [String(index)],
            timeout: .seconds(2))
        }
      }
      var output = Set<String>()
      for try await value in group { output.insert(value) }
      return output
    }
    XCTAssertEqual(output, Set((0..<8).map(String.init)))
  }
}
