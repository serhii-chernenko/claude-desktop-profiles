import Foundation

struct CommandResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool

    var succeeded: Bool { status == 0 && !timedOut }

    var isUnknownCommand: Bool {
        status == 2 && (stderr.contains("Unknown command") || stderr.contains("usage:"))
    }

    var failureSummary: String {
        if timedOut {
            return "The command did not finish in time and was stopped."
        }
        let source = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stdout : stderr
        let lines = source.split(separator: "\n", omittingEmptySubsequences: true).suffix(12)
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? "The command exited with status \(status)." : text
    }
}

enum CLILocator {
    static let overrideVariable = "CLAUDE_PROFILES_CLI"

    static func bundledCLI() -> URL? {
        if let override = ProcessInfo.processInfo.environment[overrideVariable], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("cli/bin/claude-profiles")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Runs the bundled `claude-profiles` script with `/bin/zsh -f` and streams its output line by line.
struct CLIRunner: Sendable {
    let script: URL
    var environmentOverrides: [String: String] = [:]

    var displayName: String { "claude-profiles" }

    func run(
        _ arguments: [String],
        timeout: TimeInterval? = nil,
        onLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async -> CommandResult {
        await withCheckedContinuation { continuation in
            let session = ProcessSession(onLine: onLine) { result in
                continuation.resume(returning: result)
            }
            session.start(executable: "/bin/zsh", arguments: ["-f", script.path] + arguments,
                          environment: mergedEnvironment(), timeout: timeout)
        }
    }

    private func mergedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        environment.removeValue(forKey: CLILocator.overrideVariable)
        for (key, value) in environmentOverrides {
            environment[key] = value
        }
        return environment
    }
}

private final class ProcessSession: @unchecked Sendable {
    private let lock = NSLock()
    private let onLine: (@Sendable (String, Bool) -> Void)?
    private let completion: (CommandResult) -> Void
    private let process = Process()
    private var collected: [Bool: Data] = [false: Data(), true: Data()]
    private var partial: [Bool: Data] = [false: Data(), true: Data()]
    private var openStreams = 2
    private var exitStatus: Int32?
    private var timedOut = false
    private var finished = false

    init(onLine: (@Sendable (String, Bool) -> Void)?, completion: @escaping (CommandResult) -> Void) {
        self.onLine = onLine
        self.completion = completion
    }

    func start(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval?) {
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        attach(output.fileHandleForReading, isError: false)
        attach(errors.fileHandleForReading, isError: true)
        process.terminationHandler = { [self] finishedProcess in
            processExited(finishedProcess.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            deliver(CommandResult(status: 127, stdout: "", stderr: error.localizedDescription, timedOut: false))
            return
        }
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                expire()
            }
        }
    }

    private func attach(_ handle: FileHandle, isError: Bool) {
        handle.readabilityHandler = { [self] readable in
            let data = readable.availableData
            if data.isEmpty {
                readable.readabilityHandler = nil
                streamClosed(isError: isError)
            } else {
                receive(data, isError: isError)
            }
        }
    }

    private func receive(_ data: Data, isError: Bool) {
        lock.lock()
        collected[isError, default: Data()].append(data)
        var pending = partial[isError, default: Data()]
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<newline]
            lines.append(String(decoding: lineData, as: UTF8.self))
            pending = Data(pending[pending.index(after: newline)...])
        }
        partial[isError] = pending
        lock.unlock()
        emit(lines, isError: isError)
    }

    private func streamClosed(isError: Bool) {
        lock.lock()
        let rest = partial[isError, default: Data()]
        partial[isError] = Data()
        openStreams -= 1
        lock.unlock()
        if !rest.isEmpty {
            emit([String(decoding: rest, as: UTF8.self)], isError: isError)
        }
        finishIfReady()
    }

    private func processExited(_ status: Int32) {
        lock.lock()
        exitStatus = status
        lock.unlock()
        finishIfReady()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
            finishIfReady(force: true)
        }
    }

    private func expire() {
        lock.lock()
        let running = exitStatus == nil && !finished
        if running { timedOut = true }
        lock.unlock()
        if running {
            process.terminate()
        }
    }

    private func emit(_ lines: [String], isError: Bool) {
        guard let onLine else { return }
        for line in lines {
            onLine(line, isError)
        }
    }

    private func finishIfReady(force: Bool = false) {
        lock.lock()
        guard !finished, let status = exitStatus, openStreams == 0 || force else {
            lock.unlock()
            return
        }
        finished = true
        let result = CommandResult(
            status: status,
            stdout: String(decoding: collected[false] ?? Data(), as: UTF8.self),
            stderr: String(decoding: collected[true] ?? Data(), as: UTF8.self),
            timedOut: timedOut
        )
        lock.unlock()
        completion(result)
    }

    private func deliver(_ result: CommandResult) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        completion(result)
    }
}
