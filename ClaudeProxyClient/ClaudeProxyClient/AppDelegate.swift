import AppKit
import Network
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
	private enum Defaults {
		static let selectedServer = "selectedServer"
		static let useManual = "useManualServer"
		static let manualHost = "manualHost"
		static let manualPort = "manualPort"
		static let localPort = "localPort"
	}

	private var statusItem: NSStatusItem!
	private let browser = ServerBrowser()
	private let forwarder = LocalForwarder()
	private let installer = SettingsInstaller()
	private var forwarderStatus: LocalForwarder.Status = .stopped
	private var profile: ClientProfile?
	private var profileError: String?
	private var installError: String?
	private var fetching = false
	private var pollTimer: Timer?

	private var localPort: UInt16 {
		get {
			let stored = UserDefaults.standard.integer(forKey: Defaults.localPort)
			return stored > 0 && stored <= Int(UInt16.max) ? UInt16(stored) : ClaudeProxyProtocol.defaultClientPort
		}
		set {
			UserDefaults.standard.set(Int(newValue), forKey: Defaults.localPort)
		}
	}

	private var useManual: Bool {
		get { UserDefaults.standard.bool(forKey: Defaults.useManual) }
		set { UserDefaults.standard.set(newValue, forKey: Defaults.useManual) }
	}

	private var selectedServerName: String? {
		get { UserDefaults.standard.string(forKey: Defaults.selectedServer) }
		set { UserDefaults.standard.set(newValue, forKey: Defaults.selectedServer) }
	}

	private var manualHost: String {
		get { UserDefaults.standard.string(forKey: Defaults.manualHost) ?? "" }
		set { UserDefaults.standard.set(newValue, forKey: Defaults.manualHost) }
	}

	private var manualPort: UInt16 {
		get {
			let stored = UserDefaults.standard.integer(forKey: Defaults.manualPort)
			return stored > 0 && stored <= Int(UInt16.max) ? UInt16(stored) : ClaudeProxyProtocol.defaultServerPort
		}
		set { UserDefaults.standard.set(Int(newValue), forKey: Defaults.manualPort) }
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
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
		forwarder.start(port: localPort)

		browser.onChange = { [weak self] in
			self?.serversChanged()
		}
		browser.start()
		refreshTarget()

		pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated {
				self?.fetchProfile()
			}
		}
	}

	// MARK: Server selection

	private var selectedServer: ServerBrowser.Server? {
		guard !useManual else {
			return nil
		}
		return browser.servers.first { $0.name == selectedServerName }
	}

	private var currentEndpoint: NWEndpoint? {
		if useManual {
			guard !manualHost.isEmpty, let port = NWEndpoint.Port(rawValue: manualPort) else {
				return nil
			}
			return .hostPort(host: NWEndpoint.Host(manualHost), port: port)
		}
		return selectedServer?.endpoint
	}

	private var currentServerTitle: String? {
		useManual ? (manualHost.isEmpty ? nil : "\(manualHost):\(manualPort)") : selectedServerName
	}

	private func serversChanged() {
		// With nothing chosen yet, a single discovered server is the obvious pick.
		if !useManual, selectedServerName == nil, browser.servers.count == 1 {
			selectedServerName = browser.servers[0].name
		}
		let previous = forwarder.target
		refreshTarget(fetch: false)
		if previous != forwarder.target || (selectedServer?.profileVersion).map({ $0 != profile?.pv }) ?? false {
			fetchProfile()
		}
	}

	private func refreshTarget(fetch: Bool = true) {
		forwarder.target = currentEndpoint
		if forwarder.target == nil {
			profile = nil
			profileError = nil
		}
		updateIcon()
		if fetch {
			fetchProfile()
		}
	}

	/// Handshake: learn the server's provider profile, and re-install if it changed.
	private func fetchProfile() {
		guard let endpoint = currentEndpoint, !fetching else {
			return
		}
		fetching = true
		InfoClient.fetch(endpoint) { [weak self] result in
			guard let self else {
				return
			}
			fetching = false
			guard endpoint == currentEndpoint else {
				fetchProfile()
				return
			}
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

	/// Keeps an existing installation in step with the server's profile and the local port.
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
			guard case .listening = forwarderStatus else {
				return false
			}
			return profile != nil && profileError == nil && installError == nil
		}()
		let symbol = healthy ? (installer.isInstalled ? "point.3.filled.connected.trianglepath.dotted" : "point.3.connected.trianglepath.dotted") : "exclamationmark.triangle"
		statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ClaudeProxy Client")
	}

	// MARK: Menu

	func menuNeedsUpdate(_ menu: NSMenu) {
		menu.removeAllItems()

		if let title = currentServerTitle {
			if let profile {
				let provider = profile.provider == "anthropic" ? "Anthropic API / gateway" : profile.provider
				menu.addItem(info("Server: \(title) — \(provider)"))
			} else if let profileError {
				menu.addItem(info("⚠︎ \(title): \(profileError)"))
			} else {
				menu.addItem(info(useManual || selectedServer != nil ? "Server: \(title) — connecting…" : "Server: \(title) — not found on the network"))
			}
		} else {
			menu.addItem(info("No server selected"))
		}
		switch forwarderStatus {
		case .stopped:
			menu.addItem(info("Local proxy: stopped"))
		case let .listening(port):
			menu.addItem(info("Local proxy: 127.0.0.1:\(port)"))
		case let .failed(message):
			menu.addItem(info("⚠︎ Local proxy: \(message)"))
		}

		menu.addItem(.separator())
		menu.addItem(info("Servers on This Network"))
		if browser.servers.isEmpty {
			menu.addItem(info("    None found"))
		}
		for server in browser.servers {
			let item = item(server.name, #selector(selectServer(_:)))
			item.representedObject = server.name
			item.state = !useManual && server.name == selectedServerName ? .on : .off
			item.indentationLevel = 1
			menu.addItem(item)
		}
		let manual = item(manualHost.isEmpty ? "Manual Server…" : "Manual: \(manualHost):\(manualPort)…", #selector(configureManualServer))
		manual.state = useManual ? .on : .off
		manual.indentationLevel = 1
		menu.addItem(manual)

		menu.addItem(.separator())
		if installer.isInstalled {
			menu.addItem(item("Uninstall from Claude Code", #selector(uninstall)))
			menu.addItem(info("Claude Code uses this proxy (\(SettingsInstaller.displayPath(installer.settingsURL)))"))
		} else {
			let install = item("Install into Claude Code", #selector(install))
			install.isEnabled = profile != nil
			menu.addItem(install)
			if profile == nil {
				menu.addItem(info("Select a reachable server to install"))
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
		menu.addItem(item("Local Port \(localPort)…", #selector(changeLocalPort)))

		menu.addItem(.separator())
		let login = item("Start at Login", #selector(toggleLogin))
		login.state = SMAppService.mainApp.status == .enabled ? .on : .off
		menu.addItem(login)
		menu.addItem(item("Quit ClaudeProxy Client", #selector(quit), key: "q"))
	}

	private func info(_ title: String) -> NSMenuItem {
		let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
		item.isEnabled = false
		return item
	}

	private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
		let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
		item.target = self
		return item
	}

	// MARK: Actions

	@objc private func selectServer(_ sender: NSMenuItem) {
		guard let name = sender.representedObject as? String else {
			return
		}
		useManual = false
		selectedServerName = name
		profile = nil
		profileError = nil
		refreshTarget()
	}

	@objc private func configureManualServer() {
		NSApp.activate()
		let alert = NSAlert()
		alert.messageText = "Manual Server"
		alert.informativeText = "Host name or IP address and port of a ClaudeProxy Server."
		let host = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
		host.placeholderString = "192.168.1.10"
		host.stringValue = manualHost
		let port = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
		port.placeholderString = String(ClaudeProxyProtocol.defaultServerPort)
		port.stringValue = String(manualPort)
		let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
		container.addSubview(host)
		container.addSubview(port)
		alert.accessoryView = container
		alert.addButton(withTitle: "Use This Server")
		alert.addButton(withTitle: "Cancel")
		if useManual {
			alert.addButton(withTitle: "Use Bonjour Instead")
		}
		alert.window.initialFirstResponder = host
		switch alert.runModal() {
		case .alertFirstButtonReturn:
			let hostValue = host.stringValue.trimmingCharacters(in: .whitespaces)
			guard !hostValue.isEmpty, let portValue = UInt16(port.stringValue.trimmingCharacters(in: .whitespaces)), portValue > 0 else {
				NSSound.beep()
				return
			}
			manualHost = hostValue
			manualPort = portValue
			useManual = true
		case .alertThirdButtonReturn:
			useManual = false
		default:
			return
		}
		profile = nil
		profileError = nil
		refreshTarget()
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
		NSApp.activate()
		let alert = NSAlert()
		alert.messageText = "Local Port"
		alert.informativeText = "Claude Code on this Mac connects to 127.0.0.1 on this port."
		let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
		field.stringValue = String(localPort)
		alert.accessoryView = field
		alert.addButton(withTitle: "Save")
		alert.addButton(withTitle: "Cancel")
		alert.window.initialFirstResponder = field
		guard alert.runModal() == .alertFirstButtonReturn else {
			return
		}
		guard let newPort = UInt16(field.stringValue.trimmingCharacters(in: .whitespaces)), newPort > 0 else {
			NSSound.beep()
			return
		}
		localPort = newPort
		forwarder.start(port: newPort)
		syncInstallation()
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
