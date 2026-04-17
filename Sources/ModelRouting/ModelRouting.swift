import Foundation

public enum ModelTask: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case streamingDictation
    case longSessionTranscription
    case meetingTranscription
    case formatting
    case commands
    case meetingSummary

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .streamingDictation:
            "Quick Dictation"
        case .longSessionTranscription:
            "Long Session"
        case .meetingTranscription:
            "Meeting Transcription"
        case .formatting:
            "Formatting"
        case .commands:
            "Voice Commands"
        case .meetingSummary:
            "Meeting Summary"
        }
    }
}

public enum LatencyTier: Int, CaseIterable, Codable, Comparable, Sendable {
    case realtime
    case low
    case medium
    case high

    public static func < (lhs: LatencyTier, rhs: LatencyTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .realtime:
            "Realtime"
        case .low:
            "Low"
        case .medium:
            "Medium"
        case .high:
            "High"
        }
    }
}

public enum MemoryFootprint: Int, CaseIterable, Codable, Comparable, Sendable {
    case small
    case medium
    case large

    public static func < (lhs: MemoryFootprint, rhs: MemoryFootprint) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .small:
            "Small"
        case .medium:
            "Medium"
        case .large:
            "Large"
        }
    }
}

public struct LocalModel: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let family: String
    public let supportedTasks: Set<ModelTask>
    public let supportsStreaming: Bool
    public let qualityTier: Int
    public let latencyTier: LatencyTier
    public let memoryFootprint: MemoryFootprint
    public let languageSupport: [String]
    public let preferredChunkSeconds: TimeInterval?
    public let quantization: String
    public let localPathHint: String

    public init(
        id: String,
        displayName: String,
        family: String,
        supportedTasks: Set<ModelTask>,
        supportsStreaming: Bool,
        qualityTier: Int,
        latencyTier: LatencyTier,
        memoryFootprint: MemoryFootprint,
        languageSupport: [String],
        preferredChunkSeconds: TimeInterval?,
        quantization: String,
        localPathHint: String
    ) {
        self.id = id
        self.displayName = displayName
        self.family = family
        self.supportedTasks = supportedTasks
        self.supportsStreaming = supportsStreaming
        self.qualityTier = qualityTier
        self.latencyTier = latencyTier
        self.memoryFootprint = memoryFootprint
        self.languageSupport = languageSupport
        self.preferredChunkSeconds = preferredChunkSeconds
        self.quantization = quantization
        self.localPathHint = localPathHint
    }

    public func supports(_ task: ModelTask) -> Bool {
        supportedTasks.contains(task)
    }
}

public struct ModelBenchmark: Hashable, Codable, Sendable {
    public let modelID: String
    public let measuredOn: Date
    public let tokensPerSecond: Double?
    public let realtimeFactor: Double?
    public let peakMemoryGB: Double?

    public init(
        modelID: String,
        measuredOn: Date,
        tokensPerSecond: Double?,
        realtimeFactor: Double?,
        peakMemoryGB: Double?
    ) {
        self.modelID = modelID
        self.measuredOn = measuredOn
        self.tokensPerSecond = tokensPerSecond
        self.realtimeFactor = realtimeFactor
        self.peakMemoryGB = peakMemoryGB
    }
}

public struct ModelPreferences: Hashable, Codable, Sendable {
    public var useAutomaticRouting: Bool
    public var pinnedModelIDs: [ModelTask: String]

    public init(
        useAutomaticRouting: Bool = true,
        pinnedModelIDs: [ModelTask: String] = [:]
    ) {
        self.useAutomaticRouting = useAutomaticRouting
        self.pinnedModelIDs = pinnedModelIDs
    }

    public func pinnedModelID(for task: ModelTask) -> String? {
        pinnedModelIDs[task]
    }

    public mutating func setPinnedModelID(_ modelID: String?, for task: ModelTask) {
        pinnedModelIDs[task] = modelID
    }
}

public protocol ModelRegistryProtocol {
    var installedModels: [LocalModel] { get }
    var benchmarksByModelID: [String: ModelBenchmark] { get }

    func model(id: String) -> LocalModel?
    func models(supporting task: ModelTask) -> [LocalModel]
}

public final class InMemoryModelRegistry: ModelRegistryProtocol, @unchecked Sendable {
    public private(set) var installedModels: [LocalModel]
    public private(set) var benchmarksByModelID: [String: ModelBenchmark]

    public init(
        installedModels: [LocalModel],
        benchmarksByModelID: [String: ModelBenchmark] = [:]
    ) {
        self.installedModels = installedModels
        self.benchmarksByModelID = benchmarksByModelID
    }

    public func model(id: String) -> LocalModel? {
        installedModels.first(where: { $0.id == id })
    }

    public func models(supporting task: ModelTask) -> [LocalModel] {
        installedModels.filter { $0.supports(task) }
    }
}

