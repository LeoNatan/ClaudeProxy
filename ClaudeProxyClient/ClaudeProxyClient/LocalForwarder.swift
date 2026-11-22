import Foundation
import Network

/// Listens on 127.0.0.1 and splices each connection to the selected server, byte for byte.
final class LocalForwarder: @unchecked Sendable {
	enum Status: Sendable {
		case stopped
		case listening(UInt16)
		case failed(String)
	}

	private let queue = DispatchQueue(label: "ClaudeProxyClient.forwarder")
	private let lock = NSLock()
	private var _target: NWEndpoint?
	private var listener: NWListener?
	private var splices: [ObjectIdentifier: Splice] = [:]
	var onStatus: (@Sendable (Status) -> Void)?

	/// The server new connections go to. Existing connections keep theirs.
	var target: NWEndpoint? {
		get {
			lock.lock()
			defer { lock.unlock() }
			return _target
		}
		set {
			lock.lock()
			_target = newValue
			lock.unlock()
		}
	}

	func start(port: UInt16) {
		queue.async { [self] in
			listener?.cancel()
			listener = nil
			guard let nwPort = NWEndpoint.Port(rawValue: port), port > 0 else {
				onStatus?(.failed("Invalid port \(port)."))
				return
			}
			let parameters = NWParameters.tcp
			parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
			parameters.allowLocalEndpointReuse = true
			let listener: NWListener
			do {
				listener = try NWListener(using: parameters)
			} catch {
				onStatus?(.failed(error.localizedDescription))
				return
			}
			listener.stateUpdateHandler = { [weak self, weak listener] state in
				guard let self, let listener, listener === self.listener else {
					return
				}
				switch state {
				case .ready:
					onStatus?(.listening(port))
				case let .failed(error), let .waiting(error):
					onStatus?(.failed(error.localizedDescription))
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
	}

	private func accept(_ inbound: NWConnection) {
		guard let target else {
			Splice.reject(inbound, queue: queue, status: 503, message: "ClaudeProxy Client: no server selected.")
			return
		}
		let splice = Splice(inbound: inbound, outbound: NWConnection(to: target, using: .tcp), queue: queue)
		let id = ObjectIdentifier(splice)
		splice.onFinish = { [weak self] in
			guard let self else {
				return
			}
			queue.async {
				self.splices[id] = nil
			}
		}
		splices[id] = splice
		splice.start()
	}
}

/// Two connections piped into each other, with half-close propagated.
private final class Splice: @unchecked Sendable {
	private let inbound: NWConnection
	private let outbound: NWConnection
	private let queue: DispatchQueue
	private var outboundReady = false
	private var sentAnything = false
	private var openDirections = 2
	private var finished = false
	var onFinish: (@Sendable () -> Void)?

	init(inbound: NWConnection, outbound: NWConnection, queue: DispatchQueue) {
		self.inbound = inbound
		self.outbound = outbound
		self.queue = queue
	}

	func start() {
		inbound.stateUpdateHandler = { [weak self] state in
			switch state {
			case .failed, .cancelled:
				self?.finish()
			default:
				break
			}
		}
		outbound.stateUpdateHandler = { [weak self] state in
			guard let self else {
				return
			}
			switch state {
			case .ready:
				guard !outboundReady else {
					return
				}
				outboundReady = true
				pump(from: inbound, to: outbound, countsAsSent: false)
				pump(from: outbound, to: inbound, countsAsSent: true)
			case .waiting, .failed:
				if !outboundReady {
					outboundFailed()
				} else {
					finish()
				}
			case .cancelled:
				finish()
			default:
				break
			}
		}
		inbound.start(queue: queue)
		outbound.start(queue: queue)
		// A Bonjour endpoint that never resolves leaves the connection waiting forever.
		queue.asyncAfter(deadline: .now() + 10) { [weak self] in
			guard let self, !outboundReady else {
				return
			}
			outboundFailed()
		}
	}

	private func outboundFailed() {
		guard !finished else {
			return
		}
		Self.reject(inbound, queue: queue, status: 502, message: "ClaudeProxy Client: the server is unreachable.", alreadyStarted: true)
		outbound.cancel()
		finished = true
		onFinish?()
	}

	private func pump(from source: NWConnection, to destination: NWConnection, countsAsSent: Bool) {
		source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
			guard let self, !finished else {
				return
			}
			if let data, !data.isEmpty {
				if countsAsSent {
					sentAnything = true
				}
				destination.send(content: data, completion: .contentProcessed { [weak self] error in
					guard let self else {
						return
					}
					if error != nil {
						finish()
					} else if isComplete {
						closeDirection(destination)
					} else {
						pump(from: source, to: destination, countsAsSent: countsAsSent)
					}
				})
			} else if isComplete {
				closeDirection(destination)
			} else if error != nil {
				finish()
			} else {
				pump(from: source, to: destination, countsAsSent: countsAsSent)
			}
		}
	}

	private func closeDirection(_ destination: NWConnection) {
		destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
		openDirections -= 1
		if openDirections == 0 {
			finish()
		}
	}

	private func finish() {
		guard !finished else {
			return
		}
		finished = true
		inbound.cancel()
		outbound.cancel()
		onFinish?()
		onFinish = nil
	}

	/// Answers with an Anthropic-shaped error so Claude Code shows something useful.
	static func reject(_ connection: NWConnection, queue: DispatchQueue, status: Int, message: String, alreadyStarted: Bool = false) {
		let payload: [String: Any] = ["type": "error", "error": ["type": "api_error", "message": message]]
		let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
		var response = Data("HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
		response.append(body)
		if !alreadyStarted {
			connection.start(queue: queue)
		}
		connection.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
			connection.cancel()
		})
	}
}
