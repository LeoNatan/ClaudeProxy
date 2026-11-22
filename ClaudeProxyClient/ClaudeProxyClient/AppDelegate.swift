import AppKit
import Network
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
	private enum Defaults {
		static let localPort = "localPort"
		static let networkPort = "networkPort"
	}

	private static let serviceName = Host.current().localizedName ?? "ClaudeProxy Client"

	private var statusItem: NSStatusItem!
	private let pool = HostConnectionPool(serviceName: AppDelegate.serviceName)
	private lazy var forwarder = LocalForwarder(pool: pool)
	private let installer = SettingsInstaller()
	private var forwarderStatus: LocalForwarder.Status = .stopped
	private var poolStatus: HostConnectionPool.Status = .stopped
	private var profile: ClientProfile?
	private var profileError: String?
	private var installError: String?
	private var fetching = false
	private var pollTimer: Timer?

	private var localPort: UInt16 {
		get { Self.port(forKey: Defaults.localPort, default: ClaudeProxyProtocol.defaultClientPort) }
		set { UserDefaults.standard.set(Int(newValue), forKey: Defaults.localPort) }
	}

	private var networkPort: UInt16 {
		get { Self.port(forKey: Defaults.networkPort, default: ClaudeProxyProtocol.defaultClientNetworkPort) }
		set { UserDefaults.standard.set(Int(newValue), forKey: Defaults.networkPort) }
	}

	private static func port(forKey key: String, default defaultPort: UInt16) -> UInt16 {
		let stored = UserDefaults.standard.integer(forKey: key)
		return stored > 0 && stored <= Int(UInt16.max) ? UInt16(stored) : defaultPort
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		installEditMenu()
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		let menu = NSMenu()
		menu.delegate = self
		statusItem.menu = menu
		updateIcon()

		forwarder.onStatus = { [weak self] status in
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					self?.forwarderStatus = status
					self?.updateIcon()
				}
			}
		}
		pool.onStatus = { [weak self] status in
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					self?.poolStatus = status
					self?.updateIcon()
				}
			}
		}
		// A host connecting for the first time is the moment to learn its profile.
		pool.onChange = { [weak self] in
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					guard let self, self.profile == nil || self.profileError != nil else {
						return
					}
					self.fetchProfile()
				}
			}
		}
		forwarder.start(port: localPort)
		pool.start(port: networkPort)

		pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated {
				self?.fetchProfile()
			}
		}
	}

	// MARK: Host profile

	/// Handshake: learn the host's provider profile over one of its connections, and re-install if it changed.
	private func fetchProfile() {
		guard !fetching else {
			return
		}
		fetching = true
		pool.take(timeout: 0.5) { [weak self] connection in
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					self?.fetchProfile(over: connection)
				}
			}
		}
	}

	private func fetchProfile(over connection: NWConnection?) {
		guard let connection else {
			fetching = false
			updateIcon()
			return
		}
		InfoClient.fetch(over: connection) { [weak self] result in
			guard let self else {
				return
			}
			fetching = false
			switch result {
			case let .success(profile):
				self.profile = profile
				profileError = nil
				syncInstallation()
			case let .failure(error):
				profileError = error.localizedDescription
			}
			updateIcon()
		}
	}

	private var desiredEnv: [String: String]? {
		guard let profile else {
			return nil
		}
		var env = profile.env
		env[profile.baseURLVariable] = "http://127.0.0.1:\(localPort)"
		return env
	}

	/// Keeps an existing installation in step with the host's profile and the local port.
	private func syncInstallation() {
		guard installer.isInstalled, let desiredEnv, desiredEnv != installer.installedEnv else {
			return
		}
		do {
			try installer.install(env: desiredEnv)
			installError = nil
		} catch {
			installError = error.localizedDescription
		}
	}

	private func updateIcon() {
		let healthy: Bool = {
			guard case .listening = forwarderStatus, case .listening = poolStatus else {
				return false
			}
			return pool.hasHost && profile != nil && profileError == nil && installError == nil
		}()
		let symbol = healthy ? (installer.isInstalled ? "point.3.filled.connected.trianglepath.dotted" : "point.3.connected.trianglepath.dotted") : "exclamationmark.triangle"
		statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ClaudeProxy Client")
	}

	/// Menu bar apps get no main menu, and without an Edit menu text fields don't receive ⌘X/⌘C/⌘V/⌘A/⌘Z.
	/// The menu is never shown; it only has to exist for key equivalents to reach the alert's text fields.
	private func installEditMenu() {
		let edit = NSMenu(title: "Edit")
		edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
		let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
		redo.keyEquivalentModifierMask = [.command, .shift]
		edit.addItem(.separator())
		edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
		edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
		edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
		edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
		let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
		editItem.submenu = edit
		let main = NSMenu()
		main.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
		main.addItem(editItem)
		NSApp.mainMenu = main
	}

	// MARK: Menu

	func menuNeedsUpdate(_ menu: NSMenu) {
		menu.removeAllItems()

		let hasHost = pool.hasHost
		if let profile {
			let provider = profile.provider == "anthropic" ? "Anthropic API / gateway" : profile.provider
			menu.addItem(info("Host: \(profile.name) — \(provider)\(hasHost ? "" : " (disconnected)")"))
		} else if hasHost {
			menu.addItem(info(profileError.map { "⚠︎ Host connected, but: \($0)" } ?? "Host connected — loading…"))
		} else {
			menu.addItem(info("Waiting for a ClaudeProxy host to connect"))
		}

		switch poolStatus {
		case .stopped:
			break
		case let .listening(port, advertised):
			menu.addItem(info(advertised ? "Discoverable as “\(pool.serviceName)” on port \(port)" : "Listening on port \(port), not advertised over Bonjour (retrying)"))
			if !advertised {
				menu.addItem(info("ⓘ Allow ClaudeProxy Client in System Settings › Privacy & Security › Local Network"))
			}
		case let .failed(message):
			menu.addItem(info("⚠︎ Network listener: \(message)"))
		}
		switch forwarderStatus {
		case .stopped:
			break
		case let .listening(port):
			menu.addItem(info("Claude Code connects to 127.0.0.1:\(port)"))
		case let .failed(message):
			menu.addItem(info("⚠︎ Local proxy: \(message)"))
		}

		let addresses = Self.localAddresses()
		if !addresses.isEmpty {
			menu.addItem(info("Copy Address for the Host’s “Add Client by Address”:"))
			for address in addresses {
				let copy = item("\(address.ip):\(networkPort)  (\(address.interface))", #selector(copyAddress(_:)))
				copy.representedObject = "\(address.ip):\(networkPort)"
				copy.indentationLevel = 1
				menu.addItem(copy)
			}
		}

		menu.addItem(.separator())
		if installer.isInstalled {
			menu.addItem(item("Uninstall from Claude Code", #selector(uninstall)))
			menu.addItem(info("Claude Code uses this proxy (\(SettingsInstaller.displayPath(installer.settingsURL)))"))
		} else {
			let install = item("Install into Claude Code", #selector(install))
			install.isEnabled = profile != nil
			menu.addItem(install)
			if profile == nil {
				menu.addItem(info("Available once a host has connected"))
			}
		}
		if let installError {
			menu.addItem(info("⚠︎ \(installError)"))
		}
		if let desiredEnv {
			let overridden = installer.managedOverrides(for: desiredEnv)
			if !overridden.isEmpty {
				menu.addItem(info("⚠︎ Managed settings override: \(overridden.joined(separator: ", "))"))
			}
		}

		menu.addItem(.separator())
		menu.addItem(item("Local Port \(localPort)…", #selector(changeLocalPort)))
		menu.addItem(item("Network Port \(networkPort)…", #selector(changeNetworkPort)))
		let login = item("Start at Login", #selector(toggleLogin))
		login.state = SMAppService.mainApp.status == .enabled ? .on : .off
		menu.addItem(login)
		menu.addItem(item("Quit ClaudeProxy Client", #selector(quit), key: "q"))
	}

	private func info(_ title: String) -> NSMenuItem {
		NSMenuItem.info(title)
	}

	private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
		let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
		item.target = self
		return item
	}

	/// IPv4 addresses of active LAN interfaces, the ones the host can reach.
	private static func localAddresses() -> [(ip: String, interface: String)] {
		var result: [(String, String)] = []
		var interfaces: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&interfaces) == 0, let first = interfaces else {
			return []
		}
		defer { freeifaddrs(interfaces) }
		for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
			let entry = pointer.pointee
			let flags = Int32(entry.ifa_flags)
			guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
				  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0 else {
				continue
			}
			var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
			guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
				continue
			}
			let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
			result.append((ip, String(validatingCString: entry.ifa_name) ?? "?"))
		}
		return result
	}

	// MARK: Actions

	@objc private func copyAddress(_ sender: NSMenuItem) {
		guard let value = sender.representedObject as? String else {
			return
		}
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(value, forType: .string)
	}

	@objc private func install() {
		guard let desiredEnv else {
			return
		}
		do {
			try installer.install(env: desiredEnv)
			installError = nil
		} catch {
			installError = error.localizedDescription
			NSApp.activate()
			NSAlert(error: error).runModal()
		}
		updateIcon()
	}

	@objc private func uninstall() {
		do {
			try installer.uninstall()
			installError = nil
		} catch {
			installError = error.localizedDescription
			NSApp.activate()
			NSAlert(error: error).runModal()
		}
		updateIcon()
	}

	@objc private func changeLocalPort() {
		guard let newPort = askForPort(title: "Local Port", message: "Claude Code on this Mac connects to 127.0.0.1 on this port.", current: localPort, default: ClaudeProxyProtocol.defaultClientPort) else {
			return
		}
		localPort = newPort
		forwarder.start(port: newPort)
		syncInstallation()
	}

	@objc private func changeNetworkPort() {
		guard let newPort = askForPort(title: "Network Port", message: "The host connects to this Mac on this port. A host that found this client over Bonjour follows the change; one that added it by address needs the new port.", current: networkPort, default: ClaudeProxyProtocol.defaultClientNetworkPort) else {
			return
		}
		networkPort = newPort
		pool.start(port: newPort)
	}

	private func askForPort(title: String, message: String, current: UInt16, default defaultPort: UInt16) -> UInt16? {
		NSApp.activate()
		let alert = NSAlert()
		alert.messageText = title
		alert.informativeText = message
		let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
		field.stringValue = String(current)
		alert.accessoryView = field
		alert.addButton(withTitle: "Save")
		alert.addButton(withTitle: "Cancel")
		alert.addButton(withTitle: "Use Default (\(defaultPort))")
		alert.window.initialFirstResponder = field
		switch alert.runModal() {
		case .alertFirstButtonReturn:
			guard let value = UInt16(field.stringValue.trimmingCharacters(in: .whitespaces)), value > 0 else {
				NSSound.beep()
				return nil
			}
			return value
		case .alertThirdButtonReturn:
			return defaultPort
		default:
			return nil
		}
	}

	@objc private func toggleLogin() {
		do {
			if SMAppService.mainApp.status == .enabled {
				try SMAppService.mainApp.unregister()
			} else {
				try SMAppService.mainApp.register()
			}
		} catch {
			NSApp.activate()
			NSAlert(error: error).runModal()
		}
	}

	@objc private func quit() {
		NSApp.terminate(nil)
	}
}
