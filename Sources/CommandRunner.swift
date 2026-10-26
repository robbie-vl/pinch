import Darwin
import Foundation
import Synchronization

struct CommandRunner: Sendable {
  let environment: [String: String]

  init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.environment = environment
  }

  func run(executable: URL, arguments: [String], timeout: Duration = .seconds(30)) async throws
    -> String
  {
    let command = CommandProcess(
      executable: executable, arguments: arguments, environment: environment)
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let deadline = Task {
        do {
          try await Task.sleep(for: timeout)
        } catch {
          return
        }
        command.stop(
          with: CommandTimeoutError(executable: executable.lastPathComponent, timeout: timeout))
      }
      defer { deadline.cancel() }
      // Foundation's pipe reads and process wait are blocking; keep them off the caller's actor.
      return try await Task.detached(priority: .userInitiated) {
        try command.execute()
      }.value
    } onCancel: {
      command.stop(with: CancellationError())
    }
  }
}

/// Serializes launch and termination so cancellation before or during launch cannot miss the child.
private final class CommandProcess: Sendable {
  private struct State {
    var started = false
    var finished = false
    var stopReason: (any Error)?
  }

  private let process = Process()
  private let output = Pipe()
  private let state = Mutex(State())
  private let executableName: String

  init(executable: URL, arguments: [String], environment: [String: String]) {
    executableName = executable.lastPathComponent
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
  }

  func execute() throws -> String {
    defer {
      try? output.fileHandleForReading.close()
      try? output.fileHandleForWriting.close()
    }
    try state.withLock { state in
      if let error = state.stopReason { throw error }
      try process.run()
      state.started = true
    }

    let result = Result { try output.fileHandleForReading.readToEnd() ?? Data() }
    if case .failure(let error) = result { stop(with: error) }
    process.waitUntilExit()
    try state.withLock { state in
      state.finished = true
      if let error = state.stopReason { throw error }
    }

    let message = String(decoding: try result.get(), as: UTF8.self).trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
      throw CommandExecutionError(
        executable: executableName,
        exitCode: process.terminationStatus,
        output: message)
    }
    return message
  }

  func stop(with error: any Error) {
    state.withLock { state in
      guard !state.finished, state.stopReason == nil else { return }
      state.stopReason = error
      guard state.started else { return }
      process.terminate()
      // Foundation launches a separate process group. Kill that group if a child ignores TERM
      // or keeps the output pipe open after the CLI exits (for example, Colima's SSH subprocess).
      DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
        self.state.withLock { state in
          guard !state.finished else { return }
          kill(-process.processIdentifier, SIGKILL)
        }
      }
    }
  }
}

struct ExecutableLocator: Sendable {
  let environment: [String: String]

  init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.environment = environment
  }

  func locate(_ name: String) throws -> URL {
    let searchDirectories = pathDirectories + platformDirectories
    for directory in searchDirectories {
      let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(
        name)
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
      }
    }
    throw ExecutableLocationError.notFound(name: name, searched: searchDirectories)
  }

  private var pathDirectories: [String] {
    environment["PATH"]?
      .split(separator: ":")
      .map(String.init) ?? []
  }

  private var platformDirectories: [String] {
    #if arch(arm64)
      ["/opt/homebrew/bin"]
    #else
      ["/usr/local/bin"]
    #endif
  }
}

struct CommandExecutionError: LocalizedError {
  let executable: String
  let exitCode: Int32
  let output: String

  var errorDescription: String? {
    let detail = output.isEmpty ? "No error output was returned." : output
    return "\(executable) exited with code \(exitCode). \(detail)"
  }
}

struct CommandTimeoutError: LocalizedError {
  let executable: String
  let timeout: Duration

  var errorDescription: String? {
    "\(executable) timed out after \(timeout.formatted(.units(allowed: [.minutes, .seconds], width: .wide)))."
  }
}

enum ExecutableLocationError: LocalizedError {
  case notFound(name: String, searched: [String])

  var errorDescription: String? {
    switch self {
    case .notFound(let name, let searched):
      "Could not find \(name). Searched: \(searched.joined(separator: ", "))."
    }
  }
}
