import Foundation

/// Writes ClaudeProxy's env into Claude Code's user settings, remembering what it replaced so it can be undone.
@MainActor
final class SettingsInstaller {
	struct InstallError: LocalizedError {
		let errorDescription: String?
	}

	private static let originalsKey = "originalEnv"
	private static let installedKey = "installedEnv"
	/// Stored in place of a value when the key didn't exist before install.
	private static let absentMarker = "__claudeproxy_absent__"

	private var configDirectory: URL?

	var settingsURL: URL {
		resolveConfigDirectory().appendingPathComponent("settings.json")
	}

	var installedEnv: [String: String]? {
		UserDefaults.standard.dictionary(forKey: Self.installedKey) as? [String: String]
	}

	var isInstalled: Bool {
		installedEnv != nil
	}

	func install(env: [String: String]) throws {
		var settings = try readSettings()
		var fileEnv = settings["env"] as? [String: Any] ?? [:]
		var originals = UserDefaults.standard.dictionary(forKey: Self.originalsKey) as? [String: String] ?? [:]
		let previous = installedEnv ?? [:]

		// Keys we set last time but no longer need go back to what they were.
		for key in previous.keys where env[key] == nil {
			restore(key, originals: &originals, env: &fileEnv)
		}
		for (key, value) in env {
			if originals[key] == nil {
				originals[key] = fileEnv[key].map { "\($0)" } ?? Self.absentMarker
			}
			fileEnv[key] = value
		}

		settings["env"] = fileEnv
		try backUpOnce()
		try writeSettings(settings)
		UserDefaults.standard.set(originals, forKey: Self.originalsKey)
		UserDefaults.standard.set(env, forKey: Self.installedKey)
	}

	func uninstall() throws {
		var settings = try readSettings()
		var fileEnv = settings["env"] as? [String: Any] ?? [:]
		var originals = UserDefaults.standard.dictionary(forKey: Self.originalsKey) as? [String: String] ?? [:]
		for key in (installedEnv ?? [:]).keys {
			restore(key, originals: &originals, env: &fileEnv)
		}
		if fileEnv.isEmpty {
			settings["env"] = nil
		} else {
			settings["env"] = fileEnv
		}
		try writeSettings(settings)
		UserDefaults.standard.removeObject(forKey: Self.originalsKey)
		UserDefaults.standard.removeObject(forKey: Self.installedKey)
	}

	/// Managed settings on this Mac outrank user settings; report keys where they'd override the install.
	func managedOverrides(for env: [String: String]) -> [String] {
		var managed: [String: String] = [:]
		var sources: [URL] = [
			URL(fileURLWithPath: "/Library/Managed Preferences/com.anthropic.claudecode.plist"),
			URL(fileURLWithPath: "/Library/Managed Preferences/\(NSUserName())/com.anthropic.claudecode.plist"),
			URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json"),
		]
		let dropIns = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.d")
		sources += ((try? FileManager.default.contentsOfDirectory(atPath: dropIns.path)) ?? [])
			.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
			.sorted()
			.map { dropIns.appendingPathComponent($0) }
		sources.append(resolveConfigDirectory().appendingPathComponent("remote-settings.json"))

		for url in sources {
			guard let data = try? Data(contentsOf: url) else {
				continue
			}
			let object = url.pathExtension == "plist"
				? try? PropertyListSerialization.propertyList(from: data, format: nil)
				: try? JSONSerialization.jsonObject(with: data)
			guard var dictionary = object as? [String: Any] else {
				continue
			}
			if let nested = dictionary["settings"] as? [String: Any] {
				dictionary = nested
			}
			for (key, value) in dictionary["env"] as? [String: Any] ?? [:] {
				managed[key] = "\(value)"
			}
		}
		return env.keys.filter { key in managed[key].map { $0 != env[key] } ?? false }.sorted()
	}

	static func displayPath(_ url: URL) -> String {
		let home = FileManager.default.homeDirectoryForCurrentUser.path
		return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
	}

	// MARK: Private

	private func restore(_ key: String, originals: inout [String: String], env: inout [String: Any]) {
		if let original = originals.removeValue(forKey: key), original != Self.absentMarker {
			env[key] = original
		} else {
			env[key] = nil
		}
	}

	/// Claude Code honors CLAUDE_CONFIG_DIR from the shell; the app has to ask the login shell for it.
	private func resolveConfigDirectory() -> URL {
		if let configDirectory {
			return configDirectory
		}
		let environment = ShellEnvironment.capture()
		let directory: URL
		if let path = environment["CLAUDE_CONFIG_DIR"], !path.isEmpty {
			directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
		} else {
			directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
		}
		configDirectory = directory
		return directory
	}

	private func readSettings() throws -> [String: Any] {
		guard let data = try? Data(contentsOf: settingsURL) else {
			return [:]
		}
		if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) {
			return [:]
		}
		guard let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			throw InstallError(errorDescription: "\(settingsURL.path) is not valid JSON. Fix it and try again; nothing was changed.")
		}
		return settings
	}

	private func writeSettings(_ settings: [String: Any]) throws {
		let directory = settingsURL.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
		data.append(0x0A)
		try data.write(to: settingsURL, options: .atomic)
	}

	private func backUpOnce() throws {
		let backup = settingsURL.appendingPathExtension("claudeproxy-backup")
		guard FileManager.default.fileExists(atPath: settingsURL.path), !FileManager.default.fileExists(atPath: backup.path) else {
			return
		}
		try FileManager.default.copyItem(at: settingsURL, to: backup)
	}
}
