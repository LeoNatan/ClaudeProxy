import CryptoKit
import Foundation

enum Provider: String, Sendable, CaseIterable {
	case anthropic
	case bedrock
	case vertex
	case foundry
	case mantle
	case anthropicAWS = "anthropic-aws"

	/// Cloud providers, in the order their switches are checked.
	static let cloud: [Provider] = [.bedrock, .vertex, .foundry, .mantle, .anthropicAWS]

	var displayName: String {
		switch self {
		case .anthropic: "Anthropic API / Gateway"
		case .bedrock: "Amazon Bedrock"
		case .vertex: "Google Vertex AI"
		case .foundry: "Microsoft Foundry"
		case .mantle: "Bedrock Mantle"
		case .anthropicAWS: "Claude Platform on AWS"
		}
	}

	var switchVariable: String? {
		switch self {
		case .anthropic: nil
		case .bedrock: "CLAUDE_CODE_USE_BEDROCK"
		case .vertex: "CLAUDE_CODE_USE_VERTEX"
		case .foundry: "CLAUDE_CODE_USE_FOUNDRY"
		case .mantle: "CLAUDE_CODE_USE_MANTLE"
		case .anthropicAWS: "CLAUDE_CODE_USE_ANTHROPIC_AWS"
		}
	}

	var skipAuthVariable: String? {
		switch self {
		case .anthropic: nil
		case .bedrock: "CLAUDE_CODE_SKIP_BEDROCK_AUTH"
		case .vertex: "CLAUDE_CODE_SKIP_VERTEX_AUTH"
		case .foundry: "CLAUDE_CODE_SKIP_FOUNDRY_AUTH"
		case .mantle: "CLAUDE_CODE_SKIP_MANTLE_AUTH"
		case .anthropicAWS: "CLAUDE_CODE_SKIP_ANTHROPIC_AWS_AUTH"
		}
	}

	var baseURLVariable: String {
		switch self {
		case .anthropic: "ANTHROPIC_BASE_URL"
		case .bedrock: "ANTHROPIC_BEDROCK_BASE_URL"
		case .vertex: "ANTHROPIC_VERTEX_BASE_URL"
		case .foundry: "ANTHROPIC_FOUNDRY_BASE_URL"
		case .mantle: "ANTHROPIC_BEDROCK_MANTLE_BASE_URL"
		case .anthropicAWS: "ANTHROPIC_AWS_BASE_URL"
		}
	}
}

struct ProxyRequestError: Error, Sendable {
	let status: Int
	let message: String
}

/// Where requests go and how their URLs are formed. The upstream host always comes from this Mac's settings;
/// a client only contributes the path and query.
struct UpstreamPlan: Sendable {
	let provider: Provider
	/// nil when the Vertex host is derived per request from the location in the path.
	let baseURL: URL?
	let region: String?
	let skipAuth: Bool
	let problem: String?
	let notes: [String]

	init(settings: ResolvedSettings) {
		var notes: [String] = []
		let enabled = Provider.cloud.filter { settings.isTruthy($0.switchVariable!) }
		let provider = enabled.first ?? .anthropic
		if enabled.count > 1 {
			notes.append("Several Providers Are Enabled (\(enabled.map(\.displayName).joined(separator: ", "))); Using \(provider.displayName).")
		}
		self.provider = provider
		self.skipAuth = provider.skipAuthVariable.map { settings.isTruthy($0) } ?? false

		let override = settings.value(provider.baseURLVariable)
		var region: String?
		var defaultURL: String?
		var problem: String?
		switch provider {
		case .anthropic:
			defaultURL = "https://api.anthropic.com"
		case .bedrock, .mantle:
			region = settings.value("AWS_REGION") ?? settings.value("AWS_DEFAULT_REGION") ?? "us-east-1"
			if provider == .bedrock {
				defaultURL = "https://bedrock-runtime.\(region!).amazonaws.com"
			}
		case .vertex:
			region = settings.value("CLOUD_ML_REGION")
			if settings.value("ANTHROPIC_VERTEX_PROJECT_ID") == nil {
				problem = "ANTHROPIC_VERTEX_PROJECT_ID Is Not Set."
			}
		case .foundry:
			if let resource = settings.value("ANTHROPIC_FOUNDRY_RESOURCE") {
				defaultURL = "https://\(resource).services.ai.azure.com/anthropic"
			}
		case .anthropicAWS:
			break
		}

		if let string = override ?? defaultURL {
			if let url = URL(string: string), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil {
				self.baseURL = url
				if scheme == "http" && !["localhost", "127.0.0.1", "::1"].contains(url.host!) {
					notes.append("Upstream \(provider.baseURLVariable) Is Plain HTTP; Credentials Travel Unencrypted to It.")
				}
			} else {
				self.baseURL = nil
				problem = "\(provider.baseURLVariable) Is Not a Valid http(s) URL."
			}
		} else {
			self.baseURL = nil
			if provider != .vertex {
				problem = problem ?? "Set \(provider.baseURLVariable)\(provider == .foundry ? " or ANTHROPIC_FOUNDRY_RESOURCE" : "") for \(provider.displayName)."
			}
		}
		self.region = region
		self.problem = problem
		self.notes = notes
	}

