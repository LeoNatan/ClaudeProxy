import Foundation
import Network
import os

private let logger = Logger(subsystem: "com.leonatan.ClaudeProxyServer", category: "proxy")

private struct HTTPRequest {
	let method: String
	let target: String
	let version: String
	let headers: [(name: String, value: String)]
	let body: Data

	func header(_ name: String) -> String? {
		headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
	}

	var keepAlive: Bool {
		let connection = header("Connection")?.lowercased() ?? ""
		return version == "HTTP/1.0" ? connection.contains("keep-alive") : !connection.contains("close")
	}
}

private struct ParseError: Error {
	let status: Int
}

/// Per-request state shared between the upstream callbacks; only touched on the connection queue.
private final class Exchange: @unchecked Sendable {
	var redactor: SecretRedactor
	var headersSent = false
	var retrying = false
	var isHeadLike = false

	init(secrets: [String]) {
		redactor = SecretRedactor(secrets: secrets)
	}
}

/// One inbound HTTP/1.1 connection from a client. Requests are handled one at a time; bodies are passed through untouched.
final class ProxyConnection: @unchecked Sendable {
	private static let maxHeaderBytes = 64 * 1024
	private static let maxBodyBytes = 64 * 1024 * 1024
	/// Hop-by-hop headers, plus everything carrying the client's own identity or credentials.
	private static let droppedRequestHeaders: Set<String> = [
		"connection", "keep-alive", "proxy-connection", "proxy-authorization", "proxy-authenticate", "te", "trailer",
		"transfer-encoding", "upgrade", "host", "content-length", "expect", "accept-encoding",
		"authorization", "x-api-key", "cookie",
	]
	private static let droppedResponseHeaders: Set<String> = [
		"connection", "keep-alive", "proxy-connection", "transfer-encoding", "content-length", "content-encoding", "trailer", "upgrade", "set-cookie",
	]

	private let connection: NWConnection
	private let queue = DispatchQueue(label: "ClaudeProxy.connection")
	private let stateProvider: @Sendable () -> ServerState?
	private var buffer = Data()
	private var busy = false
	private var closed = false
	private var sentContinue = false
	private var currentTask: URLSessionDataTask?
	var onClose: (@Sendable () -> Void)?

	init(connection: NWConnection, stateProvider: @escaping @Sendable () -> ServerState?) {
		self.connection = connection
		self.stateProvider = stateProvider
	}

	func start() {
		connection.stateUpdateHandler = { [weak self] state in
			switch state {
			case .failed, .cancelled:
				guard let self else {
					return
				}
				self.queue.async { self.close() }
			default:
				break
			}
		}
		connection.start(queue: queue)
		receive()
	}

