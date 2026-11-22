import Foundation
import Network

/// Discovers ClaudeProxy clients over Bonjour. Browsing works even where advertising is blocked
/// (mDNSResponder's NoMulticastAdvertisements), which is why clients advertise and the host browses.
@MainActor
final class ClientBrowser {
	struct Client: Equatable {
		let name: String
		let endpoint: NWEndpoint
	}

	private(set) var clients: [Client] = []
	var onChange: (() -> Void)?
	private var browser: NWBrowser?

	func start() {
		browser?.cancel()
		let browser = NWBrowser(for: .bonjour(type: ClaudeProxyProtocol.clientServiceType, domain: nil), using: .tcp)
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
		var byName: [String: Client] = [:]
		for result in results {
			guard case let .service(name, type, domain, _) = result.endpoint else {
				continue
			}
			// One entry per client, not per interface; the interface-less endpoint lets the system pick a route.
			byName[name] = Client(name: name, endpoint: .service(name: name, type: type, domain: domain, interface: nil))
		}
		let sorted = byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
		if sorted != clients {
			clients = sorted
			onChange?()
		}
	}
}
