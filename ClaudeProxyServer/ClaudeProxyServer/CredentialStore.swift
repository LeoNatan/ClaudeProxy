import Foundation

struct CredentialError: Error, Sendable {
	let message: String
}

/// Holds the server's credentials and applies them to upstream requests. Values never leave this object
/// except as request headers to the configured upstream, and as the redaction list.
final class CredentialStore: @unchecked Sendable {
	private let settings: ResolvedSettings
	private let plan: UpstreamPlan
	private let environment: [String: String]
	private let lock = NSLock()

	private var helperKey: (value: String, expires: Date)?
	private var awsCredentials: AWSCredentials?
	private var cloudToken: (value: String, expires: Date)?
	private var dynamicSecrets: Set<String> = []

	let customHeaders: [(name: String, value: String)]
	/// Short credential type for the menu. Never contains the value.
	let summary: String
	/// Where the credential and any custom headers came from. Never contains values.
	let details: [String]
	/// A configuration problem detectable without running anything.
	let problem: String?

	private static let secretVariables = [
		"ANTHROPIC_API_KEY",
		"ANTHROPIC_AUTH_TOKEN",
		"AWS_BEARER_TOKEN_BEDROCK",
		"AWS_ACCESS_KEY_ID",
		"AWS_SECRET_ACCESS_KEY",
		"AWS_SESSION_TOKEN",
		"ANTHROPIC_AWS_API_KEY",
		"ANTHROPIC_FOUNDRY_API_KEY",
		"ANTHROPIC_FOUNDRY_AUTH_TOKEN",
		"CLAUDE_CODE_OAUTH_TOKEN",
		"CLAUDE_CODE_CLIENT_KEY_PASSPHRASE",
	]

	/// Variables whose values must never be shown or sent to clients.
	static func isSecret(_ variable: String) -> Bool {
		secretVariables.contains(variable) || variable == "ANTHROPIC_CUSTOM_HEADERS"
	}

	init(settings: ResolvedSettings, plan: UpstreamPlan) {
		self.settings = settings
		self.plan = plan
		self.environment = settings.processEnvironment

		var headers: [(String, String)] = []
		for line in (settings.value("ANTHROPIC_CUSTOM_HEADERS") ?? "").split(whereSeparator: \.isNewline) {
			guard let colon = line.firstIndex(of: ":") else {
				continue
			}
			let name = line[..<colon].trimmingCharacters(in: .whitespaces)
			let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
			if !name.isEmpty {
				headers.append((name, value))
			}
		}
		self.customHeaders = headers

		var details: [String] = []
		func describe(_ kind: String, variable: String) -> String {
			details.append("\(variable) from \(settings.env[variable]?.source ?? "?")")
			return kind
		}
		func describeKey(_ kind: String, key: String) -> String {
			details.append("\(key) from \(settings.keys[key]?.source ?? "?")")
			return kind
		}
		func skipped() -> String {
			details.append("\(plan.provider.skipAuthVariable!) is set")
			return "None"
		}

		var problem: String?
		let summary: String
		switch plan.provider {
		case .anthropic:
			if settings.value("ANTHROPIC_AUTH_TOKEN") != nil {
				summary = describe("Bearer token", variable: "ANTHROPIC_AUTH_TOKEN")
			} else if settings.value("ANTHROPIC_API_KEY") != nil {
				summary = describe("API key", variable: "ANTHROPIC_API_KEY")
			} else if settings.key("apiKeyHelper") != nil {
				summary = describeKey("API key helper", key: "apiKeyHelper")
			} else {
				summary = "None"
				problem = "No API credentials found (ANTHROPIC_AUTH_TOKEN, ANTHROPIC_API_KEY or apiKeyHelper). OAuth logins are not used."
			}
		case .bedrock, .mantle:
			if plan.skipAuth {
				summary = settings.value("ANTHROPIC_AUTH_TOKEN") != nil ? describe("Gateway bearer token", variable: "ANTHROPIC_AUTH_TOKEN") : skipped()
			} else if settings.value("AWS_BEARER_TOKEN_BEDROCK") != nil {
				summary = describe("Bedrock API key", variable: "AWS_BEARER_TOKEN_BEDROCK")
			} else if plan.provider == .mantle {
				summary = "None"
				problem = "Bedrock Mantle needs AWS_BEARER_TOKEN_BEDROCK or \(plan.provider.skipAuthVariable!) with a gateway."
			} else if settings.key("awsCredentialExport") != nil {
				summary = describeKey("AWS SigV4", key: "awsCredentialExport")
			} else if settings.value("AWS_ACCESS_KEY_ID") != nil {
				summary = describe("AWS SigV4", variable: "AWS_ACCESS_KEY_ID")
			} else {
				summary = "AWS SigV4"
				details.append("aws CLI credential chain\(settings.value("AWS_PROFILE").map { " (profile \($0))" } ?? "")")
			}
		case .anthropicAWS:
			if plan.skipAuth {
				summary = settings.value("ANTHROPIC_AUTH_TOKEN") != nil ? describe("Gateway bearer token", variable: "ANTHROPIC_AUTH_TOKEN") : skipped()
			} else if settings.value("ANTHROPIC_AWS_API_KEY") != nil {
				summary = describe("API key", variable: "ANTHROPIC_AWS_API_KEY")
			} else {
				summary = "None"
				problem = "Claude Platform on AWS: only ANTHROPIC_AWS_API_KEY is supported (no SigV4)."
			}
		case .vertex:
			if plan.skipAuth {
				summary = settings.value("ANTHROPIC_AUTH_TOKEN") != nil ? describe("Gateway bearer token", variable: "ANTHROPIC_AUTH_TOKEN") : skipped()
			} else {
				summary = "Google Cloud token"
				details.append("gcloud application-default credentials")
			}
		case .foundry:
			if plan.skipAuth {
				summary = skipped()
			} else if settings.value("ANTHROPIC_FOUNDRY_AUTH_TOKEN") != nil {
				summary = describe("Bearer token", variable: "ANTHROPIC_FOUNDRY_AUTH_TOKEN")
			} else if settings.value("ANTHROPIC_FOUNDRY_API_KEY") != nil {
				summary = describe("API key", variable: "ANTHROPIC_FOUNDRY_API_KEY")
			} else {
				summary = "Azure token"
				details.append("az CLI credentials")
			}
		}
		if !headers.isEmpty {
			details.append("Custom headers: \(headers.map(\.0).joined(separator: ", ")) (ANTHROPIC_CUSTOM_HEADERS from \(settings.env["ANTHROPIC_CUSTOM_HEADERS"]?.source ?? "?"))")
		}
		self.summary = summary
		self.details = details
		self.problem = problem
	}

