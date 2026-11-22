import Foundation
import Network

/// Discovers ClaudeProxy servers over Bonjour.
@MainActor
final class ServerBrowser {
	struct Server: Equatable {
		let name: String
		let endpoint: NWEndpoint
		let profileVersion: String?
	}

	private(set) var servers: [Server] = []
	var onChange: (() -> Void)?
	private var browser: NWBrowser?

	func start() {
		browser?.cancel()
		let browser = NWBrowser(for: .bonjourWithTXTRecord(type: ClaudeProxyProtocol.serviceType, domain: nil), using: .tcp)
		browser.browseResultsChangedHandler = { [weak self] results, _ in
			MainActor.assumeIsolated {
				self?.update(results)
			}
		}
		browser.stateUpdateHandler = { [weak self] state in
			guard case .failed = state else {
				return
			}
			MainActor.assumeIsolated {
				DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
					MainActor.assumeIsolated {
						self?.start()
					}
				}
			}
		}
		self.browser = browser
		browser.start(queue: .main)
	}

	private func update(_ results: Set<NWBrowser.Result>) {
		var byName: [String: Server] = [:]
		for result in results {
			guard case let .service(name, _, _, _) = result.endpoint else {
				continue
			}
			var profileVersion: String?
			if case let .bonjour(txt) = result.metadata {
				profileVersion = txt["pv"]
			}
			// The same service shows up once per interface; any of them will do.
			if byName[name] == nil {
				byName[name] = Server(name: name, endpoint: result.endpoint, profileVersion: profileVersion)
			}
		}
		let sorted = byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
		if sorted != servers {
			servers = sorted
			onChange?()
		}
	}
}

/// Fetches the server's handshake profile with a plain HTTP GET.
enum InfoClient {
	struct InfoError: LocalizedError {
		let errorDescription: String?
	}

	static func fetch(_ endpoint: NWEndpoint, timeout: TimeInterval = 8, completion: @escaping @MainActor (Result<ClientProfile, Error>) -> Void) {
		final class State: @unchecked Sendable {
			var data = Data()
			var finished = false
		}
		let state = State()
		let queue = DispatchQueue(label: "ClaudeProxyClient.info")
		let connection = NWConnection(to: endpoint, using: .tcp)

		@Sendable func finish(_ result: Result<ClientProfile, Error>) {
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

		connection.stateUpdateHandler = { connectionState in
			switch connectionState {
			case .ready:
				let request = "GET \(ClaudeProxyProtocol.infoPath) HTTP/1.1\r\nHost: claudeproxy\r\nConnection: close\r\n\r\n"
				connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
					if let error {
						finish(.failure(error))
					}
				})
				receive()
			case let .failed(error), let .waiting(error):
				finish(.failure(error))
			default:
				break
			}
		}
		connection.start(queue: queue)
		queue.asyncAfter(deadline: .now() + timeout) {
			finish(.failure(InfoError(errorDescription: "Server did not respond.")))
		}
	}

	private static func parse(_ data: Data) -> Result<ClientProfile, Error> {
		guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
			return .failure(InfoError(errorDescription: "Malformed response."))
		}
		let statusLine = String(decoding: data[data.startIndex..<separator.lowerBound], as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
		guard statusLine.split(separator: " ").dropFirst().first == "200" else {
			return .failure(InfoError(errorDescription: "Not a ClaudeProxy server (\(statusLine))."))
		}
		do {
			let profile = try JSONDecoder().decode(ClientProfile.self, from: data[separator.upperBound...])
			guard profile.v == ClaudeProxyProtocol.version else {
				return .failure(InfoError(errorDescription: "Server speaks protocol v\(profile.v); this client speaks v\(ClaudeProxyProtocol.version)."))
			}
			return .success(profile)
		} catch {
			return .failure(InfoError(errorDescription: "Not a ClaudeProxy server."))
		}
	}
}
