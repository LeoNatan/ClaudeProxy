import Foundation

struct ProcessResult: Sendable {
	let status: Int32
	let stdout: Data

	var trimmedOutput: String {
		String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
	}
}

enum ProcessRunner {
	/// Runs a process and returns its exit status and stdout. Output goes through a 0600 temporary file
	/// (deleted immediately) rather than a pipe, so shells that leave background jobs holding the pipe
	/// can't hang us. stderr is discarded: helper diagnostics may echo credentials.
	static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval) -> ProcessResult? {
		let fileManager = FileManager.default
		let outputURL = fileManager.temporaryDirectory.appendingPathComponent("claudeproxy-\(UUID().uuidString)")
		guard fileManager.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
			  let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
			return nil
		}
		defer {
			try? outputHandle.close()
			try? fileManager.removeItem(at: outputURL)
		}

		let process = Process()
		process.executableURL = URL(fileURLWithPath: executable)
		process.arguments = arguments
		if let environment {
			process.environment = environment
		}
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = outputHandle
		process.standardError = FileHandle.nullDevice

		let finished = DispatchSemaphore(value: 0)
		process.terminationHandler = { _ in finished.signal() }
		do {
			try process.run()
		} catch {
			return nil
		}

		if finished.wait(timeout: .now() + timeout) == .timedOut {
			process.terminate()
			if finished.wait(timeout: .now() + 2) == .timedOut {
				kill(process.processIdentifier, SIGKILL)
				_ = finished.wait(timeout: .now() + 2)
			}
			return nil
		}

		let output = (try? Data(contentsOf: outputURL)) ?? Data()
		return ProcessResult(status: process.terminationStatus, stdout: output)
	}

	/// Runs a settings helper command (`apiKeyHelper`, `awsCredentialExport`, …) the way Claude Code does: through `/bin/sh -c`.
	static func runShellCommand(_ command: String, environment: [String: String], timeout: TimeInterval) -> ProcessResult? {
		run("/bin/sh", ["-c", command], environment: environment, timeout: timeout)
	}
}

enum ShellEnvironment {
	private static let marker = "__CLAUDEPROXY_ENV_BEGIN__"

	/// The user's login + interactive shell environment. GUI apps don't inherit what `.zprofile`/`.zshrc` export,
	/// but a terminal-launched `claude` does, so that is what we must see.
	static func capture() -> [String: String] {
		let base = ProcessInfo.processInfo.environment
		let shell = base["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
		guard let result = ProcessRunner.run(shell, ["-l", "-i", "-c", "printf '%s\\0' '\(marker)'; /usr/bin/env -0"], timeout: 15) else {
			return base
		}

		let parts = result.stdout.split(separator: 0, omittingEmptySubsequences: false)
		guard let markerIndex = parts.firstIndex(where: { String(decoding: $0, as: UTF8.self).hasSuffix(marker) }) else {
			return base
		}

		var environment = base
		for part in parts[(markerIndex + 1)...] {
			let entry = String(decoding: part, as: UTF8.self)
			guard let separator = entry.firstIndex(of: "="), separator != entry.startIndex else {
				continue
			}
			environment[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
		}
		return environment
	}
}
