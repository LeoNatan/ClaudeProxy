import Foundation
import Security

/// Outbound proxy and TLS settings resolved from Claude Code's variables. An explicit HTTPS_PROXY / HTTP_PROXY
/// (minus NO_PROXY hosts) is used as-is; otherwise traffic uses normal system networking.
final class NetworkConfiguration: @unchecked Sendable {
	let proxyURL: URL?
	let noProxy: [String]
	let extraAnchors: [SecCertificate]
	let clientIdentity: SecIdentity?
	let rejectUnauthorized: Bool
	let notes: [String]

	init(settings: ResolvedSettings) {
		var notes: [String] = []

		let proxyString = ["https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY"].lazy.compactMap { settings.value($0) }.first
		if let proxyString {
			if let url = URL(string: proxyString), let scheme = url.scheme?.lowercased(), url.host != nil, ["http", "https"].contains(scheme) {
				proxyURL = url
				if scheme == "https" {
					notes.append("HTTPS Proxy URLs Are Used as Plain HTTP CONNECT Proxies.")
				}
			} else {
				proxyURL = nil
				notes.append("Proxy URL \"\(proxyString)\" Is Not a Valid http(s) URL and Was Ignored.")
			}
		} else {
			proxyURL = nil
		}
		noProxy = (settings.value("NO_PROXY") ?? settings.value("no_proxy") ?? "")
			.split(separator: ",")
			.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
			.filter { !$0.isEmpty }

		var anchors: [SecCertificate] = []
		if let path = settings.value("NODE_EXTRA_CA_CERTS") {
			let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
			if let pem = try? String(contentsOf: url, encoding: .utf8) {
				anchors = Self.certificates(fromPEM: pem)
				if anchors.isEmpty {
					notes.append("NODE_EXTRA_CA_CERTS Contains No Readable Certificates.")
				}
			} else {
				notes.append("NODE_EXTRA_CA_CERTS File Can't Be Read.")
			}
		}
		if let store = settings.value("CLAUDE_CODE_CERT_STORE"), !store.lowercased().contains("system") {
			notes.append("CLAUDE_CODE_CERT_STORE=\(store): The macOS System Trust Store Is Used in Place of Node's Bundled CAs.")
		}
		extraAnchors = anchors

		rejectUnauthorized = settings.value("NODE_TLS_REJECT_UNAUTHORIZED") != "0"
		if !rejectUnauthorized {
			notes.append("NODE_TLS_REJECT_UNAUTHORIZED=0: Upstream Certificates Are NOT Verified.")
		}

		if let certificatePath = settings.value("CLAUDE_CODE_CLIENT_CERT"), let keyPath = settings.value("CLAUDE_CODE_CLIENT_KEY") {
			clientIdentity = Self.identity(certificatePath: certificatePath, keyPath: keyPath, passphrase: settings.value("CLAUDE_CODE_CLIENT_KEY_PASSPHRASE"))
			if clientIdentity == nil {
				notes.append("Client Certificate (CLAUDE_CODE_CLIENT_CERT/KEY) Could Not Be Loaded.")
			}
		} else {
			clientIdentity = nil
		}
		self.notes = notes
	}

	var summary: String? {
		var parts: [String] = []
		if let proxyURL, let host = proxyURL.host {
			parts.append("Proxy \(host):\(proxyURL.port ?? 80)")
		}
		if !extraAnchors.isEmpty {
			parts.append("\(extraAnchors.count) Extra CA(s)")
		}
		if clientIdentity != nil {
			parts.append("Client Certificate")
		}
		return parts.isEmpty ? nil : parts.joined(separator: ", ")
	}

