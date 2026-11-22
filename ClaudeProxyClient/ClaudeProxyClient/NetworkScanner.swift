import Foundation
import Network

/// Finds ClaudeProxy servers by asking every address on the local subnets directly, for servers that can't
/// advertise over Bonjour (e.g. a Mac managed with mDNSResponder's NoMulticastAdvertisements). Only the client
/// sends anything; the server just answers a normal handshake request.
@MainActor
final class NetworkScanner {
	struct Result: Equatable {
		let name: String
		let host: String
		let port: UInt16
	}

	private static let maxConcurrent = 64
	private static let probeTimeout: TimeInterval = 2

	private(set) var results: [Result] = []
	private(set) var isScanning = false
	var onChange: (() -> Void)?

	private var pending: [(host: String, port: UInt16)] = []
	private var inFlight = 0
	private var found: [Result] = []

	func scan(ports: [UInt16]) {
		guard !isScanning else {
			return
		}
		let hosts = Self.candidateHosts()
		pending = hosts.flatMap { host in ports.map { (host, $0) } }
		found = []
		isScanning = !pending.isEmpty
		onChange?()
		for _ in 0..<min(Self.maxConcurrent, pending.count) {
			probeNext()
		}
	}

	private func probeNext() {
		guard !pending.isEmpty else {
			if inFlight == 0 && isScanning {
				isScanning = false
				results = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
				onChange?()
			}
			return
		}
		let (host, port) = pending.removeFirst()
		inFlight += 1
		InfoClient.fetch(.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!), timeout: Self.probeTimeout) { [weak self] result in
			guard let self else {
				return
			}
			inFlight -= 1
			if case let .success(profile) = result {
				found.append(Result(name: profile.name, host: host, port: port))
			}
			probeNext()
		}
	}

	/// Every host address on each active broadcast-capable IPv4 interface. Subnets larger than /22 are
	/// narrowed to the surrounding /24 to keep the scan short.
	private static func candidateHosts() -> [String] {
		var hosts: [String] = []
		var seen = Set<UInt32>()
		var interfaces: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&interfaces) == 0, let first = interfaces else {
			return []
		}
		defer { freeifaddrs(interfaces) }

		for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
			let entry = pointer.pointee
			let flags = Int32(entry.ifa_flags)
			guard let address = entry.ifa_addr, let netmask = entry.ifa_netmask,
				  address.pointee.sa_family == UInt8(AF_INET),
				  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0 else {
				continue
			}
			let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
			var mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
			if mask.nonzeroBitCount < 22 {
				mask = 0xFFFF_FF00
			}
			let network = ip & mask
			let broadcast = network | ~mask
			guard broadcast > network + 1 else {
				continue
			}
			for candidate in (network + 1)..<broadcast where seen.insert(candidate).inserted {
				hosts.append("\(candidate >> 24).\(candidate >> 16 & 0xFF).\(candidate >> 8 & 0xFF).\(candidate & 0xFF)")
			}
		}
		return hosts
	}
}
