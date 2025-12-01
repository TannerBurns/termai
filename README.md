<p align="center">
  <img src="Icons/termAIDock.png" alt="TermAI Icon" width="128" />
</p>

# TermAI

TermAI is a native macOS application that combines a full-featured terminal emulator with an AI chat assistant. Use it as a powerful terminal with AI superpowers—select terminal output and send it to chat for analysis, run suggested commands directly, or enable **Agent Mode** to let the AI autonomously complete complex tasks.

## Features

### Core Experience
- **Side-by-Side Layout** — Terminal and chat panels with a resizable divider
- **Multiple Tabs** — Each tab contains its own terminal and chat sessions
- **Multiple Chat Sessions** — Create independent chat sessions per tab with their own settings
- **Persistent State** — Messages, settings, and sessions are saved automatically

### AI Providers
- **Cloud Providers** — OpenAI and Anthropic with API key support
- **Local Providers** — Ollama, LM Studio, and vLLM with auto-detection
- **Model Selection** — Curated model lists with favorites for quick access
- **Reasoning Models** — Full support for OpenAI o-series and Anthropic extended thinking

### Agent Mode
When enabled, the AI can autonomously execute commands and use tools to complete complex tasks:
- **Planning Phase** — Generates a step-by-step plan before execution
- **Periodic Reflection** — Pauses to assess progress and adjust strategy
- **Built-in Tools** — File operations, directory browsing, HTTP requests, process management
- **Verification** — Tests and verifies work before declaring completion
- **Safety Controls** — Optional command approval with auto-approve for read-only commands

### Terminal
- **SwiftTerm Powered** — Full terminal emulation with ANSI color support
- **Multiple Themes** — System, Xterm, VGA Dark, Terminal.app, Pale
- **Context Actions** — Select text or capture last output to send to chat
- **Code Execution** — Run shell commands directly from chat code blocks

### Analytics
- **Token Usage Tracking** — Monitor usage by provider, model, and time range
- **Context Window Indicator** — Visual display of context usage percentage
- **Request Type Breakdown** — Track chat, tool calls, planning, and more

## Requirements

- **macOS** 13.0+
- **Swift** 5.9+

## Getting Started

### Build & Run (CLI)
```bash
swift build
swift run TermAI
```

### Build & Run (Xcode)
1. Open `Package.swift` in Xcode
2. Select the `TermAI` scheme
3. Run (Cmd+R)

### Packaging a .app Bundle
Use the provided script to create a signed (or ad-hoc) application bundle:
```bash
./build_package.sh
```

Optional environment variables for signing and notarization:
- `DEVELOPER_ID` — e.g., "Developer ID Application: Your Name (TEAMID)"
- `APPLE_ID`, `TEAM_ID`, `APP_PASSWORD` — For notarization

## Configuration

### Cloud Providers (OpenAI, Anthropic)

Set API keys via environment variables:
```bash
export OPENAI_API_KEY="sk-..."
export ANTHROPIC_API_KEY="sk-ant-..."
```

Or configure them in **Settings > Chat & Model > API Keys** to override environment variables.

Available cloud models include:
- **OpenAI** — GPT-5 series, GPT-4.1/4o series, o-series reasoning models
- **Anthropic** — Claude 4.x, Claude 3.7/3.5 series

### Local Providers (Ollama, LM Studio, vLLM)

1. Start your local LLM server
2. Open **Settings > Chat & Model**
3. Select your provider (auto-configures the default URL)
4. Click **Test Connection** to verify
5. Click **Fetch Models** to load available models

Default endpoints:
| Provider   | Default URL                    |
|------------|--------------------------------|
| Ollama     | `http://localhost:11434/v1`    |
| LM Studio  | `http://localhost:1234/v1`     |
| vLLM       | `http://localhost:8000/v1`     |

Example Ollama setup:
```bash
brew install ollama
ollama serve
ollama pull llama3.1
```

### Generation Settings

