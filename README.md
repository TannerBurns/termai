<p align="center">
  <img src="Icons/termAIDock.png" alt="TermAI Icon" width="128" />
</p>

# TermAI

TermAI is a native macOS application that combines a full-featured terminal emulator with an AI chat assistant. Use it as a powerful terminal with AI superpowers—select terminal output and send it to chat for analysis, run suggested commands directly, or enable **Agent Mode** to let the AI autonomously complete complex tasks.

## Features

### Core Experience
- **Native macOS App** — Built with SwiftUI for a fast, responsive experience
- **IDE-Style Layout** — File tree, terminal, editor tabs, and chat panels with resizable dividers
- **Multiple Windows** — Each window has independent tabs, sessions, and state
- **Multiple Tabs** — Each tab contains its own terminal and chat sessions
- **Multiple Chat Sessions** — Create independent chat sessions per tab with their own settings
- **Persistent State** — Messages, settings, and sessions are saved automatically
- **Menu Bar Integration** — Quick access to TermAI with provider and model status display
- **Dock Menu** — Right-click dock icon for recent projects and quick window creation
- **Finder Integration** — Right-click folders in Finder to open in TermAI via Services menu
- **Performance Monitoring** — Real-time CPU and memory usage graphs in the tab bar

### AI Providers
- **Cloud Providers** — OpenAI, Anthropic, and Google AI Studio with API key support
- **Local Providers** — Ollama, LM Studio, and vLLM with auto-detection
- **Availability Detection** — Local providers show "Not Running" status when server is offline
- **Model Selection** — Curated model lists with favorites for quick access
- **Reasoning Models** — Full support for OpenAI o-series and Anthropic extended thinking
- **Flexible API Keys** — Use environment variables or configure in-app overrides

### File Explorer
- **File Tree Sidebar** — Browse project files synced to the terminal's working directory
- **Smart Filtering** — Automatically ignores node_modules, .git, build folders, and gitignored files
- **Search** — Quick filter to find files by name
- **Language Icons** — Color-coded icons for Swift, Python, JavaScript, TypeScript, Rust, Go, and more
- **Lazy Loading** — Directories load on expand for fast navigation of large projects
- **Navigation Buttons** — Quick access to home (~) and parent (..) directories
- **Folder Navigation** — Double-click a folder to cd into it in the terminal
- **Context Menu** — Right-click for "Open in Terminal", "Reveal in Finder", "Copy Path"
- **Resizable** — Drag to adjust sidebar width

### Editor Tabs
- **IDE-Style Tabs** — Open files in tabs alongside the terminal
- **Preview Mode** — Single-click opens files in preview (italic), double-click to pin
- **Syntax Highlighting** — Multi-language support with theme-aware colors
- **Line Numbers** — With diff indicators showing added/modified lines
- **Search in File** — Regex support with case-sensitive and whole-word options
- **Image Preview** — View PNG, JPG, GIF, WebP, and SVG with transparency support
- **Markdown Preview** — Toggle between source code and rendered markdown
- **Edit & Save** — Full editing with Cmd+S to save, undo/redo support
- **Live Reload** — Prompt to reload when agent modifies an open file
- **Add to Chat** — Send file content or selected lines to chat with line numbers

### Terminal
- **SwiftTerm Powered** — Full terminal emulation with ANSI color support
- **Multiple Themes** — System, Xterm, VGA Dark, Terminal.app, Pale
- **Terminal Bell** — Choose between sound, visual flash, or disabled
- **Context Actions** — Select text or capture last output to send to chat
- **Code Execution** — Run shell commands directly from chat code blocks
- **Favorite Commands** — Quick-access toolbar with AI-generated emoji icons
- **File Tree Toggle** — Show/hide the file explorer with Cmd+B

### Agent Mode
When enabled, the AI can autonomously execute commands and use tools to complete complex tasks.

#### Agent Modes
Four levels of agent autonomy to match your workflow:

| Mode | Icon | Description | Capabilities |
|------|------|-------------|--------------|
| **Scout** | 🔭 | Read-only exploration | Read files, search, browse directories, HTTP requests |
| **Navigator** | 🗺️ | Create implementation plans | All Scout tools + create_plan for planning |
| **Copilot** | ✈️ | File operations, no shell | All Scout tools + write/edit files, plan & track |
| **Pilot** | 🛫 | Full autonomous agent | All tools including shell execution |

