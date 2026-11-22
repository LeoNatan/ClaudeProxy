import AppKit
import Network
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
	private enum Defaults {
		static let excludedClients = "excludedClients"
		static let manualClients = "manualClients"
	}

	private static let serviceName = Host.current().localizedName ?? "ClaudeProxy Host"

	private var statusItem: NSStatusItem!
	private let updater = Updater()
	private let links = ClientLinkManager()
	private let browser = ClientBrowser()
	private var state: HostState?
	private var fingerprint = ""
	private var reloading = false
	private var watchTimer: Timer?

	func applicationDidFinishLaunching(_ notification: Notification) {
		installEditMenu()
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		statusItem.button?.image = NSImage(systemSymbolName: "xserve.raid", accessibilityDescription: "ClaudeProxy Host")
		let menu = NSMenu()
		menu.delegate = self
		statusItem.menu = menu

		links.onChange = { [weak self] in
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					self?.updateIcon()
				}
			}
		}
		browser.onChange = { [weak self] in
			self?.updateClients()
		}
		reload()
		browser.start()
		updateClients()

		// Settings files are polled; shell profile changes need "Reload Claude Settings".
		watchTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated {
				self?.checkForSettingsChanges()
			}
		}
	}

	// MARK: Settings

	private func reload() {
		guard !reloading else {
			return
		}
		reloading = true
		let serviceName = Self.serviceName
		DispatchQueue.global(qos: .userInitiated).async {
			let settings = SettingsResolver.resolve()
			let fingerprint = SettingsResolver.fingerprint(configDirectory: settings.configDirectory)
			let state = HostState(settings: settings, serviceName: serviceName)
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					self.state = state
					self.fingerprint = fingerprint
					self.reloading = false
					self.links.update(state: state)
					self.updateIcon()
				}
			}
		}
	}

	private func checkForSettingsChanges() {
		guard let state, !reloading else {
			return
		}
		let directory = state.settings.configDirectory
		DispatchQueue.global(qos: .utility).async {
			let current = SettingsResolver.fingerprint(configDirectory: directory)
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					if current != self.fingerprint {
						self.reload()
					}
				}
			}
		}
	}

	// MARK: Clients

	private var excludedClients: Set<String> {
		get { Set(UserDefaults.standard.stringArray(forKey: Defaults.excludedClients) ?? []) }
		set { UserDefaults.standard.set(newValue.sorted(), forKey: Defaults.excludedClients) }
	}

	/// "host:port" entries for clients that can't be discovered over Bonjour.
	private var manualClients: [String] {
		get { UserDefaults.standard.stringArray(forKey: Defaults.manualClients) ?? [] }
		set { UserDefaults.standard.set(newValue, forKey: Defaults.manualClients) }
	}

	private static func bonjourKey(_ name: String) -> String {
		"bonjour:\(name)"
	}

	private static func manualKey(_ address: String) -> String {
		"manual:\(address)"
	}

	private static func endpoint(forManual address: String) -> NWEndpoint? {
		guard let colon = address.lastIndex(of: ":"), let port = NWEndpoint.Port(String(address[address.index(after: colon)...])) else {
			return nil
		}
		return .hostPort(host: NWEndpoint.Host(String(address[..<colon])), port: port)
	}

	/// Every discovered client is served unless excluded, plus the manual entries.
	private func updateClients() {
		let excluded = excludedClients
		var targets: [String: NWEndpoint] = [:]
		for client in browser.clients where !excluded.contains(Self.bonjourKey(client.name)) {
			targets[Self.bonjourKey(client.name)] = client.endpoint
		}
		for address in manualClients where !excluded.contains(Self.manualKey(address)) {
			if let endpoint = Self.endpoint(forManual: address) {
				targets[Self.manualKey(address)] = endpoint
			}
		}
		links.setClients(targets)
	}

	private func updateIcon() {
		// Only a configuration problem that stops every request earns the warning; still loading settings doesn't.
		let healthy = state.map { $0.problems.isEmpty } ?? true
		statusItem.button?.image = NSImage(systemSymbolName: healthy ? "xserve.raid" : "exclamationmark.triangle", accessibilityDescription: "ClaudeProxy Host")
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

		let statuses = links.statuses()
		let excluded = excludedClients
		menu.addItem(info("Clients"))
		if browser.clients.isEmpty && manualClients.isEmpty {
			menu.addItem(info("    None found yet"))
		}
		func addClient(title: String, key: String) {
			let status: String
			switch statuses[key] {
			case .connected: status = "connected"
			case .connecting: status = "connecting…"
			case .unreachable: status = "unreachable"
			case nil: status = "not served"
			}
			let client = item("\(title) — \(status)", #selector(toggleClient(_:)))
			client.representedObject = key
			client.state = excluded.contains(key) ? .off : .on
			client.indentationLevel = 1
			menu.addItem(client)
		}
		for client in browser.clients {
			addClient(title: client.name, key: Self.bonjourKey(client.name))
		}
		for address in manualClients {
			addClient(title: address, key: Self.manualKey(address))
		}
		let add = item("Add Client by Address…", #selector(addManualClient))
		add.indentationLevel = 1
		menu.addItem(add)
		if !manualClients.isEmpty {
			let remove = NSMenuItem(title: "Remove Client by Address", action: nil, keyEquivalent: "")
			remove.indentationLevel = 1
			let removeMenu = NSMenu()
			for address in manualClients {
				let entry = item(address, #selector(removeManualClient(_:)))
				entry.representedObject = address
				removeMenu.addItem(entry)
			}
			remove.submenu = removeMenu
			menu.addItem(remove)
		}

		if let state {
			menu.addItem(.separator())
			menu.addItem(info("Provider: \(state.plan.provider.displayName)\(state.plan.region.map { " (\($0))" } ?? "")"))
			menu.addItem(info("Upstream: \(state.plan.displayUpstream)"))
			let credentials = NSMenuItem(title: "Credentials: \(state.credentials.summary)", action: nil, keyEquivalent: "")
			if !state.credentials.details.isEmpty {
				let details = NSMenu()
				for detail in state.credentials.details {
					details.addItem(info(detail))
				}
				credentials.submenu = details
			} else {
				credentials.isEnabled = false
			}
			menu.addItem(credentials)
			if let network = state.network.summary {
				menu.addItem(info("Network: \(network)"))
			}
			for problem in state.problems {
				menu.addItem(info("⚠︎ \(problem)"))
			}
			for note in state.notes {
				menu.addItem(info("ⓘ \(note)"))
			}

			let effective = NSMenuItem(title: "Effective Claude Settings", action: nil, keyEquivalent: "")
			effective.submenu = effectiveSettingsMenu(state.settings)
			menu.addItem(effective)

			let profile = NSMenuItem(title: "Settings Sent to Clients", action: nil, keyEquivalent: "")
			let profileMenu = NSMenu()
			profileMenu.addItem(info("\(state.profile.baseURLVariable) = http://127.0.0.1:<client port>"))
			for name in state.profile.env.keys.sorted() {
				let value = state.profile.env[name]!
				profileMenu.addItem(info("\(name) = \(value.isEmpty ? "(unset)" : value)"))
			}
			profile.submenu = profileMenu
			menu.addItem(profile)
		} else {
			menu.addItem(info("Reading Claude settings…"))
		}

		menu.addItem(.separator())
		menu.addItem(item(reloading ? "Reloading…" : "Reload Claude Settings", #selector(reloadSettings)))
		menu.addItem(updater.makeMenuItem())
		let login = item("Start at Login", #selector(toggleLogin))
		login.state = SMAppService.mainApp.status == .enabled ? .on : .off
		menu.addItem(login)
		menu.addItem(.separator())
		menu.addItem(item("Quit ClaudeProxy Host", #selector(quit), key: "q"))
	}

	private func effectiveSettingsMenu(_ settings: ResolvedSettings) -> NSMenu {
		let menu = NSMenu()
		var any = false
		for name in HostState.displayedVariables {
			guard let setting = settings.env[name], !(setting.source == "login shell" && setting.value.isEmpty) else {
				continue
			}
			let shown = setting.value.isEmpty ? "(unset)" : CredentialStore.isSecret(name) ? "(set)" : setting.value
			menu.addItem(info("\(name) = \(shown)\n    \(setting.source)"))
			any = true
		}
		for name in HostState.displayedKeys {
			guard let setting = settings.keys[name] else {
				continue
			}
			menu.addItem(info("\(name) = \(setting.value)\n    \(setting.source)"))
			any = true
		}
		if !any {
			menu.addItem(info("No connection settings found; using api.anthropic.com defaults."))
		}
		menu.addItem(.separator())
		menu.addItem(info("Config directory: \(SettingsResolver.displayPath(settings.configDirectory))"))
		return menu
	}

	private func info(_ title: String) -> NSMenuItem {
		NSMenuItem.info(title)
	}

	private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
		let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
		item.target = self
		return item
	}

	// MARK: Actions

	@objc private func toggleClient(_ sender: NSMenuItem) {
		guard let key = sender.representedObject as? String else {
			return
		}
		var excluded = excludedClients
		if excluded.contains(key) {
			excluded.remove(key)
		} else {
			excluded.insert(key)
		}
		excludedClients = excluded
		updateClients()
	}

	@objc private func addManualClient() {
		NSApp.activate()
		let alert = NSAlert()
		alert.messageText = "Add Client by Address"
		alert.informativeText = "For a client that isn’t discovered automatically. Its menu has a Copy item for its address."
		let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
		field.placeholderString = "192.168.1.20:\(ClaudeProxyProtocol.defaultClientNetworkPort)"
		alert.accessoryView = field
		alert.addButton(withTitle: "Add")
		alert.addButton(withTitle: "Cancel")
		alert.window.initialFirstResponder = field
		guard alert.runModal() == .alertFirstButtonReturn else {
			return
		}
		var address = field.stringValue.trimmingCharacters(in: .whitespaces)
		if !address.isEmpty && !address.contains(":") {
			address += ":\(ClaudeProxyProtocol.defaultClientNetworkPort)"
		}
		guard Self.endpoint(forManual: address) != nil else {
			NSSound.beep()
			return
		}
		if !manualClients.contains(address) {
			manualClients.append(address)
		}
		updateClients()
	}

	@objc private func removeManualClient(_ sender: NSMenuItem) {
		guard let address = sender.representedObject as? String else {
			return
		}
		manualClients.removeAll { $0 == address }
		excludedClients.remove(Self.manualKey(address))
		updateClients()
	}

	@objc private func reloadSettings() {
		reload()
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
