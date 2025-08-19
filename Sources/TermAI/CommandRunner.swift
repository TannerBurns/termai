import Foundation

final class CommandRunner: ObservableObject {
    @Published private(set) var output: String = ""

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?

    func run(commandLine: String, completion: @escaping () -> Void) {
        append("$ \(commandLine)\n")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", commandLine]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let data = try? handle.readToEndNonBlocking(), let str = String(data: data, encoding: .utf8), !str.isEmpty else { return }
            DispatchQueue.main.async {
                self?.append(str)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let data = try? handle.readToEndNonBlocking(), let str = String(data: data, encoding: .utf8), !str.isEmpty else { return }
            DispatchQueue.main.async {
                self?.append(str)
            }
        }

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.append("\n")
                self?.cleanup()
                completion()
            }
        }

        do {
            try process.run()
            self.process = process
            self.outputPipe = outputPipe
            self.errorPipe = errorPipe
        } catch {
            append("Error: \(error.localizedDescription)\n")
            cleanup()
            completion()
        }
    }

    func cancel() {
        process?.terminate()
        cleanup()
    }

    func clear() {
        output = ""
    }

    private func append(_ text: String) {
        output.append(text)
    }

    private func cleanup() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil
        process = nil
    }
}

private extension FileHandle {
    func readToEndNonBlocking() throws -> Data {
        if #available(macOS 10.15.4, *) {
            return try self.read(upToCount: Int.max) ?? Data()
        } else {
            return self.availableData
        }
    }
}