#### Navigator Mode
A specialized planning mode that helps you chart the course before implementation:

- **Exploration First** — Reads files and explores the codebase to understand context
- **Clarifying Questions** — Asks questions to confirm requirements before planning
- **Structured Plans** — Creates implementation plans with phases and a flat checklist
- **Handoff to Build Mode** — After creating a plan, offers to switch to Copilot or Pilot to implement it
- **Plan Persistence** — Plans are saved and can be viewed in the file viewer

#### Agent Profiles
Task-specific behavior profiles that adapt planning, reflection, and execution style:

| Profile | Description |
|---------|-------------|
| **Auto** | Dynamically switches between profiles based on the current task |
| **General** | Balanced general-purpose assistant |
| **Coding** | SOLID principles, clean architecture, testable code |
| **Testing** | TDD, test coverage, edge cases, quality assurance |
| **DevOps** | Rollback-first planning, infrastructure safety |
| **Documentation** | Outline-first, audience awareness, consistency |
| **Product Management** | User stories, acceptance criteria, scope tracking |

#### Agent Features
- **Planning Phase** — Generates a step-by-step plan before execution
- **Periodic Reflection** — Pauses to assess progress and adjust strategy
- **Goal Tracking** — Visual task checklists to monitor progress
- **Built-in Tools** — File operations, shell commands, HTTP requests, process management, memory
- **File Diff Preview** — IDE-style side-by-side diff viewer before applying file changes
- **Per-Hunk Approvals** — Accept or reject individual changes within a file
- **Verification** — Tests and verifies work before declaring completion
- **Safety Controls** — Optional command and file edit approval with auto-approve for read-only commands
- **Stuck Detection** — Automatically detects loops and adjusts strategy
- **Dynamic Context Scaling** — Context limits scale with model size for optimal performance
- **Smart Output Truncation** — Intelligent truncation that preserves errors and important content

#### Inline Approvals
Command and file change approvals now appear inline within the chat conversation, allowing you to:
- Approve or reject directly in context
- View file diffs before accepting changes
- Accept partial changes (individual hunks)
- Continue chatting while awaiting approval

#### System Notifications
When agent approval is needed and the app isn't in focus:
- **macOS Notifications** — Get alerted when the agent needs approval
- **Sound Control** — Enable or disable notification sounds
- **Click to Focus** — Clicking a notification brings TermAI to the foreground

### Terminal Suggestion Agent
An AI-powered command suggestion system that proactively offers relevant commands based on context:

- **Agentic Pipeline** — Multi-phase processing: context gathering, research, planning, and generation
- **Project Detection** — Automatically detects Node, Swift, Rust, Python, Go, Ruby, Java, and .NET projects
- **Smart Triggers** — Suggestions appear on directory changes, after errors, and based on workflow context
- **Shell History Integration** — Learns from your zsh/bash command history
- **Git-Aware** — Contextual suggestions based on repository state and uncommitted changes
- **Error Analysis** — Suggests fixes when commands fail
- **Separate Model Config** — Uses its own LLM settings independent of the main chat

**Suggestion Sources:**
| Icon | Source | Description |
|------|--------|-------------|
| 📁 | Project Context | Commands based on detected project type (npm, cargo, swift, etc.) |
| ⚠️ | Error Analysis | Suggested fixes for failed commands |
| 🌿 | Git Status | Git commands based on repo state |
| 📂 | Directory Change | Common commands for the current directory |
| 💡 | General Context | Contextual suggestions based on workflow |
| ⏱️ | Recent Commands | Commands you've run recently |

### Analytics
- **Token Usage Tracking** — Monitor usage by provider, model, and time range
- **Request Type Breakdown** — Track chat, tool calls, planning, reflection, suggestions, and more
- **Context Window Indicator** — Visual display of context usage percentage
- **30-Day Retention** — Usage data stored in daily files with automatic cleanup
- **Performance Graphs** — Real-time CPU and memory sparklines in the editor tab bar