	var displayUpstream: String {
		if let baseURL {
			return baseURL.absoluteString
		}
		if provider == .vertex {
			return "https://<location>-aiplatform.googleapis.com/v1"
		}
		return "—"
	}

	/// Builds the upstream URL for an origin-form request target. Anything that could steer the request
	/// (and the credentials attached to it) somewhere other than the configured upstream is rejected.
	func url(forTarget target: String) -> Result<URL, ProxyRequestError> {
		if let problem {
			return .failure(ProxyRequestError(status: 502, message: problem))
		}
		guard target.hasPrefix("/"), !target.hasPrefix("//") else {
			return .failure(ProxyRequestError(status: 400, message: "Only origin-form request targets are accepted."))
		}

		let path: String
		let query: String?
		if let questionMark = target.firstIndex(of: "?") {
			path = String(target[..<questionMark])
			query = String(target[target.index(after: questionMark)...])
		} else {
			path = target
			query = nil
		}
		guard Self.isValidEncoded(path, allowingQueryCharacters: false),
			  query.map({ Self.isValidEncoded($0, allowingQueryCharacters: true) }) ?? true else {
			return .failure(ProxyRequestError(status: 400, message: "Malformed request target."))
		}
		for segment in path.split(separator: "/", omittingEmptySubsequences: false) {
			let decoded = String(segment).removingPercentEncoding ?? String(segment)
			if decoded == "." || decoded == ".." || decoded.contains("/") || decoded.contains("\\") {
				return .failure(ProxyRequestError(status: 400, message: "Dot or encoded-slash path segments are not accepted."))
			}
		}

		var components = URLComponents()
		var basePath: String
		if let baseURL, let base = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) {
			components.scheme = base.scheme
			components.percentEncodedHost = base.percentEncodedHost
			components.port = base.port
			basePath = base.percentEncodedPath
		} else {
			// Default Vertex endpoint: the host follows the location Claude Code put in the path
			// (it can differ per model via VERTEX_REGION_CLAUDE_*).
			guard let location = Self.vertexLocation(in: path) else {
				return .failure(ProxyRequestError(status: 400, message: "Vertex request path has no valid location."))
			}
			components.scheme = "https"
			components.host = location == "global" ? "aiplatform.googleapis.com" : "\(location)-aiplatform.googleapis.com"
			basePath = "/v1"
		}
		while basePath.hasSuffix("/") {
			basePath.removeLast()
		}
		components.percentEncodedPath = basePath + path
		components.percentEncodedQuery = query
		guard let url = components.url else {
			return .failure(ProxyRequestError(status: 400, message: "Malformed request target."))
		}
		return .success(url)
	}

	private static func vertexLocation(in path: String) -> String? {
		let segments = path.split(separator: "/").map(String.init)
		guard let index = segments.firstIndex(of: "locations"), index + 1 < segments.count else {
			return nil
		}
		let location = segments[index + 1]
		let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
		guard !location.isEmpty, location.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
			return nil
		}
		return location
	}

	/// RFC 3986 pchar / query characters with well-formed percent escapes only.
	private static func isValidEncoded(_ string: String, allowingQueryCharacters: Bool) -> Bool {
		var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/")
		if allowingQueryCharacters {
			allowed.insert(charactersIn: "?")
		}
		let scalars = Array(string.unicodeScalars)
		var index = 0
		while index < scalars.count {
			let scalar = scalars[index]
			if scalar == "%" {
				guard index + 2 < scalars.count,
					  scalars[index + 1].properties.isASCIIHexDigit,
					  scalars[index + 2].properties.isASCIIHexDigit else {
					return false
				}
				index += 3
				continue
			}
			guard allowed.contains(scalar) else {
				return false
			}
			index += 1
		}
		return true
	}
}