public final class DefaultModelRouter: @unchecked Sendable {
    private let registry: any ModelRegistryProtocol

    public init(registry: any ModelRegistryProtocol) {
        self.registry = registry
    }

    public func recommendedModel(
        for task: ModelTask,
        preferences: ModelPreferences = .init()
    ) -> LocalModel? {
        if let pinnedID = preferences.pinnedModelID(for: task),
           let pinnedModel = registry.model(id: pinnedID),
           pinnedModel.supports(task) {
            return pinnedModel
        }

        let candidates = registry.models(supporting: task)
        guard !candidates.isEmpty else { return nil }

        if !preferences.useAutomaticRouting {
            return candidates.sorted(by: manualFallbackSort).first
        }

        return candidates
            .sorted { lhs, rhs in
                scored(lhs, for: task) > scored(rhs, for: task)
            }
            .first
    }

    public func availableModels(for task: ModelTask) -> [LocalModel] {
        registry.models(supporting: task)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func manualFallbackSort(lhs: LocalModel, rhs: LocalModel) -> Bool {
        if lhs.qualityTier != rhs.qualityTier {
            return lhs.qualityTier > rhs.qualityTier
        }

        if lhs.latencyTier != rhs.latencyTier {
            return lhs.latencyTier < rhs.latencyTier
        }

        return lhs.displayName < rhs.displayName
    }

    private func scored(_ model: LocalModel, for task: ModelTask) -> Int {
        let benchmark = registry.benchmarksByModelID[model.id]
        let realtimeBonus = Int((benchmark?.realtimeFactor ?? 0) * 100)
        let tpsBonus = Int((benchmark?.tokensPerSecond ?? 0) * 2)
        let qualityBonus = model.qualityTier * 100
        let memoryPenalty = model.memoryFootprint.rawValue * 15
        let latencyPenalty = model.latencyTier.rawValue * 20

        switch task {
        case .streamingDictation:
            let streamingBonus = model.supportsStreaming ? 150 : 0
            return streamingBonus + qualityBonus + realtimeBonus - latencyPenalty - memoryPenalty
        case .longSessionTranscription, .meetingTranscription:
            let streamingBonus = model.supportsStreaming ? 100 : 0
            let stabilityBonus = model.memoryFootprint == .small ? 40 : (model.memoryFootprint == .medium ? 20 : 0)
            return streamingBonus + qualityBonus + realtimeBonus + stabilityBonus - latencyPenalty
        case .formatting, .commands:
            let gemmaBonus = model.family.localizedCaseInsensitiveContains("gemma") ? 60 : 0
            return qualityBonus + gemmaBonus + tpsBonus - latencyPenalty
        case .meetingSummary:
            let gemmaBonus = model.family.localizedCaseInsensitiveContains("gemma") ? 80 : 0
            return qualityBonus + gemmaBonus + tpsBonus - latencyPenalty - memoryPenalty / 2
        }
    }
}

public enum DefaultModelCatalog {
    public static func seededRegistry() -> InMemoryModelRegistry {
        let models = [
            LocalModel(
                id: "whisper-small-en",
                displayName: "Whisper Small EN (WhisperKit)",
                family: "ASR",
                supportedTasks: [.streamingDictation, .longSessionTranscription, .meetingTranscription],
                supportsStreaming: false,
                qualityTier: 4,
                latencyTier: .low,
                memoryFootprint: .medium,
                languageSupport: ["en"],
                preferredChunkSeconds: 30,
                quantization: "small.en Core ML",
                localPathHint: "~/Library/Application Support/MyOwnVoice/Models/WhisperKit"
            ),
            LocalModel(
                id: "ollama-gemma4",
                displayName: "Gemma 4 (Ollama)",
                family: "Gemma 4",
                supportedTasks: [.formatting, .commands, .meetingSummary],
                supportsStreaming: false,
                qualityTier: 4,
                latencyTier: .medium,
                memoryFootprint: .medium,
                languageSupport: ["en"],
                preferredChunkSeconds: nil,
                quantization: "q4_k_m",
                localPathHint: "Ollama local tag: gemma4"
            ),
        ]

        let benchmarks = [
            "whisper-small-en": ModelBenchmark(
                modelID: "whisper-small-en",
                measuredOn: .now,
                tokensPerSecond: nil,
                realtimeFactor: 1.1,
                peakMemoryGB: 2.4
            ),
            "ollama-gemma4": ModelBenchmark(
                modelID: "ollama-gemma4",
                measuredOn: .now,
                tokensPerSecond: 36,
                realtimeFactor: nil,
                peakMemoryGB: 5.4
            ),
        ]

        return InMemoryModelRegistry(
            installedModels: models,
            benchmarksByModelID: benchmarks
        )
    }
}