### Settings
- **Chat & Model** — Per-session provider, model, temperature, and system prompt
- **Providers** — Configure API keys and local provider URLs
- **Agent** — Mode, profile, execution limits, planning, reflection, safety controls
- **Favorites** — Manage model and command favorites
- **Appearance** — App theme (light/dark/system), terminal color schemes, and editor preferences
- **Usage** — Token usage dashboard with charts and breakdowns
- **Data** — Storage location, clear history, factory reset

## Requirements

- **macOS** 13.0+
- **Swift** 5.9+ (only required for building from source)

## Installation

### Download (Recommended)

1. Download the latest `TermAI.dmg` from the [Releases](../../releases) page
2. Open the DMG and drag `TermAI.app` to your Applications folder
3. Launch TermAI from Applications

### Build from Source

#### Build & Run (CLI)
```bash
swift build
swift run TermAI
```

#### Build & Run (Xcode)
1. Open `Package.swift` in Xcode
2. Select the `TermAI` scheme
3. Run (Cmd+R)

#### Packaging a .app Bundle
Use the provided script to create a signed application bundle:
```bash
./build_package.sh
```

Optional environment variables for signing and notarization:
- `DEVELOPER_ID` — e.g., "Developer ID Application: Your Name (TEAMID)"
- `APPLE_ID`, `TEAM_ID`, `APP_PASSWORD` — For notarization

## Configuration

### Cloud Providers (OpenAI, Anthropic, Google)

Set API keys via environment variables:
```bash
export OPENAI_API_KEY="sk-..."
export ANTHROPIC_API_KEY="sk-ant-..."
export GOOGLE_API_KEY="..."
```

Or configure them in **Settings > Providers** to override environment variables.

Available cloud models include:
- **OpenAI** — GPT-5 series, GPT-4.1/4o series, o-series reasoning models
- **Anthropic** — Claude 4.x (Opus, Sonnet, Haiku), Claude 3.7/3.5 series
- **Google** — Gemini 3 Pro, Gemini 2.5 Pro/Flash

### Local Providers (Ollama, LM Studio, vLLM)

1. Start your local LLM server
2. Open **Settings > Providers**
3. Configure the URL (defaults are pre-filled)
4. Click **Test Connection** to verify

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

**Dynamic Context Scaling:** Agent context limits now scale automatically with model size:
- Output capture scales with model context (default 15% per output)
- Agent working memory scales proportionally (default 40% of context)
- Configurable floor and ceiling limits prevent extremes

## Using the App

### File Explorer
Toggle the file tree sidebar with the sidebar button or Cmd+B:
- **Single-click** a file to preview it (shown in italic in the tab bar)
- **Double-click** a file or double-click the tab to pin it permanently
- **Double-click** a folder to navigate the terminal to that directory
- **Right-click** any item for context menu (Reveal in Finder, Copy Path, Open in Terminal)
- Use the **Home** and **Up** buttons to quickly navigate directories
- Directories expand on click; use the refresh button to rescan

The file tree automatically follows the terminal's working directory.

### Editor Tabs
Open files appear as tabs alongside the terminal:
- **Preview tabs** (italic) are replaced when opening another file
- **Pinned tabs** stay open until explicitly closed
- Right-click tabs for context menu options (Close, Close Others, Reveal in Finder)
- Dirty files show an orange dot indicator

### Terminal to Chat
Hover over the terminal to reveal action buttons:
- **Add Selection** — Send highlighted text to chat with metadata
- **Add Last Output** — Send the most recent command output to chat

Context includes the current working directory and line range hints.

### File to Chat
When viewing a file:
- **Add File** — Send the entire file content to chat
- **Add Selection** — Select lines and send just those with line numbers (e.g., "L12-45")

Line ranges are preserved so the agent knows exactly which code you're referencing.

### Chat to Terminal
Code blocks labeled as shell (`bash`, `sh`, `zsh`) show quick actions:
- **Add to Terminal** — Insert command(s) into the terminal
- **Run in Terminal** — Insert and execute immediately

### Agent Mode

Toggle agent mode with the mode selector in the chat header. Choose your mode:

1. **Scout** — Explore and understand the codebase without making changes
2. **Navigator** — Create implementation plans that guide Copilot or Pilot
3. **Copilot** — Read and write files, but no shell command execution
4. **Pilot** — Full autonomous agent with shell access

