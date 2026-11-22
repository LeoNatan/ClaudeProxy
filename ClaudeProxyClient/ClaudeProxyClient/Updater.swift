import AppKit
import Sparkle

/// Sparkle updates, fed by the appcast attached to the latest GitHub release (`SUFeedURL` in Info.plist).
/// Keep in sync with the other app's copy.
// Sparkle calls its delegates on the main thread; its headers just don't say so.
@MainActor
final class Updater: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
	private var controller: SPUStandardUpdaterController!

	override init() {
		super.init()
		controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
	}

	func makeMenuItem() -> NSMenuItem {
		let item = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
		item.target = controller
		return item
	}

	// MARK: SPUStandardUserDriverDelegate

	/// A menu bar app has no Dock icon or windows to draw attention, so Sparkle asks how scheduled updates should appear.
	var supportsGentleScheduledUpdateReminders: Bool {
		true
	}

	/// Shows the update window in front: otherwise it opens behind whatever app is active.
	func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
		if handleShowingUpdate {
			NSApp.activate()
		}
	}
}
