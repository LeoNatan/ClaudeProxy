import Foundation

/// Values shared between ClaudeProxy Host and Client. Keep in sync with the client's copy.
enum ClaudeProxyProtocol {
	/// Clients advertise this; the host browses for it and connects out to each client.
	static let clientServiceType = "_claudeproxy-client._tcp"
	static let version = 2
	static let infoPath = "/_claudeproxy/info"
	// Ports stay below macOS's ephemeral range (49152–65535), where outgoing connections can already hold them.

	/// Port on 127.0.0.1 that Claude Code on a client connects to.
	static let defaultClientPort: UInt16 = 41821
	/// Port a client listens on for the host's connections.
	static let defaultClientNetworkPort: UInt16 = 41822
	/// Sent by clients in place of a real credential; the host always replaces it.
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
