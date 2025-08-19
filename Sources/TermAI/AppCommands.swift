import SwiftUI

@MainActor
struct AppCommands: Commands {
	let addNewTab: () -> Void

	var body: some Commands {
		CommandGroup(replacing: .textFormatting) { }
		CommandGroup(replacing: .newItem) {
			Button("New Tab") { addNewTab() }
				.keyboardShortcut("t", modifiers: [.command, .shift])
		}
	}
}