When enabled:

1. Describe your goal in natural language
2. The agent plans the approach (profile-specific planning)
3. Commands execute automatically with output captured
4. The agent iterates until the goal is complete

**Available Tools:**

| Tool | Description | Modes |
|------|-------------|-------|
| `read_file` | Read file contents with optional line range | Scout+ |
| `list_dir` | List directory contents | Scout+ |
| `search_files` | Find files by name pattern | Scout+ |
| `search_output` | Search through previous command outputs | Scout+ |
| `check_process` | Check if a process is running | Scout+ |
| `http_request` | Make HTTP requests to test APIs | Scout+ |
| `memory` | Save and recall notes during execution | Scout+ |
| `create_plan` | Create implementation plans with checklists | Navigator |
| `write_file` | Write or append content to files | Copilot+ |
| `edit_file` | Search and replace text in files | Copilot+ |
| `insert_lines` | Insert lines at a specific position | Copilot+ |
| `delete_lines` | Delete a range of lines | Copilot+ |
| `delete_file` | Delete a file (always requires approval) | Copilot+ |
| `plan_and_track` | Set goals and manage task checklists | Copilot+ |
| `shell` | Execute commands in the terminal | Pilot |
| `run_background` | Start background processes (e.g., servers) | Pilot |
| `stop_process` | Stop a background process | Pilot |

### Agent Settings

Configure agent behavior in **Settings > Agent**:

- **Default Mode** — Scout, Navigator, Copilot, or Pilot for new sessions
- **Default Profile** — Auto, General, Coding, Testing, DevOps, Documentation, or PM
- **Execution Limits** — Max steps, fix attempts, command timeout
- **Planning & Reflection** — Enable/disable planning phase, reflection interval
- **Context & Memory** — Dynamic scaling percentages, floor/ceiling limits
- **Long Output Handling** — Automatic smart truncation of verbose outputs
- **Safety** — Require command approval, auto-approve read-only, require file edit approval
- **Notifications** — System notifications when approval is needed
- **Verbose Logging** — Debug output for troubleshooting

### Suggestion Agent Settings

Configure the terminal suggestion agent in **Settings > Chat & Model** (per-session) or via global settings:

- **Provider & Model** — Choose a separate LLM for suggestions (can differ from chat)
- **Enable/Disable** — Toggle suggestion agent on or off
- **Shell History** — Include entries from your shell history file

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
| Toggle Suggestions | Ctrl+Space |
| Dismiss Suggestions | Esc |
| Toggle File Tree | Cmd+B |
| Save File | Cmd+S |
| Find in File | Cmd+F |
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
- Implementation plans (Navigator mode)
- Recent projects list
- Token usage records (daily files, 30-day retention)
- Favorite commands

Logs are stored in:
```
~/Library/Caches/TermAI/Logs/
```

## Theming

### App Appearance
Configure in **Settings > Appearance**:
- **System** — Follows macOS light/dark mode
- **Light** — Always use light mode
- **Dark** — Always use dark mode

### Terminal Theme
Choose a color scheme for your terminal:
- **System** — Follows macOS appearance
- **Xterm** — Classic xterm colors
- **VGA Dark** — VGA palette on black
- **Terminal.app** — Matches macOS Terminal
- **Pale** — GNOME-style muted colors

Each theme includes a live preview and color palette display.

### Terminal Bell
Choose how the terminal bell behaves:
- **Sound** — Play system alert sound
- **Visual** — Flash the terminal window
- **Off** — Disable terminal bell

## Troubleshooting

| Issue | Solution |
|-------|----------|
| 401/403 errors | Verify API key and base URL in Settings > Providers |
| No models found (local) | Ensure the server is running; click Test Connection |
| Streaming doesn't start | Check network access and provider compatibility |
| Agent stuck in loop | Increase stuck detection threshold or reduce max iterations |
| Context limit warnings | Switch to a model with larger context or clear chat history |
| Approval notifications not showing | Grant notification permission in System Preferences |
| File tree not updating | Click the refresh button or cd to trigger an update |
| Syntax highlighting missing | Check that the file has a recognized extension |

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
