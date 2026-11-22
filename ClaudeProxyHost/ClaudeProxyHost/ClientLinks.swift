import Foundation
import Network

/// Keeps a pool of outbound connections open to one client. The client hands each idle connection to one
/// Claude Code connection; the host then serves that connection's requests like any other. Connecting out
/// (rather than listening) lets a host on a Mac that blocks incoming connections still serve clients.
final class ClientLink: @unchecked Sendable {
	enum Status: Sendable, Equatable {
		case connecting
		case connected
		case unreachable
	}

	private final class Entry: @unchecked Sendable {
		var ready = false
		var active = false
	}

	/// Idle connections kept waiting at the client for new Claude Code connections.
	private static let idleTarget = 4
	private static let maxConnections = 64
	private static let connectTimeout: TimeInterval = 10

	let endpoint: NWEndpoint
	private let queue: DispatchQueue
	private let stateProvider: @Sendable () -> HostState?
	private var connections: [ObjectIdentifier: ProxyConnection] = [:]
	private var idle = 0
	private var active = 0
	private var ready = 0
	private var failures = 0
	private var retryScheduled = false
	private var stopped = false
	private(set) var status: Status = .connecting
	var onStatusChange: (@Sendable () -> Void)?

	init(endpoint: NWEndpoint, queue: DispatchQueue, stateProvider: @escaping @Sendable () -> HostState?) {
		self.endpoint = endpoint
		self.queue = queue
		self.stateProvider = stateProvider
	}

	func start() {
		queue.async { [self] in
			replenish()
		}
	}

	func stop() {
		queue.async { [self] in
			stopped = true
			for connection in connections.values {
				connection.cancel()
			}
		}
	}

	// MARK: Pool (on `queue`)

	private func replenish() {
		guard !stopped, !retryScheduled else {
			return
		}
		while idle < Self.idleTarget && idle + active < Self.maxConnections {
			open()
		}
	}

	private func open() {
		idle += 1
		// Same keep-alive as the client: a client that vanishes is noticed after about 25 s.
		let tcp = NWProtocolTCP.Options()
		tcp.enableKeepalive = true
		tcp.keepaliveIdle = 10
		tcp.keepaliveInterval = 5
		tcp.keepaliveCount = 3
		let connection = ProxyConnection(connection: NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp)), stateProvider: stateProvider)
		let entry = Entry()
		let id = ObjectIdentifier(connection)
		connection.onReady = { [weak self] in
			guard let self else {
				return
			}
			queue.async {
				guard !entry.ready else {
					return
				}
				entry.ready = true
				self.ready += 1
				self.failures = 0
				self.updateStatus()
			}
		}
		connection.onFirstData = { [weak self] in
			guard let self else {
				return
			}
			queue.async {
				entry.active = true
				self.idle -= 1
				self.active += 1
				if entry.ready {
					self.ready -= 1
				}
				self.replenish()
			}
		}
		connection.onClose = { [weak self] in
			guard let self else {
				return
			}
			queue.async {
				guard self.connections.removeValue(forKey: id) != nil else {
					return
				}
				if entry.active {
					self.active -= 1
				} else {
					self.idle -= 1
					if entry.ready {
						self.ready -= 1
					}
				}
				if entry.ready {
					self.replenish()
				} else {
					self.failures += 1
					self.scheduleRetry()
				}
				self.updateStatus()
			}
		}
		connections[id] = connection
		connection.start()

		// A Bonjour endpoint that never resolves, or a client that never answers, would otherwise hold a pool slot forever.
		queue.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak connection] in
			if !entry.ready {
				connection?.cancel()
			}
		}
	}

	private func scheduleRetry() {
		guard !retryScheduled, !stopped else {
			return
		}
		retryScheduled = true
		let delay: TimeInterval = failures > 3 * Self.idleTarget ? 30 : 5
		queue.asyncAfter(deadline: .now() + delay) { [weak self] in
			guard let self else {
				return
			}
			retryScheduled = false
			replenish()
		}
	}

	private func updateStatus() {
		// `ready` counts idle connections that reached the client; `active` ones are carrying requests.
		let newStatus: Status = ready > 0 || active > 0 ? .connected : failures > 0 ? .unreachable : .connecting
		if newStatus != status {
			status = newStatus
			onStatusChange?()
		}
	}
}

/// Holds the current settings generation and a `ClientLink` per client being served.
final class ClientLinkManager: @unchecked Sendable {
	private let queue = DispatchQueue(label: "ClaudeProxy.links")
	private let lock = NSLock()
	private var state: HostState?
	private var links: [String: ClientLink] = [:]
	var onChange: (@Sendable () -> Void)?

	var currentState: HostState? {
		lock.lock()
		defer { lock.unlock() }
		return state
	}

	/// Swaps in a new settings generation. The previous forwarder finishes its in-flight requests.
	func update(state newState: HostState) {
		lock.lock()
		let old = state
		state = newState
		lock.unlock()
		if old !== newState {
			old?.forwarder.retire()
		}
	}

	/// Serves exactly these clients (keyed by a stable identifier), keeping existing links that are still wanted.
	func setClients(_ targets: [String: NWEndpoint]) {
		queue.async { [self] in
			for (key, link) in links where targets[key] != link.endpoint {
				link.stop()
				links[key] = nil
			}
			for (key, endpoint) in targets where links[key] == nil {
				let link = ClientLink(endpoint: endpoint, queue: queue) { [weak self] in
					self?.currentState
				}
				link.onStatusChange = { [weak self] in
					self?.onChange?()
				}
				links[key] = link
				link.start()
			}
			onChange?()
		}
	}

	func statuses() -> [String: ClientLink.Status] {
		queue.sync {
			links.mapValues(\.status)
		}
	}
}
