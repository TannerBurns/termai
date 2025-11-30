import Foundation

struct SystemInfo {
    let osName: String
    let osVersion: String
    let linuxDistro: String
    let arch: String
    let shell: String
    let packageManagers: [String]
    let containerType: String
    let isRootless: Bool
    let privileges: String
    let gpuPresent: Bool
    let cudaVersion: String
    let pythonVersion: String
    
    static func gather() -> SystemInfo {
        let osName = getOSName()
        let osVersion = getOSVersion()
        let linuxDistro = getLinuxDistro()
        let arch = getArchitecture()
        let shell = getShell()
        let packageManagers = getPackageManagers()
        let containerType = getContainerType()
        let isRootless = checkRootless()
        let privileges = getPrivileges()
        let gpuPresent = checkGPU()
        let cudaVersion = getCUDAVersion()
        let pythonVersion = getPythonVersion()
        
        return SystemInfo(
            osName: osName,
            osVersion: osVersion,
            linuxDistro: linuxDistro,
            arch: arch,
            shell: shell,
            packageManagers: packageManagers,
            containerType: containerType,
            isRootless: isRootless,
            privileges: privileges,
            gpuPresent: gpuPresent,
            cudaVersion: cudaVersion,
            pythonVersion: pythonVersion
        )
    }
    
    private static func getOSName() -> String {
        #if os(macOS)
        return "macOS"
        #elseif os(Linux)
        return "Linux"
        #elseif os(Windows)
        return "Windows"
        #else
        return "Unknown"
        #endif
    }
    
    private static func getOSVersion() -> String {
        let process = ProcessInfo.processInfo
        let version = process.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
    
    private static func getLinuxDistro() -> String {
        #if os(Linux)
        // Try to read /etc/os-release
        if let content = try? String(contentsOfFile: "/etc/os-release") {
            let lines = content.split(separator: "\n")
            for line in lines {
                if line.starts(with: "ID=") {
                    return String(line.dropFirst(3).replacingOccurrences(of: "\"", with: ""))
                }
            }
        }
        return "Unknown"
        #else
        return ""
        #endif
    }
    
    private static func getArchitecture() -> String {
        #if arch(x86_64)
        return "x86_64"
        #elseif arch(arm64)
        return "arm64"
        #elseif arch(i386)
        return "i386"
        #else
        return "Unknown"
        #endif
    }
    
    private static func getShell() -> String {
        if let shellEnv = ProcessInfo.processInfo.environment["SHELL"] {
            return URL(fileURLWithPath: shellEnv).lastPathComponent
        }
        return "Unknown"
    }
    
    private static func getPackageManagers() -> [String] {
        var managers: [String] = []
        
        #if os(macOS)
        // Check for Homebrew
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") ||
           FileManager.default.fileExists(atPath: "/usr/local/bin/brew") {
            managers.append("brew")
        }
        // Check for MacPorts
        if FileManager.default.fileExists(atPath: "/opt/local/bin/port") {
            managers.append("port")
        }
        #elseif os(Linux)
        // Check for various Linux package managers
        if FileManager.default.fileExists(atPath: "/usr/bin/apt") ||
           FileManager.default.fileExists(atPath: "/usr/bin/apt-get") {
            managers.append("apt")
        }
        if FileManager.default.fileExists(atPath: "/usr/bin/dnf") {
            managers.append("dnf")
        }
        if FileManager.default.fileExists(atPath: "/usr/bin/yum") {
            managers.append("yum")
        }
        if FileManager.default.fileExists(atPath: "/usr/bin/pacman") {
            managers.append("pacman")
        }
        if FileManager.default.fileExists(atPath: "/usr/bin/zypper") {
            managers.append("zypper")
        }
        if FileManager.default.fileExists(atPath: "/usr/bin/snap") {
            managers.append("snap")
        }
        #endif
        
        return managers
    }
    
    private static func getContainerType() -> String {
        // Check if running in Docker
        if FileManager.default.fileExists(atPath: "/.dockerenv") {
            return "docker"
        }
        
        // Check if running in Kubernetes
        if ProcessInfo.processInfo.environment["KUBERNETES_SERVICE_HOST"] != nil {
            return "kubernetes"
        }
        
        // Check for Podman
        if let cgroupContent = try? String(contentsOfFile: "/proc/1/cgroup"),
           cgroupContent.contains("podman") {
            return "podman"
        }
        
        return "none"
    }
    
    private static func checkRootless() -> Bool {
        // Check if running rootless containers
        if let runtimeEnv = ProcessInfo.processInfo.environment["container"],
           runtimeEnv == "podman" || runtimeEnv == "docker" {
            return getuid() != 0
        }
        return false
    }
    
    private static func getPrivileges() -> String {
        let uid = getuid()
        if uid == 0 {
            return "root"
        }
        
        // Check if user can sudo (simplified check)
        #if os(macOS) || os(Linux)
        let sudoResult = runCommand("/usr/bin/sudo", arguments: ["-n", "true"])
        if sudoResult?.exitCode == 0 {
            return "sudoer"
        }
        #endif
        
        return "user"
    }
    
    private static func checkGPU() -> Bool {
        #if os(macOS)
        // macOS always has GPU (either integrated or discrete)
        return true
        #elseif os(Linux)
        // Check for NVIDIA GPU
        if FileManager.default.fileExists(atPath: "/usr/bin/nvidia-smi") {
            return true
        }
        // Check for AMD GPU
        if FileManager.default.fileExists(atPath: "/usr/bin/rocm-smi") {
            return true
        }
        // Check for Intel GPU
        if FileManager.default.fileExists(atPath: "/sys/class/drm/card0") {
            return true
        }
        return false
        #else
        return false
        #endif
    }
    
    private static func getCUDAVersion() -> String {
        #if os(Linux)
        if let result = runCommand("/usr/bin/nvidia-smi", arguments: []),
           result.exitCode == 0,
           let output = result.output {
            // Parse CUDA version from nvidia-smi output
            let lines = output.split(separator: "\n")
            for line in lines {
                if line.contains("CUDA Version:") {
                    if let range = line.range(of: "CUDA Version: ") {
                        let versionStr = String(line[range.upperBound...])
                        if let spaceIndex = versionStr.firstIndex(of: " ") {
                            return String(versionStr[..<spaceIndex])
                        }
                    }
                }
            }
        }
        #endif
        return ""
    }
    
    private static func getPythonVersion() -> String {
        // Try python3 first, then python
        for pythonCmd in ["python3", "python"] {
            if let result = runCommand("/usr/bin/env", arguments: [pythonCmd, "--version"]),
               result.exitCode == 0,
               let output = result.output {
                // Parse version from "Python X.Y.Z"
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.starts(with: "Python ") {
                    return String(trimmed.dropFirst(7))
                }
            }
        }
        return ""
    }
    
    private static func runCommand(_ path: String, arguments: [String]) -> (output: String?, exitCode: Int32)? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe() // Suppress error output
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)
            
