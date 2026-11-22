import Foundation

/// Values shared between ClaudeProxy Server and Client. Keep in sync with the client's copy.
enum ClaudeProxyProtocol {
	static let serviceType = "_claudeproxy._tcp"
	static let version = 1
	static let infoPath = "/_claudeproxy/info"
	static let defaultServerPort: UInt16 = 52880
	static let defaultClientPort: UInt16 = 52881
	/// Sent by clients in place of a real credential; the server always replaces it.
	static let placeholderToken = "claudeproxy-placeholder"
}

/// Handshake payload served at `ClaudeProxyProtocol.infoPath`. Never contains secrets.
struct ClientProfile: Codable, Sendable, Equatable {
	var v: Int
	/// Profile version: a hash of `provider` + `env`; clients re-install when it changes.
	var pv: String
	var name: String
	var provider: String
	/// The env variable the client points at its local forwarder.
	var baseURLVariable: String
	/// Non-secret env the client writes into Claude Code's settings (empty string = unset).
	var env: [String: String]
}
