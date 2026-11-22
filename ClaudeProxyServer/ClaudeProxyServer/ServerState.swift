import Foundation

/// One generation of resolved configuration. Replaced wholesale on reload; in-flight requests keep theirs.
final class ServerState: Sendable {
	let settings: ResolvedSettings
	let plan: UpstreamPlan
	let credentials: CredentialStore
	let network: NetworkConfiguration
	let forwarder: UpstreamForwarder
	let profile: ClientProfile

	init(settings: ResolvedSettings, serviceName: String) {
		self.settings = settings
		plan = UpstreamPlan(settings: settings)
		credentials = CredentialStore(settings: settings, plan: plan)
		network = NetworkConfiguration(settings: settings)
		forwarder = UpstreamForwarder(network: network)
		profile = ClientProfileBuilder.build(name: serviceName, plan: plan, settings: settings, secrets: credentials.secrets)
	}

	var problems: [String] {
		[plan.problem, credentials.problem].compactMap { $0 }
	}

	var notes: [String] {
		plan.notes + network.notes + settings.notes
	}

	/// Connection-related variables worth showing in the menu.
	static let displayedVariables: [String] = [
		"CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_USE_MANTLE", "CLAUDE_CODE_USE_ANTHROPIC_AWS",
		"CLAUDE_CODE_SKIP_BEDROCK_AUTH", "CLAUDE_CODE_SKIP_VERTEX_AUTH", "CLAUDE_CODE_SKIP_FOUNDRY_AUTH", "CLAUDE_CODE_SKIP_MANTLE_AUTH", "CLAUDE_CODE_SKIP_ANTHROPIC_AWS_AUTH",
		"ANTHROPIC_BASE_URL", "ANTHROPIC_BEDROCK_BASE_URL", "ANTHROPIC_BEDROCK_MANTLE_BASE_URL", "ANTHROPIC_VERTEX_BASE_URL", "ANTHROPIC_FOUNDRY_BASE_URL", "ANTHROPIC_AWS_BASE_URL",
		"ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "AWS_BEARER_TOKEN_BEDROCK", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_PROFILE",
		"ANTHROPIC_AWS_API_KEY", "ANTHROPIC_FOUNDRY_API_KEY", "ANTHROPIC_FOUNDRY_AUTH_TOKEN", "ANTHROPIC_FOUNDRY_RESOURCE",
		"AWS_REGION", "AWS_DEFAULT_REGION", "ANTHROPIC_VERTEX_PROJECT_ID", "CLOUD_ML_REGION", "ANTHROPIC_AWS_WORKSPACE_ID",
		"ANTHROPIC_CUSTOM_HEADERS", "ANTHROPIC_BETAS",
		"HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "NO_PROXY", "no_proxy",
		"NODE_EXTRA_CA_CERTS", "CLAUDE_CODE_CERT_STORE", "NODE_TLS_REJECT_UNAUTHORIZED",
		"CLAUDE_CODE_CLIENT_CERT", "CLAUDE_CODE_CLIENT_KEY", "CLAUDE_CODE_CLIENT_KEY_PASSPHRASE",
		"ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL",
		"CLAUDE_CONFIG_DIR",
	]
	static let displayedKeys = ["apiKeyHelper", "awsCredentialExport", "awsAuthRefresh", "gcpAuthRefresh", "managedSourcesBehavior"]
}