	/// Every credential value currently known, for response redaction and profile filtering.
	var secrets: [String] {
		lock.lock()
		defer { lock.unlock() }
		var values = Set(dynamicSecrets)
		for variable in Self.secretVariables {
			if let value = settings.value(variable) {
				values.insert(value)
			}
		}
		for header in customHeaders {
			values.insert(header.value)
		}
		// Very short values would cause spurious redactions and aren't meaningful secrets.
		return values.filter { $0.count >= 8 }.sorted { $0.count > $1.count }
	}

	/// Applies credentials to `request`. May run helper commands; never call on the main thread.
	func authorize(_ request: inout URLRequest, body: Data) throws {
		if let problem {
			throw CredentialError(message: problem)
		}
		switch plan.provider {
		case .anthropic:
			if let token = settings.value("ANTHROPIC_AUTH_TOKEN") {
				request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
			} else if let key = settings.value("ANTHROPIC_API_KEY") {
				request.setValue(key, forHTTPHeaderField: "x-api-key")
			} else {
				// apiKeyHelper output is sent in both headers, like Claude Code does.
				let key = try helperAPIKey()
				request.setValue(key, forHTTPHeaderField: "x-api-key")
				request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
			}
		case .bedrock, .mantle:
			if plan.skipAuth {
				applyGatewayToken(&request)
			} else if let token = settings.value("AWS_BEARER_TOKEN_BEDROCK") {
				request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
			} else {
				SigV4.sign(&request, body: body, credentials: try resolveAWSCredentials(), region: plan.region ?? "us-east-1", service: "bedrock")
			}
		case .anthropicAWS:
			if plan.skipAuth {
				applyGatewayToken(&request)
			} else if let key = settings.value("ANTHROPIC_AWS_API_KEY") {
				request.setValue(key, forHTTPHeaderField: "x-api-key")
			}
		case .vertex:
			if plan.skipAuth {
				applyGatewayToken(&request)
			} else {
				request.setValue("Bearer \(try cachedCloudToken(command: "gcloud auth application-default print-access-token", refreshKey: "gcpAuthRefresh"))", forHTTPHeaderField: "Authorization")
			}
		case .foundry:
			if plan.skipAuth {
				break
			} else if let token = settings.value("ANTHROPIC_FOUNDRY_AUTH_TOKEN") {
				request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
			} else if let key = settings.value("ANTHROPIC_FOUNDRY_API_KEY") {
				request.setValue(key, forHTTPHeaderField: "x-api-key")
			} else {
				let command = "az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv"
				request.setValue("Bearer \(try cachedCloudToken(command: command, refreshKey: nil))", forHTTPHeaderField: "Authorization")
			}
		}
		for header in customHeaders {
			request.setValue(header.value, forHTTPHeaderField: header.name)
		}
	}

