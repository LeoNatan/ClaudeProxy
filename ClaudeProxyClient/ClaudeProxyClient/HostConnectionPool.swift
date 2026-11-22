import Foundation
import Network

/// TCP keep-alive for host connections: a host that vanishes without closing (sleep, network loss) is noticed
/// after about 10 s idle + 3 × 5 s probes.
func makeKeepaliveTCPOptions() -> NWProtocolTCP.Options {
	let tcp = NWProtocolTCP.Options()
	tcp.enableKeepalive = true
	tcp.keepaliveIdle = 10
	tcp.keepaliveInterval = 5
	tcp.keepaliveCount = 3
	return tcp
}

/// One connection opened by the host. It has a single reader at all times, even while idle in the pool, so a host
/// closing the connection is noticed immediately. Whatever that read returns goes to the current consumer: the pool
/// while idle, the Claude Code connection it's paired with once handed out. Everything runs on the pool's queue.
final class HostConnection: @unchecked Sendable {
	struct Event {
		let data: Data?
		let isComplete: Bool
		let failed: Bool
	}

	let connection: NWConnection
	private var reading = false
	private var buffered: Event?
	private var handler: ((Event) -> Void)?

	init(connection: NWConnection) {
		self.connection = connection
	}

	/// Delivers the next chunk (or the close) to `handler`, exactly once.
	func read(_ handler: @escaping (Event) -> Void) {
		if let buffered {
			self.buffered = nil
			handler(buffered)
			return
		}
		self.handler = handler
		if !reading {
			reading = true
			connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
				guard let self else {
					return
				}
				reading = false
				let event = Event(data: data, isComplete: isComplete, failed: error != nil)
				if let handler = self.handler {
					self.handler = nil
					handler(event)
				} else {
					buffered = event
				}
			}
		}
	}

	/// Stops delivering to the current handler; a read already in flight is kept for the next one.
	func detach() {
		handler = nil
	}

	func cancel() {
		handler = nil
		connection.cancel()
	}
}

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
	private var idle: [HostConnection] = []
	/// Accepted connections not yet established; holds them until they join `idle`.
	private var connecting: [ObjectIdentifier: HostConnection] = [:]
	private var inUse = 0
	private var waiters: [(id: UUID, handler: @Sendable (HostConnection?) -> Void)] = []
	var onStatus: (@Sendable (Status) -> Void)?
	/// Called when host connections come or go.
	var onChange: (@Sendable () -> Void)?

	init(serviceName: String) {
		self.serviceName = serviceName
	}

	/// Whether a host currently keeps connections open to this client.
	var hasHost: Bool {
		queue.sync { !idle.isEmpty || inUse > 0 }
	}

	func start(port: UInt16) {
		queue.async { [self] in
			self.port = port
			listen(advertise: true)
		}
	}

	/// Hands out one idle host connection (already established), waiting up to `timeout` for one to arrive.
	/// Every connection handed out must be given back with `release(_:)` once finished.
	func take(timeout: TimeInterval, handler: @escaping @Sendable (HostConnection?) -> Void) {
		queue.async { [self] in
			if let connection = popIdle() {
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

	/// Called (on `queue`) when a handed-out connection is done.
	func release(_ connection: HostConnection) {
		connection.cancel()
		inUse -= 1
		onChange?()
	}

	// MARK: Pool (on `queue`)

	private func popIdle() -> HostConnection? {
		guard !idle.isEmpty else {
			return nil
		}
		let connection = idle.removeFirst()
		connection.detach()
		inUse += 1
		onChange?()
		return connection
	}

	private func addIdle(_ connection: HostConnection) {
		if let waiter = waiters.first {
			waiters.removeFirst()
			inUse += 1
			onChange?()
			waiter.handler(connection)
			return
		}
		idle.append(connection)
		onChange?()
		// The host never sends anything unprompted, so whatever this read returns means the connection is unusable:
		// usually the host closing it because it quit or restarted.
		connection.read { [weak self, weak connection] _ in
			guard let self, let connection else {
				return
			}
			removeIdle(connection)
		}
	}

	private func removeIdle(_ connection: HostConnection) {
		guard let index = idle.firstIndex(where: { $0 === connection }) else {
			return
		}
		idle.remove(at: index)
		connection.cancel()
		onChange?()
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
		let parameters = NWParameters(tls: nil, tcp: makeKeepaliveTCPOptions())
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

	private func accept(_ nwConnection: NWConnection) {
		let connection = HostConnection(connection: nwConnection)
		let id = ObjectIdentifier(connection)
		connecting[id] = connection
		nwConnection.stateUpdateHandler = { [weak self, weak connection] state in
			guard let self, let connection else {
				return
			}
			switch state {
			case .ready:
				if connecting.removeValue(forKey: id) != nil {
					addIdle(connection)
				}
			case .failed, .cancelled:
				// Keep-alive giving up, or the connection being torn down.
				connecting[id] = nil
				removeIdle(connection)
			default:
				break
			}
		}
		nwConnection.start(queue: queue)
	}
}

/// Fetches the host's handshake profile over one of its connections.
enum InfoClient {
	struct InfoError: LocalizedError {
		let errorDescription: String?
	}

	/// Runs on the pool's queue; hands the connection back to the pool when done.
	static func fetch(over connection: HostConnection, pool: HostConnectionPool, completion: @escaping @MainActor (Result<ClientProfile, Error>) -> Void) {
		final class State: @unchecked Sendable {
			var data = Data()
			var finished = false
		}
		let state = State()
		let queue = pool.queue

		@Sendable func finish(_ result: Result<ClientProfile, Error>) {
			queue.async {
				guard !state.finished else {
					return
				}
				state.finished = true
				pool.release(connection)
				DispatchQueue.main.async {
					MainActor.assumeIsolated {
						completion(result)
					}
				}
			}
		}

		@Sendable func receive() {
			connection.read { event in
				if let data = event.data {
					state.data.append(data)
				}
				if event.isComplete {
					finish(parse(state.data))
				} else if event.failed {
					finish(.failure(InfoError(errorDescription: "The host closed the connection.")))
				} else if state.data.count > 1024 * 1024 {
					finish(.failure(InfoError(errorDescription: "Response too large.")))
				} else {
					receive()
				}
			}
		}

		queue.async {
			let request = "GET \(ClaudeProxyProtocol.infoPath) HTTP/1.1\r\nHost: claudeproxy\r\nConnection: close\r\n\r\n"
			connection.connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
				if error != nil {
					finish(.failure(InfoError(errorDescription: "The host closed the connection.")))
				}
			})
			receive()
		}
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
