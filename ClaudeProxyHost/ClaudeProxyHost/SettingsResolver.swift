import Foundation

struct SettingValue: Sendable {
	let value: String
	let source: String
}

/// Claude Code's effective configuration on this machine, resolved in Claude Code's precedence order.
struct ResolvedSettings: Sendable {
	/// Effective environment. An empty value means "explicitly unset" (the documented way a settings file unsets a variable).
	var env: [String: SettingValue] = [:]
	/// Effective non-`env` top-level settings with string values (`apiKeyHelper`, `awsCredentialExport`, …).
	var keys: [String: SettingValue] = [:]
	var configDirectory: URL
	var notes: [String] = []

	func value(_ name: String) -> String? {
		guard let value = env[name]?.value, !value.isEmpty else {
			return nil
		}
		return value
	}

	func isTruthy(_ name: String) -> Bool {
		guard let value = value(name)?.lowercased() else {
			return false
		}
		return ["1", "true", "yes", "on"].contains(value)
	}

	func key(_ name: String) -> String? {
		guard let value = keys[name]?.value, !value.isEmpty else {
			return nil
		}
		return value
	}

	/// The environment helper commands run with: what a terminal `claude` session would have.
	var processEnvironment: [String: String] {
		var result: [String: String] = [:]
		for (name, setting) in env where !setting.value.isEmpty {
			result[name] = setting.value
		}
		return result
	}
}

enum SettingsResolver {
	private struct Tier {
		let name: String
		let settings: [String: Any]
	}

	static let managedDirectory = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode")
	static let mdmDomain = "com.anthropic.claudecode"
	private static let remoteSettingsMaxAge: TimeInterval = 24 * 60 * 60
	/// Read from the shell environment first, per Claude Code's env-vars documentation.
	private static let shellFirstVariables: Set<String> = ["ANTHROPIC_MODEL"]

	/// Resolves, highest precedence first:
	/// server-managed (cached) → MDM profile → managed-settings.json + managed-settings.d → user settings.json → login shell env.
	/// Project, local and `--settings` scopes don't apply: the host has no project or session.
	static func resolve() -> ResolvedSettings {
		let shellEnvironment = ShellEnvironment.capture()
		var notes: [String] = []

		let mdmTier = loadMDMTier()
		let fileTier = loadManagedFileTier(notes: &notes)

		// CLAUDE_CONFIG_DIR can't come from a file inside the directory it names.
		let configDirectory: URL = {
			let candidates = [mdmTier, fileTier].compactMap { ($0?.settings["env"] as? [String: Any])?["CLAUDE_CONFIG_DIR"] }.map { stringValue($0) }
			if let path = candidates.first(where: { !$0.isEmpty }) ?? shellEnvironment["CLAUDE_CONFIG_DIR"].flatMap({ $0.isEmpty ? nil : $0 }) {
				return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
			}
			return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
		}()

		let remoteTier = loadRemoteSettingsTier(configDirectory: configDirectory, notes: &notes)
		let managedTiers = [remoteTier, mdmTier, fileTier].compactMap { $0 }

		let userURL = configDirectory.appendingPathComponent("settings.json")
		let userSettings = loadJSON(userURL, notes: &notes) ?? [:]
		let userSource = displayPath(userURL)

		var resolved = ResolvedSettings(configDirectory: configDirectory)

		// Lowest precedence first; each layer overwrites.
		for (name, value) in shellEnvironment {
			resolved.env[name] = SettingValue(value: value, source: "login shell")
		}
		apply(env: userSettings["env"], source: userSource, to: &resolved)
		for tier in managedTiers.reversed() {
			// `env` merges per variable across all admin sources, regardless of managedSourcesBehavior.
			apply(env: tier.settings["env"], source: tier.name, to: &resolved)
		}
		for name in shellFirstVariables {
			if let value = shellEnvironment[name], !value.isEmpty {
				resolved.env[name] = SettingValue(value: value, source: "login shell")
			}
		}

		// Non-env keys: user < managed. Among managed tiers, "first-wins" (default) takes every policy key from the
		// highest tier that defines any; "merge" combines them per key.
		apply(keys: userSettings, source: userSource, to: &resolved)
		let behavior = managedTiers.lazy.compactMap { $0.settings["managedSourcesBehavior"] as? String }.first ?? "first-wins"
		if behavior == "merge" {
			for tier in managedTiers.reversed() {
				apply(keys: tier.settings, source: tier.name, to: &resolved)
			}
		} else if let winner = managedTiers.first(where: { $0.settings.keys.contains { $0 != "env" } }) {
			apply(keys: winner.settings, source: winner.name, to: &resolved)
		}

		resolved.notes = notes
		return resolved
	}

	/// Changes whenever any settings file this resolver reads changes. Shell profile changes need a manual reload.
	static func fingerprint(configDirectory: URL) -> String {
		var urls = [
			managedDirectory.appendingPathComponent("managed-settings.json"),
			managedDirectory.appendingPathComponent("managed-settings.d"),
			configDirectory.appendingPathComponent("settings.json"),
			configDirectory.appendingPathComponent("remote-settings.json"),
		]
		urls += mdmURLs()
		urls += managedDropInURLs()
		return urls.map { url in
			let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
			let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
			let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
			return "\(url.path):\(date):\(size)"
		}.joined(separator: "|")
	}

