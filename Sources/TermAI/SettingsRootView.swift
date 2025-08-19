import SwiftUI

struct SettingsRootView: View {
    var selectedSession: ChatSession?
    @ObservedObject var ptyModel: PTYModel

    var body: some View {
        TabView {
            // Chat & Model settings (existing SessionSettingsView)
            Group {
                if let selectedSession {
                    SessionSettingsView(session: selectedSession)
                } else {
                    Text("No chat session selected")
                        .padding()
                        .frame(width: 400, height: 200)
                }
            }
            .tabItem {
                Label("Chat & Model", systemImage: "message")
            }

            // Terminal Theme settings
            TerminalThemeSettingsView(ptyModel: ptyModel)
                .tabItem {
                    Label("Terminal Theme", systemImage: "paintpalette")
                }
        }
        .frame(minWidth: 520, minHeight: 440)
    }
}

struct TerminalThemeSettingsView: View {
    @ObservedObject var ptyModel: PTYModel

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Preset", selection: $ptyModel.themeId) {
                    ForEach(TerminalTheme.presets, id: \.id) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Preview") {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(terminalTheme.background))
                        .frame(width: 42, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.gray.opacity(0.2))
                        )
                    Text("Background")
                    Spacer()
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(terminalTheme.foreground))
                        .frame(width: 42, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.gray.opacity(0.2))
                        )
                    Text("Foreground")
                }
                .padding(.vertical, 4)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(ansiPreview.enumerated()), id: \.offset) { idx, nsColor in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(nsColor))
                                .frame(width: 24, height: 16)
                                .overlay(Text("\(idx)").font(.system(size: 8)).foregroundColor(.black).opacity(0.35))
                        }
                    }
                }
                .frame(height: 28)
            }
        }
        .padding(12)
    }

    private var terminalTheme: TerminalTheme {
        TerminalTheme.presets.first(where: { $0.id == ptyModel.themeId }) ?? TerminalTheme.presets.first ?? TerminalTheme.system()
    }

    private var ansiPreview: [NSColor] {
        guard let palette = terminalTheme.ansi16Palette else { return [] }
        return palette.map { NSColor(calibratedRed: CGFloat($0.red)/65535.0, green: CGFloat($0.green)/65535.0, blue: CGFloat($0.blue)/65535.0, alpha: 1) }
    }
}