	func shouldBypassProxy(host: String) -> Bool {
		let host = host.lowercased()
		for entry in noProxy {
			if entry == "*" {
				return true
			}
			var pattern = entry
			if let colon = pattern.lastIndex(of: ":"), !pattern.contains("]") || pattern.hasSuffix("]") == false {
				pattern = String(pattern[..<colon])
			}
			pattern = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "*."))
			if host == pattern || host.hasSuffix("." + pattern) {
				return true
			}
		}
		return false
	}

	/// connectionProxyDictionary for URLSession. nil means normal system networking (system proxy/PAC, VPN routing and DNS),
	/// so upstreams only reachable through a VPN work as they do for everything else on this Mac.
	func proxyDictionary(useProxy: Bool) -> [AnyHashable: Any]? {
		guard useProxy, let proxyURL, let host = proxyURL.host else {
			return nil
		}
		let port = proxyURL.port ?? (proxyURL.scheme?.lowercased() == "https" ? 443 : 80)
		return [
			"HTTPEnable": 1,
			"HTTPProxy": host,
			"HTTPPort": port,
			"HTTPSEnable": 1,
			"HTTPSProxy": host,
			"HTTPSPort": port,
		]
	}

	var proxyCredential: URLCredential? {
		guard let user = proxyURL?.user(percentEncoded: false) else {
			return nil
		}
		return URLCredential(user: user, password: proxyURL?.password(percentEncoded: false) ?? "", persistence: .forSession)
	}

	func evaluate(_ trust: SecTrust) -> Bool {
		guard rejectUnauthorized else {
			return true
		}
		if !extraAnchors.isEmpty {
			SecTrustSetAnchorCertificates(trust, extraAnchors as CFArray)
			SecTrustSetAnchorCertificatesOnly(trust, false)
		}
		return SecTrustEvaluateWithError(trust, nil)
	}

	// MARK: PEM

	private static func certificates(fromPEM pem: String) -> [SecCertificate] {
		var certificates: [SecCertificate] = []
		let begin = "-----BEGIN CERTIFICATE-----"
		let end = "-----END CERTIFICATE-----"
		var remainder = pem[...]
		while let start = remainder.range(of: begin), let stop = remainder.range(of: end, range: start.upperBound..<remainder.endIndex) {
			let base64 = remainder[start.upperBound..<stop.lowerBound].components(separatedBy: .whitespacesAndNewlines).joined()
			if let der = Data(base64Encoded: base64), let certificate = SecCertificateCreateWithData(nil, der as CFData) {
				certificates.append(certificate)
			}
			remainder = remainder[stop.upperBound...]
		}
		return certificates
	}

	/// Builds an in-memory identity from PEM files by packaging them as PKCS#12 with /usr/bin/openssl.
	private static func identity(certificatePath: String, keyPath: String, passphrase: String?) -> SecIdentity? {
		let fileManager = FileManager.default
		let outputURL = fileManager.temporaryDirectory.appendingPathComponent("claudeproxy-\(UUID().uuidString).p12")
		guard fileManager.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
			return nil
		}
		defer {
			try? fileManager.removeItem(at: outputURL)
		}

		let exportPassword = UUID().uuidString
		var environment = ["CLAUDEPROXY_OUT": exportPassword]
		var arguments = [
			"pkcs12", "-export",
			"-in", (certificatePath as NSString).expandingTildeInPath,
			"-inkey", (keyPath as NSString).expandingTildeInPath,
			"-out", outputURL.path,
			"-passout", "env:CLAUDEPROXY_OUT",
			"-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1",
		]
		if let passphrase {
			environment["CLAUDEPROXY_IN"] = passphrase
			arguments += ["-passin", "env:CLAUDEPROXY_IN"]
		}
		guard let result = ProcessRunner.run("/usr/bin/openssl", arguments, environment: environment, timeout: 20), result.status == 0,
			  let data = try? Data(contentsOf: outputURL) else {
			return nil
		}

		let options: [String: Any] = [
			kSecImportExportPassphrase as String: exportPassword,
			kSecImportToMemoryOnly as String: true,
		]
		var items: CFArray?
		guard SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess,
			  let first = (items as? [[String: Any]])?.first,
			  let identity = first[kSecImportItemIdentity as String] else {
			return nil
		}
		return (identity as! SecIdentity)
	}
}

/// Removes exact occurrences of secrets from a byte stream, holding back only a tail that could be
/// the start of a secret split across chunks.
struct SecretRedactor {
	private let secrets: [Data]
	private let replacement = Data("[REDACTED]".utf8)
	private var pending = Data()

	init(secrets: [String]) {
		self.secrets = secrets.map { Data($0.utf8) }.filter { !$0.isEmpty }
	}

	mutating func process(_ chunk: Data) -> Data {
		guard !secrets.isEmpty else {
			return chunk
		}
		var buffer = pending + chunk
		pending = Data()
		buffer = redact(buffer)

		// Hold back the longest suffix that is a proper prefix of any secret.
		let maxHold = min(buffer.count, (secrets.map(\.count).max() ?? 1) - 1)
		var hold = 0
		if maxHold > 0 {
			for length in stride(from: maxHold, through: 1, by: -1) {
				let suffix = buffer.suffix(length)
				if secrets.contains(where: { $0.count > length && $0.prefix(length) == suffix }) {
					hold = length
					break
				}
			}
		}
		if hold > 0 {
			pending = Data(buffer.suffix(hold))
			buffer = Data(buffer.prefix(buffer.count - hold))
		}
		return buffer
	}

	mutating func flush() -> Data {
		defer { pending = Data() }
		return pending
	}

	func redact(_ string: String) -> String {
		var result = string
		for secret in secrets {
			result = result.replacingOccurrences(of: String(decoding: secret, as: UTF8.self), with: "[REDACTED]")
		}
		return result
	}

	private func redact(_ data: Data) -> Data {
		var result = Data(data)
		for secret in secrets {
			var searchStart = result.startIndex
			while let range = result.range(of: secret, in: searchStart..<result.endIndex) {
				result.replaceSubrange(range, with: replacement)
				searchStart = range.lowerBound + replacement.count
			}
		}
		return result
	}
}