	static func displayPath(_ url: URL) -> String {
		let home = FileManager.default.homeDirectoryForCurrentUser.path
		return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
	}

	// MARK: Sources

	private static func mdmURLs() -> [URL] {
		let root = URL(fileURLWithPath: "/Library/Managed Preferences")
		return [
			root.appendingPathComponent("\(mdmDomain).plist"),
			root.appendingPathComponent(NSUserName()).appendingPathComponent("\(mdmDomain).plist"),
		]
	}

	private static func managedDropInURLs() -> [URL] {
		let directory = managedDirectory.appendingPathComponent("managed-settings.d")
		let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
		return names
			.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
			.sorted()
			.map { directory.appendingPathComponent($0) }
	}

	/// Configuration profile payload for `com.anthropic.claudecode`; user-level profile overrides the machine one.
	private static func loadMDMTier() -> Tier? {
		var merged: [String: Any] = [:]
		for url in mdmURLs() {
			guard let data = try? Data(contentsOf: url),
				  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
				continue
			}
			merged = merge(merged, plist)
		}
		return merged.isEmpty ? nil : Tier(name: "MDM profile (\(mdmDomain))", settings: merged)
	}

	/// managed-settings.json, then managed-settings.d/*.json alphabetically; later files win.
	private static func loadManagedFileTier(notes: inout [String]) -> Tier? {
		var merged: [String: Any] = [:]
		var names: [String] = []
		for url in [managedDirectory.appendingPathComponent("managed-settings.json")] + managedDropInURLs() {
			guard let json = loadJSON(url, notes: &notes) else {
				continue
			}
			merged = merge(merged, json)
			names.append(url.lastPathComponent)
		}
		return merged.isEmpty ? nil : Tier(name: names.count == 1 ? names[0] : "managed settings (\(names.joined(separator: ", ")))", settings: merged)
	}

	/// Claude Code's cache of server-managed (admin console) settings. We can't fetch them ourselves,
	/// so this is only as fresh as the last Claude Code run on this Mac.
	private static func loadRemoteSettingsTier(configDirectory: URL, notes: inout [String]) -> Tier? {
		let url = configDirectory.appendingPathComponent("remote-settings.json")
		guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
			  let modified = attributes[.modificationDate] as? Date else {
			return nil
		}
		let age = Date().timeIntervalSince(modified)
		guard age < remoteSettingsMaxAge else {
			notes.append("Server-managed settings cache is older than 24 h and was ignored; run claude once to refresh it.")
			return nil
		}
		guard let json = loadJSON(url, notes: &notes) else {
			return nil
		}
		let settings = (json["settings"] as? [String: Any]) ?? json
		return Tier(name: "server-managed (cached \(Int(age / 60)) min ago)", settings: settings)
	}

	private static func loadJSON(_ url: URL, notes: inout [String]) -> [String: Any]? {
		guard let data = try? Data(contentsOf: url) else {
			return nil
		}
		guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			notes.append("\(displayPath(url)) is not valid JSON and was ignored.")
			return nil
		}
		return json
	}

	// MARK: Merging

	/// Scalars: overlay wins. Dictionaries (such as `env`): merged key by key. Arrays: union.
	private static func merge(_ base: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
		var result = base
		for (key, value) in overlay {
			if let baseDictionary = result[key] as? [String: Any], let overlayDictionary = value as? [String: Any] {
				result[key] = merge(baseDictionary, overlayDictionary)
			} else if let baseArray = result[key] as? [Any], let overlayArray = value as? [Any] {
				var union = baseArray
				for element in overlayArray where !union.contains(where: { ($0 as AnyObject).isEqual(element) }) {
					union.append(element)
				}
				result[key] = union
			} else {
				result[key] = value
			}
		}
		return result
	}

	private static func apply(env: Any?, source: String, to resolved: inout ResolvedSettings) {
		guard let env = env as? [String: Any] else {
			return
		}
		for (name, value) in env {
			resolved.env[name] = SettingValue(value: stringValue(value), source: source)
		}
	}

	private static func apply(keys settings: [String: Any], source: String, to resolved: inout ResolvedSettings) {
		for (name, value) in settings where name != "env" {
			if value is String || value is NSNumber {
				resolved.keys[name] = SettingValue(value: stringValue(value), source: source)
			}
		}
	}

	private static func stringValue(_ value: Any) -> String {
		if let string = value as? String {
			return string
		}
		if let number = value as? NSNumber {
			// JSON booleans arrive as NSNumber; Claude Code reads them as strings like "true".
			if CFGetTypeID(number) == CFBooleanGetTypeID() {
				return number.boolValue ? "true" : "false"
			}
			return number.stringValue
		}
		return "\(value)"
	}
}
