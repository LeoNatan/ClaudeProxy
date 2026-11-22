import CryptoKit
import Foundation

struct AWSCredentials: Sendable {
	let accessKeyId: String
	let secretAccessKey: String
	let sessionToken: String?
	let expiration: Date?
}

/// AWS Signature Version 4 for non-S3 services (path segments are encoded a second time).
enum SigV4 {
	static func sign(_ request: inout URLRequest, body: Data, credentials: AWSCredentials, region: String, service: String, date: Date = Date()) {
		guard let url = request.url,
			  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			  let host = components.percentEncodedHost else {
			return
		}

		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(identifier: "UTC")
		formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
		let amzDate = formatter.string(from: date)
		let dateStamp = String(amzDate.prefix(8))
		let payloadHash = hex(SHA256.hash(data: body))

		var hostHeader = host
		if let port = components.port, !((components.scheme == "https" && port == 443) || (components.scheme == "http" && port == 80)) {
			hostHeader += ":\(port)"
		}
		var headers = [
			"host": hostHeader,
			"x-amz-date": amzDate,
			"x-amz-content-sha256": payloadHash,
		]
		if let sessionToken = credentials.sessionToken {
			headers["x-amz-security-token"] = sessionToken
		}
		let signedNames = headers.keys.sorted()
		let canonicalHeaders = signedNames.map { "\($0):\(headers[$0]!.trimmingCharacters(in: .whitespaces))\n" }.joined()
		let signedHeaders = signedNames.joined(separator: ";")

		let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
		let canonicalURI = path.split(separator: "/", omittingEmptySubsequences: false).map { uriEncode(String($0)) }.joined(separator: "/")
		let canonicalRequest = [
			request.httpMethod ?? "GET",
			canonicalURI,
			canonicalQuery(components.percentEncodedQuery),
			canonicalHeaders,
			signedHeaders,
			payloadHash,
		].joined(separator: "\n")

		let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
		let stringToSign = [
			"AWS4-HMAC-SHA256",
			amzDate,
			scope,
			hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
		].joined(separator: "\n")

		var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
		for part in [dateStamp, region, service, "aws4_request"] {
			key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
		}
		let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))

		request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
		request.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-Sha256")
		if let sessionToken = credentials.sessionToken {
			request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
		}
		request.setValue("AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
	}

	private static func canonicalQuery(_ query: String?) -> String {
		guard let query, !query.isEmpty else {
			return ""
		}
		let pairs = query.split(separator: "&").map { item -> (String, String) in
			let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
			let name = parts[0].removingPercentEncoding ?? parts[0]
			let value = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : ""
			return (uriEncode(name), uriEncode(value))
		}
		return pairs.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
	}

	private static func uriEncode(_ string: String) -> String {
		var result = ""
		for byte in string.utf8 {
			switch byte {
			case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
				 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
				result.append(Character(UnicodeScalar(byte)))
			default:
				result += String(format: "%%%02X", byte)
			}
		}
		return result
	}

	private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
		bytes.map { String(format: "%02x", $0) }.joined()
	}
}