            return (output: output, exitCode: task.terminationStatus)
        } catch {
            return nil
        }
    }
}

extension SystemInfo {
    // Agent mode system prompt addition
    static let agentModePrompt = """
    
    === AGENT MODE INSTRUCTIONS ===
    
    When operating in AGENT MODE, you are an autonomous terminal agent that can execute multi-step tasks.
    
    PLANNING:
    - Always think step-by-step before executing commands
    - Create a numbered checklist of tasks to complete
    - Include a verification step for each major milestone
    - Consider what could go wrong and how to handle it
    
    EXECUTION:
    - Work through the checklist systematically
    - After each command, verify it achieved the intended result
    - Check exit codes and output for errors
    - If a command fails, analyze why before retrying
    - Reference the checklist item number in your responses
    
    VERIFICATION (CRITICAL):
    - After creating files, READ them back to verify content
    - After starting servers, CHECK they are running (check_process tool)
    - For APIs, TEST endpoints using http_request tool
    - Never declare done without verification
    - For web servers: start with run_background, then test with http_request
    
    STAYING ON TRACK:
    - Keep the original goal in mind at all times
    - If you seem to be going in circles, stop and reconsider your approach
    - Try different strategies rather than repeating failed commands
    - Periodically assess: "Am I making progress toward the goal?"
    
    AVAILABLE TOOLS:
    
    FILE OPERATIONS:
    - write_file: Create/overwrite a file (args: path, content, mode)
    - edit_file: Search and replace in file (args: path, old_text, new_text, replace_all)
    - insert_lines: Insert at line number (args: path, line_number, content)
    - delete_lines: Delete line range (args: path, start_line, end_line)
    - read_file: Read file contents (args: path, start_line, end_line)
    - list_dir: List directory (args: path, recursive)
    - search_files: Find files by pattern (args: path, pattern, recursive)
    
    SHELL & PROCESS:
    - command: Execute a shell command
    - run_background: Start server/process in background (args: command, wait_for, timeout)
    - check_process: Check if process is running (args: pid, port, or list=true)
    - stop_process: Stop a background process (args: pid, or all=true)
    
    VERIFICATION & MEMORY:
    - http_request: Test API endpoints (args: url, method, body, headers)
    - search_output: Search previous outputs (args: pattern, context_lines)
    - memory: Store/recall notes (args: action, key, value)
    
    SAFETY:
    - Always consider safety before running destructive commands
    - Prefer reversible actions when possible
    - If unsure, ask for clarification rather than guessing
    
    OUTPUT FORMAT:
    - Include the checklist item number: {"step":"description", "tool":"tool_name", "tool_args":{...}, "checklist_item": 1}
    - For shell commands: {"step":"description", "command":"shell command", "tool":"command", "checklist_item": 1}
    
    EXAMPLE WORKFLOW FOR API CREATION:
    1. Create project structure (mkdir, npm init)
    2. Install dependencies (npm install)
    3. Write source files (write_file)
    4. Read back files to verify (read_file)
    5. Start server in background (run_background with wait_for="listening")
    6. Test endpoints (http_request to verify responses)
    7. Stop server when done (stop_process)
    """
    
