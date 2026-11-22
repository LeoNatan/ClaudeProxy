import Foundation

/// Streams requests to the upstream with URLSession. One instance per settings generation.
final class UpstreamForwarder: NSObject, URLSessionDataDelegate, @unchecked Sendable {
	struct Callbacks: Sendable {
		/// Return false to cancel the task (used to retry after an auth failure).
		let response: @Sendable (HTTPURLResponse) -> Bool
		let data: @Sendable (Data) -> Void
		let complete: @Sendable (Error?) -> Void
	}

	private let network: NetworkConfiguration
	private let lock = NSLock()
	private var callbacks: [ObjectIdentifier: Callbacks] = [:]
	private var proxiedSession: URLSession!
	private var directSession: URLSession!

	init(network: NetworkConfiguration) {
		self.network = network
		super.init()
		let queue = OperationQueue()
		queue.maxConcurrentOperationCount = 1
		queue.name = "ClaudeProxy.upstream"
		proxiedSession = URLSession(configuration: makeConfiguration(useProxy: true), delegate: self, delegateQueue: queue)
		directSession = URLSession(configuration: makeConfiguration(useProxy: false), delegate: self, delegateQueue: queue)
	}

	private func makeConfiguration(useProxy: Bool) -> URLSessionConfiguration {
		let configuration = URLSessionConfiguration.ephemeral
		if let proxy = network.proxyDictionary(useProxy: useProxy) {
			configuration.connectionProxyDictionary = proxy
		}
		configuration.httpCookieStorage = nil
		configuration.httpShouldSetCookies = false
		configuration.urlCache = nil
		configuration.urlCredentialStorage = nil
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		// Idle timeout between bytes; long thinking pauses happen inside streams.
		configuration.timeoutIntervalForRequest = 600
		configuration.timeoutIntervalForResource = 24 * 60 * 60
		configuration.httpMaximumConnectionsPerHost = 16
		return configuration
	}

	func start(_ request: URLRequest, callbacks: Callbacks) -> URLSessionDataTask {
		let host = request.url?.host ?? ""
		let session = network.proxyURL != nil && !network.shouldBypassProxy(host: host) ? proxiedSession! : directSession!
		let task = session.dataTask(with: request)
		lock.lock()
		self.callbacks[ObjectIdentifier(task)] = callbacks
		lock.unlock()
		task.resume()
		return task
	}

	/// Lets in-flight requests finish, then releases the sessions (which retain their delegate).
	func retire() {
		proxiedSession.finishTasksAndInvalidate()
		directSession.finishTasksAndInvalidate()
	}

	private func callbacks(for task: URLSessionTask) -> Callbacks? {
		lock.lock()
		defer { lock.unlock() }
		return callbacks[ObjectIdentifier(task)]
	}

	// MARK: URLSessionDataDelegate

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
		guard let callbacks = callbacks(for: dataTask), let response = response as? HTTPURLResponse else {
			completionHandler(.cancel)
			return
		}
		completionHandler(callbacks.response(response) ? .allow : .cancel)
	}

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
		callbacks(for: dataTask)?.data(data)
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		lock.lock()
		let callbacks = self.callbacks.removeValue(forKey: ObjectIdentifier(task))
		lock.unlock()
		callbacks?.complete(error)
	}

	/// Never follow redirects: the client gets the 3xx as-is, and credentials never go to another host.
	func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
		completionHandler(nil)
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
		let space = challenge.protectionSpace
		if space.isProxy() {
			if challenge.previousFailureCount == 0, let credential = network.proxyCredential {
				completionHandler(.useCredential, credential)
			} else {
				completionHandler(.performDefaultHandling, nil)
			}
			return
		}
		switch space.authenticationMethod {
		case NSURLAuthenticationMethodServerTrust:
			guard let trust = space.serverTrust else {
				completionHandler(.performDefaultHandling, nil)
				return
			}
			if network.extraAnchors.isEmpty && network.rejectUnauthorized {
				completionHandler(.performDefaultHandling, nil)
			} else if network.evaluate(trust) {
				completionHandler(.useCredential, URLCredential(trust: trust))
			} else {
				completionHandler(.cancelAuthenticationChallenge, nil)
			}
		case NSURLAuthenticationMethodClientCertificate:
			if let identity = network.clientIdentity {
				completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
			} else {
				completionHandler(.performDefaultHandling, nil)
			}
		default:
			completionHandler(.performDefaultHandling, nil)
		}
	}
}
