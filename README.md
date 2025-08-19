<p align="center">
  <img src="Icons/termAIDock.png" alt="TermAI Icon" width="128" />
</p>

## TermAI

TermAI is a native macOS app that combines a full terminal with an AI chat assistant. Select terminal output and send it to chat for analysis, or run suggested commands straight in the integrated terminal.

### Highlights
- **Integrated terminal**: Powered by `SwiftTerm`, with themes and ANSI color support
- **Context-aware chat**: Add selection or last output from the terminal into the chat context (includes cwd and row hints)
- **Model-agnostic**: Works with OpenAI-compatible APIs (OpenAI, local `ollama serve`, etc.)
- **Streaming replies**: Live token streaming in chat bubbles
- **One-click execution**: Code blocks labeled as shell get quick actions: “Add to terminal” and “Run in terminal”
- **Multiple chat tabs**: Independent sessions with per-tab settings and history
- **Persistent state**: Messages and settings stored under Application Support

### Requirements
- **macOS**: 13.0+
- **Swift**: 5.9+

### Getting Started
#### Build & Run (CLI)
```bash
swift build
swift run TermAI
```

#### Build & Run (Xcode)
1. Open `Package.swift` in Xcode
2. Select the `TermAI` scheme
3. Run (⌘R)

### Packaging a .app
Use the provided script to create a signed (or ad‑hoc) app bundle and zip:
```bash
./build_package.sh
```

Optional notarization/signing env vars you can set before invoking the script:
- `DEVELOPER_ID` (e.g. "Developer ID Application: Your Name (TEAMID)")
- `APPLE_ID`, `TEAM_ID`, `APP_PASSWORD`

The script embeds the app icon if available from `Icons/termAIDock.icns` (or falls back to `Icons/TermAI.icns` / `Icons/termai.png`).

### Configuration (Providers & Models)
TermAI speaks the OpenAI Chat Completions API. You can point it at:
- **Ollama (local)**: default `http://localhost:11434/v1` (no API key)
- **OpenAI**: `https://api.openai.com/v1` (API key required)
- **Any OpenAI-compatible endpoint**

Open Settings (⌘,):
- **API Base URL**: Endpoint to target (e.g., `http://localhost:11434/v1` or `https://api.openai.com/v1`)
- **API Key**: Optional for Ollama; required for OpenAI
- **Model**: Choose from fetched list (Ollama local) or type a model name
- Quick presets: “Use Ollama Defaults” or “Use OpenAI Defaults”

Ollama model list fetch is supported only for local servers (localhost/127.0.0.1). Make sure `ollama serve` is running. Example:
```bash
brew install ollama
ollama serve
ollama pull llama3.1
```

### Using the App
#### Terminal → Chat
- Hover the terminal to reveal buttons:
  - **Add Selection**: Sends the highlighted terminal text to chat
  - **Add Last Output**: Sends the most recent output chunk to chat
- TermAI includes metadata like current working directory and line range

#### Chat → Terminal
- For code blocks labeled as shell (```bash, ```sh, ```zsh), you’ll see:
  - **Add to terminal**: Inserts sanitized command(s) into the terminal
  - **Run in terminal**: Inserts and executes the command(s)

#### Multiple Chats
- Open the chat pane via the chat bubble button in the terminal header
- Use the tab row to switch chats; click the plus to create a new chat
- Each chat tab keeps its own messages and settings

### Keyboard Shortcuts
- **New Tab**: ⇧⌘T
- **Send Message**: ⌘⏎
- **Settings**: ⌘,

### Data Persistence
User data lives in:
```
~/Library/Application Support/TermAI/
```

What’s stored:
- Chat messages per session (JSON)
- Session settings per chat (API base URL, API key if provided, model, system prompt, title)
- Global settings if using the legacy single-chat view

### Theming
The terminal supports several presets (System, Xterm, VGA Dark, Terminal.app, Pale). Configure in Settings → Terminal Theme.

### Troubleshooting
- **401/403 errors**: Check API key and base URL
- **No models fetched (Ollama)**: Ensure `ollama serve` is running locally; fetching is only supported for localhost
- **Streaming doesn’t start**: Verify network access to your provider and that it supports streaming via Chat Completions
- **No model selected**: Go to Settings (⌘,) and choose a model; the app will warn in chat if none is set

### Dependencies
- `SwiftTerm` (embedded under `Vendor/SwiftTerm`)
- `Down` (embedded under `Vendor/Down`) — the app currently uses a SwiftUI-based markdown renderer to keep layouts stable, but the dependency is packaged for future use

### Icons
App/Dock and toolbar icons live under `Icons/`. The app and packaging script will prefer dedicated Dock (`termAIDock.icns`) and toolbar (`termAIToolbar.icns`) icons when present.

### License
Project license to be determined. Dependencies retain their original licenses under `Vendor/`.


