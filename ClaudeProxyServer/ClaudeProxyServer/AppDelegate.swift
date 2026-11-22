import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
	private static let portDefaultsKey = "port"

	private var statusItem: NSStatusItem!
	private let server = ProxyServer(serviceName: Host.current().localizedName ?? "ClaudeProxy Server")
	private var status: ProxyServer.Status = .stopped
	private var state: ServerState?
	private var fingerprint = ""
	private var reloading = false
	private var watchTimer: Timer?

	private var port: UInt16 {
		get {
			let stored = UserDefaults.standard.integer(forKey: Self.portDefaultsKey)
			return stored > 0 && stored <= Int(UInt16.max) ? UInt16(stored) : ClaudeProxyProtocol.defaultServerPort
		}
		set {
			UserDefaults.standard.set(Int(newValue), forKey: Self.portDefaultsKey)
		}
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		installEditMenu()
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		statusItem.button?.image = NSImage(systemSymbolName: "xserve.raid", accessibilityDescription: "ClaudeProxy Server")
		let menu = NSMenu()
		menu.delegate = self
		statusItem.menu = menu

		server.onStatus = { [weak self] status in
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					self?.status = status
					self?.updateIcon()
				}
			}
		}
		reload()
		server.start(port: port)

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
		let serviceName = server.serviceName
		DispatchQueue.global(qos: .userInitiated).async {
			let settings = SettingsResolver.resolve()
			let fingerprint = SettingsResolver.fingerprint(configDirectory: settings.configDirectory)
			let state = ServerState(settings: settings, serviceName: serviceName)
			DispatchQueue.main.async {
				MainActor.assumeIsolated {
					self.state = state
					self.fingerprint = fingerprint
					self.reloading = false
					self.server.update(state: state)
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

	private func updateIcon() {
		let healthy: Bool = {
			switch status {
			case .running, .runningWithoutBonjour:
				break
			default:
				return false
			}
			guard let state else {
				return false
			}
			return state.problems.isEmpty
		}()
		statusItem.button?.image = NSImage(systemSymbolName: healthy ? "xserve.raid" : "exclamationmark.triangle", accessibilityDescription: "ClaudeProxy Server")
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

		switch status {
		case .stopped:
			menu.addItem(info("Stopped"))
		case .starting:
			menu.addItem(info("Starting on port \(port)…"))
		case let .running(port):
			menu.addItem(info("Running on port \(port) as “\(server.serviceName)”"))
		case let .runningWithoutBonjour(port):
			menu.addItem(info("Running on port \(port) — not advertised over Bonjour (retrying)"))
			menu.addItem(info("ⓘ Allow ClaudeProxy Server in System Settings › Privacy & Security › Local Network"))
		case let .failed(message):
			menu.addItem(info("⚠︎ Listener failed: \(message)"))
		}

		let addresses = Self.localAddresses()
		if !addresses.isEmpty {
			menu.addItem(info("Copy Address for a Client’s Manual Server:"))
			for address in addresses {
				let copy = item("\(address.ip):\(port)  (\(address.interface))", #selector(copyAddress(_:)))
				copy.representedObject = "\(address.ip):\(port)"
				copy.indentationLevel = 1
				menu.addItem(copy)
			}
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
		menu.addItem(item("Port \(port)…", #selector(changePort)))
		menu.addItem(item(reloading ? "Reloading…" : "Reload Claude Settings", #selector(reloadSettings)))
		let login = item("Start at Login", #selector(toggleLogin))
		login.state = SMAppService.mainApp.status == .enabled ? .on : .off
		menu.addItem(login)
		menu.addItem(.separator())
		menu.addItem(item("Quit ClaudeProxy Server", #selector(quit), key: "q"))
	}

	private func effectiveSettingsMenu(_ settings: ResolvedSettings) -> NSMenu {
		let menu = NSMenu()
		var any = false
		for name in ServerState.displayedVariables {
			guard let setting = settings.env[name], !(setting.source == "login shell" && setting.value.isEmpty) else {
				continue
			}
			let shown = setting.value.isEmpty ? "(unset)" : CredentialStore.isSecret(name) ? "(set)" : setting.value
			menu.addItem(info("\(name) = \(shown)\n    \(setting.source)"))
			any = true
		}
		for name in ServerState.displayedKeys {
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

	@objc private func changePort() {
		NSApp.activate()
		let alert = NSAlert()
		alert.messageText = "Server Port"
		alert.informativeText = "Clients that found this server over Bonjour follow the change automatically. Manually configured clients need the new port."
		let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
		field.stringValue = String(port)
		alert.accessoryView = field
		alert.addButton(withTitle: "Save")
		alert.addButton(withTitle: "Cancel")
		alert.addButton(withTitle: "Use Default (\(ClaudeProxyProtocol.defaultServerPort))")
		alert.window.initialFirstResponder = field
		let newPort: UInt16
		switch alert.runModal() {
		case .alertFirstButtonReturn:
			guard let value = UInt16(field.stringValue.trimmingCharacters(in: .whitespaces)), value > 0 else {
				NSSound.beep()
				return
			}
			newPort = value
		case .alertThirdButtonReturn:
			newPort = ClaudeProxyProtocol.defaultServerPort
		default:
			return
		}
		port = newPort
		server.start(port: newPort)
	}

	@objc private func copyAddress(_ sender: NSMenuItem) {
		guard let value = sender.representedObject as? String else {
			return
		}
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(value, forType: .string)
	}

	/// IPv4 addresses of active LAN interfaces, the ones a client on the same network can reach.
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
