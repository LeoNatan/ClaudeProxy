import Foundation
import Network

/// Listens for clients and advertises itself over Bonjour.
final class ProxyServer: @unchecked Sendable {
	enum Status: Sendable {
		case stopped
		case starting
		case running(UInt16)
		case runningWithoutBonjour(UInt16)
		case failed(String)
	}

	private let queue = DispatchQueue(label: "ClaudeProxy.server")
	private let lock = NSLock()
	private var state: ServerState?
	private var listener: NWListener?
	private var connections: [ObjectIdentifier: ProxyConnection] = [:]
	private var port: UInt16 = 0
	private var generation = 0
	let serviceName: String
	var onStatus: (@Sendable (Status) -> Void)?

	init(serviceName: String) {
		self.serviceName = serviceName
	}

	var currentState: ServerState? {
		lock.lock()
		defer { lock.unlock() }
		return state
	}

	func start(port: UInt16) {
		queue.async { [self] in
			self.port = port
			onStatus?(.starting)
			listen(advertise: true)
		}
	}

	/// Bonjour registration can fail on its own (e.g. Local Network access not yet granted). Clients can still
	/// connect by IP, so keep serving without advertising and try advertising again later.
	private func listen(advertise: Bool) {
		listener?.cancel()
		listener = nil
		generation += 1
		let port = port
		guard let nwPort = NWEndpoint.Port(rawValue: port) else {
			onStatus?(.failed("Invalid port \(port)."))
			return
		}
		let parameters = NWParameters.tcp
		parameters.allowLocalEndpointReuse = true
		let listener: NWListener
		do {
			listener = try NWListener(using: parameters, on: nwPort)
		} catch {
			onStatus?(.failed(error.localizedDescription))
			return
		}
		if advertise {
			listener.service = makeService()
		}
		listener.stateUpdateHandler = { [weak self, weak listener] state in
			guard let self, let listener, listener === self.listener else {
				return
			}
			switch state {
			case .ready:
				onStatus?(advertise ? .running(port) : .runningWithoutBonjour(port))
			case let .failed(error), let .waiting(error):
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

	/// Tries a full (advertised) listener again unless something restarted the listener in the meantime.
	private func retryLater() {
		let current = generation
		queue.asyncAfter(deadline: .now() + 15) { [weak self] in
			guard let self, generation == current else {
				return
			}
			listen(advertise: true)
		}
	}

	/// Swaps in a new settings generation. The previous forwarder finishes its in-flight requests.
	func update(state newState: ServerState) {
		lock.lock()
		let old = state
		state = newState
		lock.unlock()
		if old !== newState {
			old?.forwarder.retire()
		}
		queue.async { [self] in
			if old?.profile.pv != newState.profile.pv {
				listener?.service = makeService()
			}
		}
	}

	private func makeService() -> NWListener.Service {
		var txt = NWTXTRecord()
		txt["v"] = String(ClaudeProxyProtocol.version)
		txt["pv"] = currentState?.profile.pv ?? ""
		return NWListener.Service(name: serviceName, type: ClaudeProxyProtocol.serviceType, domain: nil, txtRecord: txt)
	}

	private func accept(_ nwConnection: NWConnection) {
		let connection = ProxyConnection(connection: nwConnection) { [weak self] in
			self?.currentState
		}
		let id = ObjectIdentifier(connection)
		connection.onClose = { [weak self] in
			guard let self else {
				return
			}
			queue.async {
				self.connections[id] = nil
			}
		}
		connections[id] = connection
		connection.start()
	}
}
