import AppKit

extension NSMenuItem {
	/// Longest line shown in a menu before wrapping, in characters.
	static let maximumLineLength = 60

	/// A disabled, informational item. Long text wraps onto several lines instead of widening the whole menu.
	static func info(_ text: String) -> NSMenuItem {
		let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
		item.isEnabled = false
		let lines = wrap(text)
		if lines.count > 1 {
			item.attributedTitle = NSAttributedString(string: lines.joined(separator: "\n"), attributes: [
				.font: NSFont.menuFont(ofSize: 0),
				.foregroundColor: NSColor.disabledControlTextColor,
			])
			item.toolTip = text
		}
		return item
	}

	/// Word-wraps to `maximumLineLength`, keeping existing line breaks and hard-breaking very long tokens (paths, URLs).
	static func wrap(_ text: String) -> [String] {
		var lines: [String] = []
		for paragraph in text.components(separatedBy: "\n") {
			var line = ""
			for word in paragraph.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
				var word = word
				while word.count > maximumLineLength {
					if !line.isEmpty {
						lines.append(line)
						line = ""
					}
					lines.append(String(word.prefix(maximumLineLength)))
					word = String(word.dropFirst(maximumLineLength))
				}
				if line.isEmpty {
					line = word
				} else if line.count + 1 + word.count <= maximumLineLength {
					line += " " + word
				} else {
					lines.append(line)
					line = word
				}
			}
			lines.append(line)
		}
		return lines
	}
}