- **Temperature** — Controls output randomness (locked to 1.0 for reasoning models)
- **Max Tokens** — Maximum response length
- **Reasoning Effort** — For supported models: None, Low, Medium, High

### Context Window

For local models, you can set a custom context size if auto-detection is incorrect. Common sizes: 4K, 8K, 32K, 128K tokens.

## Using the App

### Terminal to Chat
Hover over the terminal to reveal action buttons:
- **Add Selection** — Send highlighted text to chat with metadata
- **Add Last Output** — Send the most recent command output to chat

Context includes the current working directory and line range hints.

### Chat to Terminal
Code blocks labeled as shell (`bash`, `sh`, `zsh`) show quick actions:
- **Add to Terminal** — Insert command(s) into the terminal
- **Run in Terminal** — Insert and execute immediately

### Agent Mode

Toggle agent mode with the brain icon in the chat header. When enabled:

1. Describe your goal in natural language
2. The agent plans the approach
3. Commands execute automatically with output captured
4. The agent iterates until the goal is complete

**Available Tools:**

| Tool | Description |
|------|-------------|
| `read_file` | Read file contents with optional line range |
| `write_file` | Write or append content to files |
| `edit_file` | Search and replace text in files |
| `insert_lines` | Insert lines at a specific position |
| `delete_lines` | Delete a range of lines |
| `list_dir` | List directory contents |
| `search_files` | Find files by name pattern |
| `search_output` | Search through previous command outputs |
| `memory` | Save and recall notes during execution |
| `run_background` | Start background processes (e.g., servers) |
| `check_process` | Check if a process is running |
| `stop_process` | Stop a background process |
| `http_request` | Make HTTP requests to test APIs |

### Agent Settings

Configure agent behavior in **Settings > Agent**:

- **Execution Limits** — Max steps, fix attempts, command timeout
- **Planning & Reflection** — Enable/disable planning phase, reflection interval
- **Context & Memory** — Output capture limits, context window size
- **Safety** — Require command approval, auto-approve read-only commands
- **Verbose Logging** — Debug output for troubleshooting

## Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| New Tab | Cmd+T |
| New Chat Session | Shift+Cmd+T |
| Close Tab | Cmd+W |
| Close Chat Session | Shift+Cmd+W |
| Next Tab | Cmd+Shift+] |
| Previous Tab | Cmd+Shift+[ |
| Switch to Tab 1-9 | Cmd+1 through Cmd+9 |
| Send Message | Cmd+Enter |
| Settings | Cmd+, |

## Data Storage

User data is stored in:
```
~/Library/Application Support/TermAI/
```

Contents:
- Chat messages per session (JSON)
- Session settings (provider, model, system prompt, title)
- Agent settings (global)
- Token usage records (daily files, 30-day retention)

Logs are stored in:
```
~/Library/Caches/TermAI/Logs/
```

## Theming

Configure the terminal appearance in **Settings > Terminal Theme**:

- **System** — Follows macOS appearance
- **Xterm** — Classic xterm colors
- **VGA Dark** — VGA palette on black
- **Terminal.app** — Matches macOS Terminal
- **Pale** — GNOME-style muted colors

Each theme includes a live preview and color palette display.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| 401/403 errors | Verify API key and base URL in Settings |
| No models found (local) | Ensure the server is running; click Test Connection |
| Streaming doesn't start | Check network access and provider compatibility |
| Agent stuck in loop | Increase stuck detection threshold or reduce max iterations |
| Context limit warnings | Switch to a model with larger context or clear chat history |

## Dependencies

- **SwiftTerm** — Terminal emulation (vendored under `Vendor/SwiftTerm`)
- **MarkdownUI** — Markdown rendering (vendored under `Vendor/MarkdownUI`)
- **swift-collections** — Data structures (vendored)
- **swift-argument-parser** — CLI parsing (vendored)

## Icons

Application icons are located in `Icons/`:
- `termAIDock.icns` — Dock and app icon
- `termAIToolbar.icns` — Menu bar icon

## License

Project license to be determined. Dependencies retain their original licenses under `Vendor/`.
