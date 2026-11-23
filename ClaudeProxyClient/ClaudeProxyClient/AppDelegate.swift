import AppKit
import Network
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
	private enum Defaults {
		static let localPort = "localPort"
		static let networkPort = "networkPort"
		/// Set when the user ticks "Don't ask again"; stops the offer to enable at launch.
		static let skipInstallOffer = "skipInstallOffer"
		/// Whether the user wants the client enabled. The settings themselves are only in place while the app runs:
		/// removed on quit, written again once a host's profile arrives after launch.
		static let clientEnabled = "clientEnabled"
	}

	private var wantsEnabled: Bool {
		get { UserDefaults.standard.bool(forKey: Defaults.clientEnabled) }
		set { UserDefaults.standard.set(newValue, forKey: Defaults.clientEnabled) }
	}

	private static let serviceName = Host.current().localizedName ?? "ClaudeProxy Client"

	private var statusItem: NSStatusItem!
	private let updater = Updater()
	private let pool = HostConnectionPool(serviceName: AppDelegate.serviceName)
	private lazy var forwarder = LocalForwarder(pool: pool)
	private let installer = SettingsInstaller()
	private var forwarderStatus: LocalForwarder.Status = .stopped
	private var poolStatus: HostConnectionPool.Status = .stopped
	private var profile: ClientProfile?
	private var profileError: String?
	private var installError: String?
	private var fetching = false
	private var offeredInstall = false
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
		// Versions up to 1.3.2 kept the settings in place across quits and had no separate record of the choice.
		if installer.isInstalled && UserDefaults.standard.object(forKey: Defaults.clientEnabled) == nil {
			wantsEnabled = true
		}
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
		// Host connections coming and going change the icon; a host connecting for the first time is the moment to learn its profile.
		pool.onChange = { [weak self] in
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					guard let self else {
						return
					}
					self.updateIcon()
					if self.profile == nil || self.profileError != nil {
						self.fetchProfile()
					}
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

	private func fetchProfile(over connection: HostConnection?) {
		guard let connection else {
			fetching = false
			updateIcon()
			return
		}
		InfoClient.fetch(over: connection, pool: pool) { [weak self] result in
			guard let self else {
				return
			}
			fetching = false
			switch result {
			case let .success(profile):
				self.profile = profile
				profileError = nil
				syncInstallation()
				offerInstallIfNeeded()
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

	/// While the client is enabled, puts the settings in place once a host's profile is known (after launch) and keeps
	/// them in step with the profile and the local port.
	private func syncInstallation() {
		guard wantsEnabled, let desiredEnv, desiredEnv != installer.installedEnv else {
			return
		}
		do {
			try installer.install(env: desiredEnv)
			installError = nil
		} catch {
			installError = error.localizedDescription
		}
	}

	/// The client is meant to be the way Claude Code works on this Mac, so while it's disabled it offers to enable as
	/// soon as a host provides the settings: once per launch, until the user ticks "Don't ask again".
	private func offerInstallIfNeeded() {
		guard !offeredInstall, !wantsEnabled, !UserDefaults.standard.bool(forKey: Defaults.skipInstallOffer) else {
			return
		}
		offeredInstall = true
		NSApp.activate()
		let alert = NSAlert()
		alert.messageText = "Enable ClaudeProxy Client?"
		alert.informativeText = "Claude Code on this Mac will connect through this client with no login needed here."
		alert.addButton(withTitle: "Enable")
		alert.addButton(withTitle: "Not Now")
		alert.showsSuppressionButton = true
		alert.suppressionButton?.title = "Don’t ask again"
		guard alert.runModal() == .alertFirstButtonReturn else {
			if alert.suppressionButton?.state == .on {
				UserDefaults.standard.set(true, forKey: Defaults.skipInstallOffer)
			}
			return
		}
		wantsEnabled = true
		install()
	}

	private func updateIcon() {
		let healthy: Bool = {
			guard case .listening = forwarderStatus, case .listening = poolStatus else {
				return false
			}
			return pool.hasHost && profile != nil && profileError == nil && installError == nil
		}()
		// Filled while a host is connected and serving; the menu explains anything else.
		let symbol = healthy ? "point.3.filled.connected.trianglepath.dotted" : "point.3.connected.trianglepath.dotted"
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
			let provider = profile.provider == "anthropic" ? "Anthropic API / Gateway" : profile.provider
			menu.addItem(info("Host: \(profile.name) — \(provider)\(hasHost ? "" : " (Disconnected)")"))
		} else if hasHost {
			menu.addItem(info(profileError.map { "⚠︎ Host Connected, but: \($0)" } ?? "Host Connected — Loading…"))
		} else {
			menu.addItem(info("Waiting for a ClaudeProxy Host to Connect"))
		}

		switch poolStatus {
		case .stopped:
			break
		case let .listening(port, advertised):
			menu.addItem(info(advertised ? "Discoverable as “\(pool.serviceName)” on Port \(port)" : "Listening on Port \(port), Not Advertised Over Bonjour (Retrying)"))
			if !advertised {
				menu.addItem(info("ⓘ Allow ClaudeProxy Client in System Settings › Privacy & Security › Local Network"))
			}
		case let .failed(message):
			menu.addItem(info("⚠︎ Network Listener: \(message)"))
		}
		switch forwarderStatus {
		case .stopped:
			break
		case let .listening(port):
			menu.addItem(info("Claude Code Connects to 127.0.0.1:\(port)"))
		case let .failed(message):
			menu.addItem(info("⚠︎ Local Proxy: \(message)"))
		}

		let hosts = pool.knownHosts
		if hosts.count > 1 || hosts.contains(where: { !$0.isSelected }) {
			menu.addItem(.separator())
			menu.addItem(.sectionHeader(title: "Hosts"))
			for host in hosts {
				let suffix = host.isSelected ? (hasHost ? "" : " — Offline") : ""
				let entry = item(host.name + suffix, #selector(selectHost(_:)))
				entry.representedObject = host.id
				entry.state = host.isSelected ? .on : .off
				menu.addItem(entry)
			}
		}

		menu.addItem(.separator())
		
		let addresses = Self.localAddresses()
		if !addresses.isEmpty {
			menu.addItem(.sectionHeader(title: "Copy to Pasteboard"))
			for address in addresses {
				let copy = item("\(address.ip):\(networkPort)  (\(address.interface))", #selector(copyAddress(_:)))
				copy.representedObject = "\(address.ip):\(networkPort)"
				menu.addItem(copy)
			}
		}

		menu.addItem(.separator())
		let enabled = item("Client Enabled", #selector(toggleEnabled))
		enabled.state = wantsEnabled ? .on : .off
		menu.addItem(enabled)
		if installer.isInstalled {
			menu.addItem(info("Claude Code Uses This Proxy (\(SettingsInstaller.displayPath(installer.settingsURL)))"))
		} else if wantsEnabled {
			menu.addItem(info("Takes Effect Once a Host Has Connected"))
		}
		if let installError {
			menu.addItem(info("⚠︎ \(installError)"))
		}
		if let desiredEnv {
			let overridden = installer.managedOverrides(for: desiredEnv)
			if !overridden.isEmpty {
				menu.addItem(info("⚠︎ Managed Settings Override: \(overridden.joined(separator: ", "))"))
			}
		}

		menu.addItem(.separator())
		menu.addItem(item("Local Port \(localPort)…", #selector(changeLocalPort)))
		menu.addItem(item("Network Port \(networkPort)…", #selector(changeNetworkPort)))
		menu.addItem(updater.makeMenuItem())
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

	@objc private func selectHost(_ sender: NSMenuItem) {
		guard let id = sender.representedObject as? String, sender.state != .on else {
			return
		}
		pool.select(hostID: id)
		// The new host's settings replace the old one's once it connects (within about 10 s).
		profile = nil
		profileError = nil
		updateIcon()
	}

	@objc private func copyAddress(_ sender: NSMenuItem) {
		guard let value = sender.representedObject as? String else {
			return
		}
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(value, forType: .string)
	}

	@objc private func toggleEnabled() {
		wantsEnabled.toggle()
		if wantsEnabled {
			install()
		} else if installer.isInstalled {
			uninstall()
		} else {
			updateIcon()
		}
	}

	/// Without a host's profile yet, `syncInstallation()` installs once one arrives.
	private func install() {
		guard let desiredEnv else {
			updateIcon()
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

	/// Disabling is remembered, and the next launch offers to enable again.
	private func uninstall() {
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
		let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
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

	/// Nothing listens on the local port once the app is gone, so Claude Code must stop using it. Covers Quit, logout,
	/// shutdown and Sparkle relaunches; `wantsEnabled` stays, so the next launch puts the settings back.
	func applicationWillTerminate(_ notification: Notification) {
		guard installer.isInstalled else {
			return
		}
		try? installer.uninstall()
	}
}
