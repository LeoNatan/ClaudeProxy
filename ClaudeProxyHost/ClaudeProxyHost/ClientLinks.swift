import Foundation
import Network

/// Keeps a pool of outbound connections open to one client. The client hands each idle connection to one
/// Claude Code connection; the host then serves that connection's requests like any other. Connecting out
/// (rather than listening) lets a host on a Mac that blocks incoming connections still serve clients.
final class ClientLink: @unchecked Sendable {
	enum Status: Sendable, Equatable {
		case connecting
		case connected
		/// The client turned the connections away: it uses another host.
		case otherHost
		case unreachable
	}

	private final class Entry: @unchecked Sendable {
		var ready = false
		var accepted = false
		var rejected = false
		var active = false
	}

	/// Idle connections kept waiting at the client for new Claude Code connections.
	private static let idleTarget = 4
	private static let maxConnections = 64
	private static let connectTimeout: TimeInterval = 10
	/// How often to ask again after a client turned this host away (it may switch back).
	private static let otherHostRetry: TimeInterval = 10

	let endpoint: NWEndpoint
	private let queue: DispatchQueue
	private let greeting: Data
	private let stateProvider: @Sendable () -> HostState?
	private var entries: [ObjectIdentifier: (connection: ProxyConnection, entry: Entry)] = [:]
	private var failures = 0
	private var turnedAway = false
	private var retryScheduled = false
	private var stopped = false
	private(set) var status: Status = .connecting
	var onStatusChange: (@Sendable () -> Void)?

	init(endpoint: NWEndpoint, greeting: Data, queue: DispatchQueue, stateProvider: @escaping @Sendable () -> HostState?) {
		self.endpoint = endpoint
		self.greeting = greeting
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
			for (connection, _) in entries.values {
				connection.cancel()
			}
		}
	}

	// MARK: Pool (on `queue`)

	private var idleCount: Int {
		entries.values.count { !$0.entry.active }
	}

	private func replenish() {
		guard !stopped, !retryScheduled else {
			return
		}
		while idleCount < Self.idleTarget && entries.count < Self.maxConnections {
			open()
		}
	}

	private func open() {
		// Same keep-alive as the client: a client that vanishes is noticed after about 25 s.
		let tcp = NWProtocolTCP.Options()
		tcp.enableKeepalive = true
		tcp.keepaliveIdle = 10
		tcp.keepaliveInterval = 5
		tcp.keepaliveCount = 3
		let connection = ProxyConnection(connection: NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp)), stateProvider: stateProvider)
		connection.greeting = greeting
		let entry = Entry()
		let id = ObjectIdentifier(connection)
		connection.onReady = { [weak self] in
			self?.queue.async {
				entry.ready = true
			}
		}
		connection.onAccepted = { [weak self] in
			guard let self else {
				return
			}
			queue.async {
				entry.accepted = true
				self.failures = 0
				self.turnedAway = false
				self.updateStatus()
			}
		}
		connection.onRejected = { [weak self] in
			guard let self else {
				return
			}
			queue.async {
				entry.rejected = true
				self.turnedAway = true
				self.updateStatus()
			}
		}
		connection.onFirstData = { [weak self] in
			guard let self else {
				return
			}
			queue.async {
				entry.active = true
				self.replenish()
			}
		}
		connection.onClose = { [weak self] in
			guard let self else {
				return
			}
			queue.async {
				guard self.entries.removeValue(forKey: id) != nil else {
					return
				}
				if entry.rejected {
					self.scheduleRetry(after: Self.otherHostRetry)
				} else if entry.accepted {
					self.replenish()
				} else {
					self.failures += 1
					self.scheduleRetry(after: self.failures > 3 * Self.idleTarget ? 30 : 5)
				}
				self.updateStatus()
			}
		}
		entries[id] = (connection, entry)
		connection.start()

		// A Bonjour endpoint that never resolves, or a client that never answers, would otherwise hold a pool slot forever.
		queue.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak connection] in
			if !entry.accepted && !entry.rejected {
				connection?.cancel()
			}
		}
	}

	private func scheduleRetry(after delay: TimeInterval) {
		guard !retryScheduled, !stopped else {
			return
		}
		retryScheduled = true
		queue.asyncAfter(deadline: .now() + delay) { [weak self] in
			guard let self else {
				return
			}
			retryScheduled = false
			replenish()
		}
	}

	private func updateStatus() {
		let serving = entries.values.contains { $0.entry.accepted || $0.entry.active }
		let newStatus: Status = serving ? .connected : turnedAway ? .otherHost : failures > 0 ? .unreachable : .connecting
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
	/// Clients to serve once settings are loaded: connecting earlier would only answer "still loading".
	private var targets: [String: NWEndpoint] = [:]
	private let greeting: Data
	var onChange: (@Sendable () -> Void)?

	/// `hostID` identifies this host to clients across restarts; `hostName` is what clients show.
	init(hostID: String, hostName: String) {
		greeting = Data("\(ClaudeProxyProtocol.hostGreetingPrefix)\(hostID) \(hostName)\n".utf8)
	}

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
		if old == nil {
			queue.async { [self] in
				applyTargets()
			}
		}
	}

	/// Serves exactly these clients (keyed by a stable identifier), keeping existing links that are still wanted.
	func setClients(_ targets: [String: NWEndpoint]) {
		queue.async { [self] in
			self.targets = targets
			applyTargets()
		}
	}

	private func applyTargets() {
		guard currentState != nil else {
			return
		}
		for (key, link) in links where targets[key] != link.endpoint {
			link.stop()
			links[key] = nil
		}
		for (key, endpoint) in targets where links[key] == nil {
			let link = ClientLink(endpoint: endpoint, greeting: greeting, queue: queue) { [weak self] in
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

	func statuses() -> [String: ClientLink.Status] {
		queue.sync {
			links.mapValues(\.status)
		}
	}
}