    // Hard-coded system prompt template
    static let systemPromptTemplate = """
    You are a helpful and precise terminal assistant.
    
    Guidelines:
    - When given pasted terminal outputs, analyze them and provide guidance.
    - When providing bash or shell commands, do NOT put comments inside the shell code blocks. Put all explanations outside the blocks.
    
    Mission:
    - Provide minimal, correct, and reproducible command-line solutions.
    - Default to least-privilege and idempotent actions.
    
    Environment (auto-injected at runtime — machine-readable):
    ENV:
      os:
        name: {{OS_NAME}}            # e.g., "Ubuntu", "Fedora", "macOS", "Windows"
        version: "{{OS_VERSION}}"    # e.g., "22.04", "14.5", "11"
        distro: "{{LINUX_DISTRO}}"   # e.g., "Ubuntu", "RHEL" ("" for macOS/Windows)
      arch: "{{ARCH}}"               # e.g., "x86_64", "arm64"
      shell: "{{SHELL}}"             # e.g., "bash", "zsh", "pwsh"
      package_managers: [{{PKG_MANAGERS}}]  # e.g., apt, dnf, brew, choco
      container:
        type: "{{CONTAINER_TYPE}}"   # "docker"|"podman"|"kubernetes"|"none"
        rootless: {{IS_ROOTLESS}}    # true|false
      privileges: "{{PRIVILEGES}}"   # "user"|"sudoer"|"root"
    
    Rules for using ENV:
    - Tailor commands to this ENV. Prefer a single platform's commands when ENV is unambiguous.
    - If any key is missing, state a brief assumption and (only if helpful) offer one alternative variant.
    - If the user's message conflicts with ENV (e.g., says "on macOS" but ENV says Ubuntu), ask for confirmation before giving destructive commands.
    
    Command generation rules:
    - Prefer idempotent patterns (e.g., `mkdir -p`, existence checks).
    - Quote variables and paths; use `--` to terminate option parsing.
    - Avoid `sudo` unless required; when used, justify and scope it narrowly.
    - Prefer package managers (apt/dnf/yum/pacman/brew/choco) over `curl | sh`. If a script is unavoidable, include checksum or signature verification.
    - Use placeholders in ALL_CAPS like `<PROJECT_DIR>` and `<PORT>`. Never hardcode secrets or print tokens. For secrets, use `read -s VAR` and store in files with `chmod 600`.
    - Split multi-step tasks into short commands rather than one long pipeline; clarity over cleverness.
    - Provide platform-appropriate variants when needed:
      - Linux (Debian/Ubuntu: apt; RHEL/Fedora: dnf/yum)
      - macOS: Homebrew (+ note BSD vs GNU utility differences)
      - Windows: PowerShell equivalents (pwsh)
    
    Verification & rollback:
    - Provide an undo path when feasible (revert config, uninstall package, stop/disable service, restore backup/tarball).
    
    Safety checklist:
    - Be explicit and require confirmation for destructive operations (`rm -rf`, overwriting `mv`, firewall rules, database migrations).
    
    Formatting rules:
    - Explanations outside code blocks.
    - Separate code blocks per platform/shell when they differ.
    - Use fenced code blocks tagged with the appropriate language (`bash`, `zsh`, `pwsh`).
    
    Long-running/background processes:
    - Show how to run under `tmux`/`screen` or as a service (systemd or launchd), where logs go, and how to stop or inspect.
    
    Security & privacy:
    - Redact sensitive values unless the user explicitly asks to include them.
    - Do not echo tokens or credentials; prefer environment files with correct permissions.
    """
    
    func injectIntoPrompt() -> String {
        var prompt = SystemInfo.systemPromptTemplate
        
        // Replace placeholders with actual values
        prompt = prompt.replacingOccurrences(of: "{{OS_NAME}}", with: osName)
        prompt = prompt.replacingOccurrences(of: "{{OS_VERSION}}", with: osVersion)
        prompt = prompt.replacingOccurrences(of: "{{LINUX_DISTRO}}", with: linuxDistro)
        prompt = prompt.replacingOccurrences(of: "{{ARCH}}", with: arch)
        prompt = prompt.replacingOccurrences(of: "{{SHELL}}", with: shell)
        prompt = prompt.replacingOccurrences(of: "{{PKG_MANAGERS}}", with: packageManagers.joined(separator: ", "))
        prompt = prompt.replacingOccurrences(of: "{{CONTAINER_TYPE}}", with: containerType)
        prompt = prompt.replacingOccurrences(of: "{{IS_ROOTLESS}}", with: String(isRootless))
        prompt = prompt.replacingOccurrences(of: "{{PRIVILEGES}}", with: privileges)
        prompt = prompt.replacingOccurrences(of: "{{GPU_PRESENT}}", with: String(gpuPresent))
        prompt = prompt.replacingOccurrences(of: "{{CUDA_VERSION}}", with: cudaVersion)
        prompt = prompt.replacingOccurrences(of: "{{PYTHON_VERSION}}", with: pythonVersion)
        
        return prompt
    }
    
    /// Get system prompt with agent mode instructions appended
    func injectIntoPromptWithAgentMode() -> String {
        return injectIntoPrompt() + SystemInfo.agentModePrompt
    }
}