	private func receive() {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
			guard let self else {
				return
			}
			if let data, !data.isEmpty {
				buffer.append(data)
				if !busy {
					processBuffer()
				}
			}
			if isComplete || error != nil {
				// Client went away (e.g. Esc in Claude Code): stop the upstream request too.
				close()
				return
			}
			if !closed {
				receive()
			}
		}
	}

	private func close() {
		guard !closed else {
			return
		}
		closed = true
		currentTask?.cancel()
		currentTask = nil
		connection.cancel()
		onClose?()
		onClose = nil
	}

	// MARK: Parsing

	private func processBuffer() {
		guard !busy, !closed else {
			return
		}
		do {
			guard let (request, consumed) = try parseRequest() else {
				return
			}
			buffer = Data(buffer.dropFirst(consumed))
			sentContinue = false
			busy = true
			handle(request)
		} catch let error as ParseError {
			sendSimple(status: error.status, message: "Malformed request.", keepAlive: false)
		} catch {
			close()
		}
	}

	private func parseRequest() throws -> (HTTPRequest, Int)? {
		let separator = Data("\r\n\r\n".utf8)
		guard let headEnd = buffer.range(of: separator) else {
			if buffer.count > Self.maxHeaderBytes {
				throw ParseError(status: 431)
			}
			return nil
		}
		let head = String(decoding: buffer[buffer.startIndex..<headEnd.lowerBound], as: UTF8.self)
		var lines = head.components(separatedBy: "\r\n")
		let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true).map(String.init)
		guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
			throw ParseError(status: 400)
		}
		var headers: [(String, String)] = []
		for line in lines {
			guard let colon = line.firstIndex(of: ":") else {
				throw ParseError(status: 400)
			}
			headers.append((line[..<colon].trimmingCharacters(in: .whitespaces), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
		}
		let partial = HTTPRequest(method: requestLine[0].uppercased(), target: requestLine[1], version: requestLine[2], headers: headers, body: Data())
		let bodyStart = headEnd.upperBound

		let body: Data
		let end: Int
		if partial.header("Transfer-Encoding")?.lowercased().contains("chunked") == true {
			guard let (decoded, decodedEnd) = try decodeChunked(from: bodyStart) else {
				sendContinueIfNeeded(partial)
				return nil
			}
			body = decoded
			end = decodedEnd
		} else if let lengthString = partial.header("Content-Length") {
			guard let length = Int(lengthString), length >= 0, length <= Self.maxBodyBytes else {
				throw ParseError(status: 413)
			}
			guard buffer.endIndex - bodyStart >= length else {
				sendContinueIfNeeded(partial)
				return nil
			}
			body = Data(buffer[bodyStart..<(bodyStart + length)])
			end = bodyStart + length
		} else {
			body = Data()
			end = bodyStart
		}
		let request = HTTPRequest(method: partial.method, target: partial.target, version: partial.version, headers: headers, body: body)
		return (request, end - buffer.startIndex)
	}

	private func decodeChunked(from start: Int) throws -> (Data, Int)? {
		let crlf = Data("\r\n".utf8)
		var index = start
		var body = Data()
		while true {
			guard let lineEnd = buffer.range(of: crlf, in: index..<buffer.endIndex) else {
				return nil
			}
			let sizeLine = String(decoding: buffer[index..<lineEnd.lowerBound], as: UTF8.self)
			guard let size = Int(sizeLine.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? "", radix: 16), size >= 0 else {
				throw ParseError(status: 400)
			}
			index = lineEnd.upperBound
			if size == 0 {
				// Skip trailers up to the terminating empty line.
				while true {
					guard let trailerEnd = buffer.range(of: crlf, in: index..<buffer.endIndex) else {
						return nil
					}
					let isEmpty = trailerEnd.lowerBound == index
					index = trailerEnd.upperBound
					if isEmpty {
						return (body, index)
					}
				}
			}
			guard body.count + size <= Self.maxBodyBytes else {
				throw ParseError(status: 413)
			}
			guard buffer.endIndex - index >= size + 2 else {
				return nil
			}
			body.append(buffer[index..<(index + size)])
			index += size + 2
		}
	}

	private func sendContinueIfNeeded(_ request: HTTPRequest) {
		guard !sentContinue, request.header("Expect")?.lowercased() == "100-continue" else {
			return
		}
		sentContinue = true
		connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
	}

	// MARK: Handling

	private func handle(_ request: HTTPRequest) {
		guard let state = stateProvider() else {
			sendSimple(status: 503, message: "ClaudeProxy Server is still loading settings.", keepAlive: request.keepAlive)
			return
		}

		let pathOnly = request.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.target
		if pathOnly == ClaudeProxyProtocol.infoPath {
			let body = (try? JSONEncoder().encode(state.profile)) ?? Data("{}".utf8)
			sendRaw(status: 200, contentType: "application/json", body: body, keepAlive: request.keepAlive)
			return
		}
		if request.method == "CONNECT" {
			sendSimple(status: 405, message: "CONNECT is not supported; point Claude Code's base URL at the ClaudeProxy client.", keepAlive: false)
			return
		}

		let url: URL
		switch state.plan.url(forTarget: request.target) {
		case let .success(value):
			url = value
		case let .failure(error):
			sendSimple(status: error.status, message: "ClaudeProxy: \(error.message)", keepAlive: request.keepAlive)
			return
		}

		var upstreamRequest = URLRequest(url: url)
		upstreamRequest.httpMethod = request.method
		for header in request.headers {
			let name = header.name.lowercased()
			if Self.droppedRequestHeaders.contains(name) || name.hasPrefix("x-amz-") || name.hasPrefix("x-goog-") || name.hasPrefix("proxy-") {
				continue
			}
			upstreamRequest.addValue(header.value, forHTTPHeaderField: header.name)
		}
		if !request.body.isEmpty || ["POST", "PUT", "PATCH"].contains(request.method) {
			upstreamRequest.httpBody = request.body
		}

		send(upstreamRequest, body: request.body, request: request, state: state, attempt: 0)
	}

	private func send(_ unauthorized: URLRequest, body: Data, request: HTTPRequest, state: ServerState, attempt: Int) {
		DispatchQueue.global(qos: .userInitiated).async { [self] in
			var authorized = unauthorized
			do {
				try state.credentials.authorize(&authorized, body: body)
			} catch let error as CredentialError {
				queue.async { self.sendSimple(status: 502, message: "ClaudeProxy: \(error.message)", keepAlive: request.keepAlive) }
				return
			} catch {
				queue.async { self.sendSimple(status: 502, message: "ClaudeProxy: credential error.", keepAlive: request.keepAlive) }
				return
			}
			let signed = authorized
			queue.async { self.start(signed, unauthorized: unauthorized, body: body, request: request, state: state, attempt: attempt) }
		}
	}

	private func start(_ authorized: URLRequest, unauthorized: URLRequest, body: Data, request: HTTPRequest, state: ServerState, attempt: Int) {
		guard !closed else {
			return
		}

		let exchange = Exchange(secrets: state.credentials.secrets)
		let keepAlive = request.keepAlive
		let logPath = String(request.target.split(separator: "?").first ?? "")

		let callbacks = UpstreamForwarder.Callbacks(
			response: { [weak self] response in
				guard let self else {
					return false
				}
				if (response.statusCode == 401 || response.statusCode == 403) && attempt == 0 && state.credentials.invalidate() {
					exchange.retrying = true
					return false
				}
				queue.async {
					self.sendHead(response, exchange: exchange, request: request, keepAlive: keepAlive)
				}
				logger.info("\(request.method, privacy: .public) \(logPath, privacy: .public) → \(response.statusCode, privacy: .public)")
				return true
			},
			data: { [weak self] data in
				guard let self else {
					return
				}
				queue.async {
					guard !exchange.isHeadLike else {
						return
					}
					self.sendChunk(exchange.redactor.process(data))
				}
			},
			complete: { [weak self] error in
				guard let self else {
					return
				}
				queue.async {
					self.currentTask = nil
					if exchange.retrying {
						self.send(unauthorized, body: body, request: request, state: state, attempt: attempt + 1)
						return
					}
					if !exchange.headersSent {
						let message = (error as? URLError).map { "ClaudeProxy: upstream request failed (\($0.code.rawValue): \($0.localizedDescription))." } ?? "ClaudeProxy: upstream request failed."
						self.sendSimple(status: 502, message: message, keepAlive: keepAlive)
						return
					}
					if error != nil {
						// Mid-stream failure: HTTP/1.1 can only signal it by closing.
						self.close()
						return
					}
					if !exchange.isHeadLike {
						self.sendChunk(exchange.redactor.flush())
						self.connection.send(content: Data("0\r\n\r\n".utf8), completion: .idempotent)
					}
					self.finishExchange(keepAlive: keepAlive)
				}
			}
		)
		currentTask = state.forwarder.start(authorized, callbacks: callbacks)
	}

	private func sendHead(_ response: HTTPURLResponse, exchange: Exchange, request: HTTPRequest, keepAlive: Bool) {
		exchange.headersSent = true
		exchange.isHeadLike = request.method == "HEAD" || response.statusCode == 204 || response.statusCode == 304
		var head = "HTTP/1.1 \(response.statusCode) \(Self.reasonPhrase(response.statusCode))\r\n"
		for (key, value) in response.allHeaderFields {
			guard let name = key as? String, let value = value as? String, !Self.droppedResponseHeaders.contains(name.lowercased()) else {
				continue
			}
			head += "\(name): \(exchange.redactor.redact(value).replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: ""))\r\n"
		}
		head += exchange.isHeadLike ? "Content-Length: 0\r\n" : "Transfer-Encoding: chunked\r\n"
		head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
		connection.send(content: Data(head.utf8), completion: .idempotent)
	}

	private func sendChunk(_ data: Data) {
		guard !data.isEmpty, !closed else {
			return
		}
		var chunk = Data(String(data.count, radix: 16).utf8)
		chunk.append(Data("\r\n".utf8))
		chunk.append(data)
		chunk.append(Data("\r\n".utf8))
		connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
			if error != nil {
				guard let self else {
					return
				}
				self.queue.async { self.close() }
			}
		})
	}

	private func finishExchange(keepAlive: Bool) {
		busy = false
		if keepAlive {
			processBuffer()
		} else {
			connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
				guard let self else {
					return
				}
				self.queue.async { self.close() }
			})
		}
	}

	/// An Anthropic-shaped error so Claude Code shows the message.
	private func sendSimple(status: Int, message: String, keepAlive: Bool) {
		let payload: [String: Any] = ["type": "error", "error": ["type": status == 502 ? "api_error" : "invalid_request_error", "message": message]]
		let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
		sendRaw(status: status, contentType: "application/json", body: body, keepAlive: keepAlive)
	}

	private func sendRaw(status: Int, contentType: String, body: Data, keepAlive: Bool) {
		var head = "HTTP/1.1 \(status) \(Self.reasonPhrase(status))\r\n"
		head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
		head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
		var data = Data(head.utf8)
		data.append(body)
		connection.send(content: data, completion: .idempotent)
		finishExchange(keepAlive: keepAlive)
	}

	private static func reasonPhrase(_ status: Int) -> String {
		HTTPURLResponse.localizedString(forStatusCode: status).capitalized
	}
}
