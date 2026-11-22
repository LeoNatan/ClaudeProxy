import Foundation
import Network

/// Accepts the connections a ClaudeProxy host opens to this client and keeps them until Claude Code needs one.
/// The client advertises itself over Bonjour so the host can find it; the host always connects out, which works
/// even when the host Mac blocks incoming connections.
final class HostConnectionPool: @unchecked Sendable {
	enum Status: Sendable {
		case stopped
		case listening(UInt16, advertised: Bool)
		case failed(String)
	}

	let serviceName: String
	/// Shared with `LocalForwarder`, so handed-out connections keep delivering events on the same serial queue.
	let queue = DispatchQueue(label: "ClaudeProxyClient.connections")
	private var listener: NWListener?
	private var port: UInt16 = 0
	private var generation = 0
	private var idle: [NWConnection] = []
	private var waiters: [(id: UUID, handler: @Sendable (NWConnection?) -> Void)] = []
	private var lastConnection: Date?
	var onStatus: (@Sendable (Status) -> Void)?
	/// Called when the set of idle host connections changes.
	var onChange: (@Sendable () -> Void)?

	init(serviceName: String) {
		self.serviceName = serviceName
	}

	/// Whether a host currently keeps connections open to this client.
	var hasHost: Bool {
		queue.sync { !idle.isEmpty || (lastConnection.map { Date().timeIntervalSince($0) < 15 } ?? false) }
	}

	func start(port: UInt16) {
		queue.async { [self] in
			self.port = port
			listen(advertise: true)
		}
	}

	/// Hands out one idle host connection (already established), waiting up to `timeout` for one to arrive.
	func take(timeout: TimeInterval, handler: @escaping @Sendable (NWConnection?) -> Void) {
		queue.async { [self] in
			if !idle.isEmpty {
				let connection = idle.removeFirst()
				onChange?()
				handler(connection)
				return
			}
			let id = UUID()
			waiters.append((id, handler))
			queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
				guard let self, let index = waiters.firstIndex(where: { $0.id == id }) else {
					return
				}
				waiters.remove(at: index).handler(nil)
			}
		}
	}

	// MARK: Listener (on `queue`)

	private func listen(advertise: Bool) {
		listener?.cancel()
		listener = nil
		generation += 1
		let port = port
		guard let nwPort = NWEndpoint.Port(rawValue: port), port > 0 else {
			onStatus?(.failed("Invalid port \(port)."))
			return
		}
		let tcp = NWProtocolTCP.Options()
		tcp.enableKeepalive = true
		tcp.keepaliveIdle = 30
		let parameters = NWParameters(tls: nil, tcp: tcp)
		parameters.allowLocalEndpointReuse = true
		let listener: NWListener
		do {
			listener = try NWListener(using: parameters, on: nwPort)
		} catch {
			onStatus?(.failed(error.localizedDescription))
			return
		}
		if advertise {
			listener.service = NWListener.Service(name: serviceName, type: ClaudeProxyProtocol.clientServiceType)
		}
		listener.stateUpdateHandler = { [weak self, weak listener] state in
			guard let self, let listener, listener === self.listener else {
				return
			}
			switch state {
			case .ready:
				onStatus?(.listening(port, advertised: advertise))
			case let .failed(error), let .waiting(error):
				// Bonjour registration can fail on its own (e.g. Local Network access not granted yet); the host
				// can still connect by address, so keep listening and try advertising again later.
				if case .dns = error, advertise {
					listen(advertise: false)
				} else {
					onStatus?(.failed(error.localizedDescription))
				}
				retryLater()
			default:
				break
			}
		}
		listener.newConnectionHandler = { [weak self] connection in
			self?.accept(connection)
		}
		self.listener = listener
		listener.start(queue: queue)
	}

	private func retryLater() {
		let current = generation
		queue.asyncAfter(deadline: .now() + 15) { [weak self] in
			guard let self, generation == current else {
				return
			}
			listen(advertise: true)
		}
	}

	private func accept(_ connection: NWConnection) {
		lastConnection = Date()
		connection.stateUpdateHandler = { [weak self, weak connection] state in
			guard let self, let connection else {
				return
			}
			switch state {
			case .ready:
				if let waiter = waiters.first {
					waiters.removeFirst()
					waiter.handler(connection)
				} else {
					idle.append(connection)
					onChange?()
				}
			case .failed, .cancelled:
				if let index = idle.firstIndex(where: { $0 === connection }) {
					idle.remove(at: index)
					onChange?()
				}
			default:
				break
			}
		}
		connection.start(queue: queue)
	}
}

/// Fetches the host's handshake profile over one of its connections.
enum InfoClient {
	struct InfoError: LocalizedError {
		let errorDescription: String?
	}

	static func fetch(over connection: NWConnection, completion: @escaping @MainActor (Result<ClientProfile, Error>) -> Void) {
		final class State: @unchecked Sendable {
			var data = Data()
			var finished = false
		}
		let state = State()
		let queue = DispatchQueue(label: "ClaudeProxyClient.info")

		@Sendable func finish(_ result: Result<ClientProfile, Error>) {
			queue.async {
				guard !state.finished else {
					return
				}
				state.finished = true
				connection.cancel()
				DispatchQueue.main.async {
					MainActor.assumeIsolated {
						completion(result)
					}
				}
			}
		}

		@Sendable func receive() {
			connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
				if let data {
					state.data.append(data)
				}
				if isComplete {
					finish(parse(state.data))
				} else if let error {
					finish(.failure(error))
				} else if state.data.count > 1024 * 1024 {
					finish(.failure(InfoError(errorDescription: "Response too large.")))
				} else {
					receive()
				}
			}
		}

		let request = "GET \(ClaudeProxyProtocol.infoPath) HTTP/1.1\r\nHost: claudeproxy\r\nConnection: close\r\n\r\n"
		connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
			if let error {
				finish(.failure(error))
			}
		})
		receive()
		queue.asyncAfter(deadline: .now() + 8) {
			finish(.failure(InfoError(errorDescription: "The host did not respond.")))
		}
	}

	private static func parse(_ data: Data) -> Result<ClientProfile, Error> {
		guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
			return .failure(InfoError(errorDescription: "Malformed response."))
		}
		let statusLine = String(decoding: data[data.startIndex..<separator.lowerBound], as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
		guard statusLine.split(separator: " ").dropFirst().first == "200" else {
			return .failure(InfoError(errorDescription: "Not a ClaudeProxy host (\(statusLine))."))
		}
		do {
			let profile = try JSONDecoder().decode(ClientProfile.self, from: data[separator.upperBound...])
			guard profile.v == ClaudeProxyProtocol.version else {
				return .failure(InfoError(errorDescription: "The host speaks protocol v\(profile.v); this client speaks v\(ClaudeProxyProtocol.version). Update both apps."))
			}
			return .success(profile)
		} catch {
			return .failure(InfoError(errorDescription: "Not a ClaudeProxy host."))
		}
	}
}