enum ClientProfileBuilder {
	/// Non-secret variables a client's Claude Code needs to address the same models/projects as the host.
	/// Whitelist only: anything not listed here never leaves the host.
	private static let passthroughVariables: Set<String> = [
		"ANTHROPIC_MODEL",
		"ANTHROPIC_DEFAULT_MODEL",
		"ANTHROPIC_DEFAULT_OPUS_MODEL",
		"ANTHROPIC_DEFAULT_SONNET_MODEL",
		"ANTHROPIC_DEFAULT_HAIKU_MODEL",
		"ANTHROPIC_DEFAULT_FABLE_MODEL",
		"ANTHROPIC_SMALL_FAST_MODEL",
		"ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION",
		"CLAUDE_CODE_SUBAGENT_MODEL",
		"ANTHROPIC_BETAS",
		"CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS",
		"ANTHROPIC_BEDROCK_REGION_PREFIX",
		"ANTHROPIC_VERTEX_PROJECT_ID",
		"CLOUD_ML_REGION",
		"ANTHROPIC_AWS_WORKSPACE_ID",
	]
	private static let passthroughPrefixes = ["VERTEX_REGION_CLAUDE_"]

	static func build(name: String, plan: UpstreamPlan, settings: ResolvedSettings, secrets: [String]) -> ClientProfile {
		var env: [String: String] = [:]
		let provider = plan.provider

		// Make the client's provider selection match ours, overriding whatever it had.
		for other in Provider.cloud where other != provider {
			env[other.switchVariable!] = ""
		}
		if let switchVariable = provider.switchVariable, let skipVariable = provider.skipAuthVariable {
			env[switchVariable] = "1"
			env[skipVariable] = "1"
		}

		// Neutralize client-side credentials so nothing of the client's leaks upstream and Claude Code doesn't ask to log in.
		switch provider {
		case .anthropic:
			env["ANTHROPIC_AUTH_TOKEN"] = ClaudeProxyProtocol.placeholderToken
			env["ANTHROPIC_API_KEY"] = ""
		case .bedrock, .mantle:
			env["AWS_BEARER_TOKEN_BEDROCK"] = ""
			env["AWS_REGION"] = plan.region
		case .anthropicAWS:
			env["ANTHROPIC_AWS_API_KEY"] = ""
		case .foundry:
			env["ANTHROPIC_FOUNDRY_API_KEY"] = ""
			env["ANTHROPIC_FOUNDRY_AUTH_TOKEN"] = ""
		case .vertex:
			break
		}

		for (variable, setting) in settings.env where !setting.value.isEmpty {
			guard passthroughVariables.contains(variable) || passthroughPrefixes.contains(where: { variable.hasPrefix($0) }) else {
				continue
			}
			guard !secrets.contains(where: { setting.value.contains($0) }) else {
				continue
			}
			env[variable] = setting.value
		}

		let digestInput = provider.rawValue + "\n" + env.keys.sorted().map { "\($0)=\(env[$0]!)" }.joined(separator: "\n")
		let digest = SHA256.hash(data: Data(digestInput.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
		return ClientProfile(v: ClaudeProxyProtocol.version, pv: digest, name: name, provider: provider.rawValue, baseURLVariable: provider.baseURLVariable, env: env)
	}
}
