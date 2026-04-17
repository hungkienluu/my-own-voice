import AppKit
import Foundation

public struct OllamaRuntimeDiagnostics: Sendable {
    public let appInstalled: Bool
    public let cliAvailable: Bool
    public let serverReachable: Bool
    public let installedModels: [String]
    public let missingRequiredModels: [String]

    public init(
        appInstalled: Bool,
        cliAvailable: Bool,
        serverReachable: Bool,
        installedModels: [String],
        missingRequiredModels: [String]
    ) {
        self.appInstalled = appInstalled
        self.cliAvailable = cliAvailable
        self.serverReachable = serverReachable
        self.installedModels = installedModels
        self.missingRequiredModels = missingRequiredModels
    }

    public var isReady: Bool {
        serverReachable && missingRequiredModels.isEmpty
    }
}

public actor OllamaRuntimeSetupService {
    private let ollamaService: OllamaService
    private let fileManager: FileManager
    private var launchedServeProcess: Process?

    public init(
        ollamaService: OllamaService,
        fileManager: FileManager = .default
    ) {
        self.ollamaService = ollamaService
        self.fileManager = fileManager
    }

    public func inspect(requiredModels: [String]) async -> OllamaRuntimeDiagnostics {
        let appInstalled = ollamaAppURL() != nil
        let cliAvailable = ollamaCLIURL() != nil

        do {
            let installedModels = try await ollamaService.installedModelNames()
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            let missingModels = requiredModels.filter { requiredModel in
                !installedModels.contains(where: { installedModel in
                    installedModel == requiredModel || installedModel.hasPrefix("\(requiredModel):")
                })
            }

            return OllamaRuntimeDiagnostics(
                appInstalled: appInstalled,
                cliAvailable: cliAvailable,
                serverReachable: true,
                installedModels: installedModels,
                missingRequiredModels: missingModels
            )
        } catch {
            return OllamaRuntimeDiagnostics(
                appInstalled: appInstalled,
                cliAvailable: cliAvailable,
                serverReachable: false,
                installedModels: [],
                missingRequiredModels: requiredModels
            )
        }
    }

    public func prepareRuntime(
        requiredModels: [String],
        progress: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws -> OllamaRuntimeDiagnostics {
        await publish("Checking Ollama...", using: progress)
        var diagnostics = await inspect(requiredModels: requiredModels)

        if !diagnostics.serverReachable {
            let launched = try await launchRuntimeIfPossible(progress: progress)

            if !launched {
                await openDownloadPage()
                await publish(
                    "Ollama is not installed yet. The official download page is open. Install it, then run setup again.",
                    using: progress
                )
                return await inspect(requiredModels: requiredModels)
            }

            await publish("Starting Ollama locally...", using: progress)
            diagnostics = await waitForRuntime(requiredModels: requiredModels)
        }

        if diagnostics.serverReachable && !diagnostics.missingRequiredModels.isEmpty {
            for model in diagnostics.missingRequiredModels {
                await publish("Installing local model \(model)...", using: progress)
                try await ollamaService.pull(model: model)
            }

            diagnostics = await inspect(requiredModels: requiredModels)
        }

        if diagnostics.isReady {
            await publish("Ollama is ready and the required models are installed.", using: progress)
        }

        return diagnostics
    }

    private func launchRuntimeIfPossible(
        progress: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> Bool {
        if let appURL = ollamaAppURL() {
            await publish("Opening the installed Ollama app...", using: progress)
            _ = await MainActor.run {
                NSWorkspace.shared.open(appURL)
            }
            return true
        }

        if let cliURL = ollamaCLIURL() {
            await publish("Starting Ollama from the CLI install...", using: progress)
            try startServeProcess(using: cliURL)
            return true
        }

        return false
    }

    private func startServeProcess(using cliURL: URL) throws {
        if let launchedServeProcess, launchedServeProcess.isRunning {
            return
        }

        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        launchedServeProcess = process
    }

    private func waitForRuntime(requiredModels: [String]) async -> OllamaRuntimeDiagnostics {
        for _ in 0..<25 {
            let diagnostics = await inspect(requiredModels: requiredModels)
            if diagnostics.serverReachable {
                return diagnostics
            }

            try? await Task.sleep(for: .seconds(1))
        }

        return await inspect(requiredModels: requiredModels)
    }

    private func publish(
        _ message: String,
        using progress: (@MainActor @Sendable (String) -> Void)?
    ) async {
        guard let progress else { return }
        await progress(message)
    }

    private func openDownloadPage() async {
        guard let url = URL(string: "https://ollama.com/download") else { return }

        _ = await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }

    private func ollamaAppURL() -> URL? {
        let directPath = "/Applications/Ollama.app"

        if fileManager.fileExists(atPath: directPath) {
            return URL(fileURLWithPath: directPath)
        }

        return nil
    }

    private func ollamaCLIURL() -> URL? {
        let appCLI = ollamaAppURL()?
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("ollama", isDirectory: false)

        let candidates = [
            "/usr/local/bin/ollama",
            "/opt/homebrew/bin/ollama",
            appCLI?.path
        ].compactMap { $0 }

        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }
}
