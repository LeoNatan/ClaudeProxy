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
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		statusItem.button?.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "ClaudeProxy Server")
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
		statusItem.button?.image = NSImage(systemSymbolName: healthy ? "server.rack" : "exclamationmark.triangle", accessibilityDescription: "ClaudeProxy Server")
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

		if let state {
			menu.addItem(.separator())
			menu.addItem(info("Provider: \(state.plan.provider.displayName)\(state.plan.region.map { " (\($0))" } ?? "")"))
			menu.addItem(info("Upstream: \(state.plan.displayUpstream)"))
			menu.addItem(info("Credentials: \(state.credentials.summary)"))
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
			menu.addItem(info("\(name) = \(shown)  — \(setting.source)"))
			any = true
		}
		for name in ServerState.displayedKeys {
			guard let setting = settings.keys[name] else {
				continue
			}
			menu.addItem(info("\(name) = \(setting.value)  — \(setting.source)"))
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
		alert.window.initialFirstResponder = field
		guard alert.runModal() == .alertFirstButtonReturn else {
			return
		}
		guard let newPort = UInt16(field.stringValue.trimmingCharacters(in: .whitespaces)), newPort > 0 else {
			NSSound.beep()
			return
		}
		port = newPort
		server.start(port: newPort)
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