	/// Drops cached dynamic credentials after an auth failure. Returns whether a retry can produce different credentials.
	func invalidate() -> Bool {
		lock.lock()
		defer { lock.unlock() }
		let refreshable = helperKey != nil || cloudToken != nil || (awsCredentials != nil && settings.value("AWS_ACCESS_KEY_ID") == nil)
		helperKey = nil
		cloudToken = nil
		awsCredentials = nil
		return refreshable
	}

	// MARK: Sources

	private func applyGatewayToken(_ request: inout URLRequest) {
		if let token = settings.value("ANTHROPIC_AUTH_TOKEN") {
			request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		}
	}

	private func helperAPIKey() throws -> String {
		lock.lock()
		defer { lock.unlock() }
		if let helperKey, helperKey.expires > Date() {
			return helperKey.value
		}
		guard let command = settings.key("apiKeyHelper") else {
			throw CredentialError(message: "No API credentials found.")
		}
		guard let result = ProcessRunner.runShellCommand(command, environment: environment, timeout: 60) else {
			throw CredentialError(message: "apiKeyHelper timed out or could not start.")
		}
		let key = result.trimmedOutput
		guard result.status == 0, !key.isEmpty else {
			throw CredentialError(message: "apiKeyHelper failed (exit \(result.status)).")
		}
		let ttl = Double(settings.value("CLAUDE_CODE_API_KEY_HELPER_TTL_MS") ?? "") ?? 300_000
		helperKey = (key, Date().addingTimeInterval(ttl / 1000))
		dynamicSecrets.insert(key)
		return key
	}

	private func resolveAWSCredentials() throws -> AWSCredentials {
		lock.lock()
		defer { lock.unlock() }
		if let awsCredentials, (awsCredentials.expiration ?? .distantFuture) > Date().addingTimeInterval(5 * 60) {
			return awsCredentials
		}

		if let accessKey = settings.value("AWS_ACCESS_KEY_ID"), let secretKey = settings.value("AWS_SECRET_ACCESS_KEY"), settings.key("awsCredentialExport") == nil {
			let credentials = AWSCredentials(accessKeyId: accessKey, secretAccessKey: secretKey, sessionToken: settings.value("AWS_SESSION_TOKEN"), expiration: nil)
			awsCredentials = credentials
			return credentials
		}

		func fetch() -> AWSCredentials? {
			if let command = settings.key("awsCredentialExport") {
				guard let result = ProcessRunner.runShellCommand(command, environment: environment, timeout: 180), result.status == 0,
					  let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
					  let credentials = json["Credentials"] as? [String: Any] else {
					return nil
				}
				return Self.parseAWS(credentials)
			}
			guard let result = ProcessRunner.runShellCommand("aws configure export-credentials --format process", environment: environment, timeout: 180), result.status == 0,
				  let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
				return nil
			}
			return Self.parseAWS(json)
		}

		var credentials = fetch()
		if credentials == nil, let refresh = settings.key("awsAuthRefresh") {
			_ = ProcessRunner.runShellCommand(refresh, environment: environment, timeout: 180)
			credentials = fetch()
		}
		guard let credentials else {
			throw CredentialError(message: "Could not obtain AWS credentials (awsCredentialExport / aws CLI).")
		}
		awsCredentials = credentials
		dynamicSecrets.insert(credentials.secretAccessKey)
		if let token = credentials.sessionToken {
			dynamicSecrets.insert(token)
		}
		return credentials
	}

	private static func parseAWS(_ json: [String: Any]) -> AWSCredentials? {
		guard let accessKey = json["AccessKeyId"] as? String, let secretKey = json["SecretAccessKey"] as? String else {
			return nil
		}
		var expiration: Date?
		if let string = json["Expiration"] as? String {
			let formatter = ISO8601DateFormatter()
			formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
			expiration = formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
		}
		return AWSCredentials(accessKeyId: accessKey, secretAccessKey: secretKey, sessionToken: json["SessionToken"] as? String, expiration: expiration)
	}

	/// Short-lived OAuth access token from a cloud CLI, cached for 50 minutes (they last ~60).
	private func cachedCloudToken(command: String, refreshKey: String?) throws -> String {
		lock.lock()
		defer { lock.unlock() }
		if let cloudToken, cloudToken.expires > Date() {
			return cloudToken.value
		}
		func fetch() -> String? {
			guard let result = ProcessRunner.runShellCommand(command, environment: environment, timeout: 60), result.status == 0 else {
				return nil
			}
			let token = result.trimmedOutput
			return token.isEmpty ? nil : token
		}
		var token = fetch()
		if token == nil, let refreshKey, let refresh = settings.key(refreshKey) {
			_ = ProcessRunner.runShellCommand(refresh, environment: environment, timeout: 180)
			token = fetch()
		}
		guard let token else {
			throw CredentialError(message: "Could not obtain an access token (\(command.split(separator: " ").first ?? "")).")
		}
		cloudToken = (token, Date().addingTimeInterval(50 * 60))
		dynamicSecrets.insert(token)
		return token
	}
}
