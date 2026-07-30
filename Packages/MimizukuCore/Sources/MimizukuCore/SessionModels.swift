import Foundation

public enum SessionSchema {
    /// version 0はS5実装前の開発用最小形として読み取り移行だけをサポートする。新規保存は常にversion 1。
    public static let currentMetaVersion = 1
    public static let currentTranscriptVersion = 1
    public static let currentJournalVersion = 1
}

public struct SessionTrack: Sendable, Codable, Equatable, Identifiable {
    public enum Origin: String, Sendable, Codable, Equatable {
        case microphone
        case systemAudio
        case importedAudio
    }

    public var id: UUID
    public var origin: Origin
    public var label: String
    public var relativeAudioPath: String
    public var startOffset: TimeInterval

    public init(
        id: UUID = UUID(),
        origin: Origin,
        label: String,
        relativeAudioPath: String,
        startOffset: TimeInterval = 0
    ) {
        self.id = id
        self.origin = origin
        self.label = label
        self.relativeAudioPath = relativeAudioPath
        self.startOffset = startOffset
    }
}

public struct SessionInput: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable, Equatable {
        case liveRecording
        case imported
    }

    public var kind: Kind
    public var importedMedia: ImportedMediaProvenance?

    public init(kind: Kind, importedMedia: ImportedMediaProvenance? = nil) {
        self.kind = kind
        self.importedMedia = importedMedia
    }

    public static let liveRecording = SessionInput(kind: .liveRecording)

    public static func imported(_ provenance: ImportedMediaProvenance) -> SessionInput {
        SessionInput(kind: .imported, importedMedia: provenance)
    }
}

public struct ImportedMediaProvenance: Sendable, Codable, Equatable {
    public enum MediaKind: String, Sendable, Codable, Equatable {
        case audio
        case video
    }

    public var displayName: String
    public var mediaKind: MediaKind
    public var originalDuration: TimeInterval?

    public init(displayName: String, mediaKind: MediaKind, originalDuration: TimeInterval? = nil) {
        self.displayName = displayName
        self.mediaKind = mediaKind
        self.originalDuration = originalDuration
    }
}

public enum SessionStatus: String, Sendable, Codable, Equatable {
    case recording
    case completed
    case interrupted
    case recoveryNeeded
}

public struct SessionMetadata: Sendable, Codable, Equatable, Identifiable {
    public var schemaVersion: Int
    public var id: UUID
    public var revision: Int
    public var title: String
    public var startedAt: Date
    public var duration: TimeInterval
    public var tags: [String]
    public var status: SessionStatus
    public var input: SessionInput
    public var tracks: [SessionTrack]

    public init(
        schemaVersion: Int = SessionSchema.currentMetaVersion,
        id: UUID = UUID(),
        revision: Int = 1,
        title: String,
        startedAt: Date,
        duration: TimeInterval = 0,
        tags: [String] = [],
        status: SessionStatus = .recording,
        input: SessionInput = .liveRecording,
        tracks: [SessionTrack]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.revision = revision
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.tags = tags
        self.status = status
        self.input = input
        self.tracks = tracks
    }
}

public struct TranscriptBlock: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var trackID: UUID
    public var text: String
    public var start: TimeInterval?
    public var end: TimeInterval?
    public var isComplete: Bool

    public init(
        id: UUID = UUID(),
        trackID: UUID,
        text: String,
        start: TimeInterval?,
        end: TimeInterval?,
        isComplete: Bool
    ) {
        self.id = id
        self.trackID = trackID
        self.text = text
        self.start = start
        self.end = end
        self.isComplete = isComplete
    }
}

public enum TranscriptEditState: String, Sendable, Codable, Equatable {
    case generated
    case userEdited
}

public struct TranscriptDocument: Sendable, Codable, Equatable {
    public var schemaVersion: Int
    public var sessionID: UUID
    public var revision: Int
    public var sourceRunID: UUID
    public var appliedSequence: UInt64
    public var editState: TranscriptEditState
    public var blocks: [TranscriptBlock]

    public init(
        schemaVersion: Int = SessionSchema.currentTranscriptVersion,
        sessionID: UUID,
        revision: Int = 1,
        sourceRunID: UUID,
        appliedSequence: UInt64,
        editState: TranscriptEditState = .generated,
        blocks: [TranscriptBlock]
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.revision = revision
        self.sourceRunID = sourceRunID
        self.appliedSequence = appliedSequence
        self.editState = editState
        self.blocks = blocks
    }
}

public struct TranscriptJournalEntry: Sendable, Codable, Equatable {
    public var schemaVersion: Int
    public var sessionID: UUID
    public var runID: UUID
    public var sequence: UInt64
    public var sourceSegmentID: UUID
    public var trackID: UUID
    public var text: String
    public var start: TimeInterval?
    public var end: TimeInterval?
    public var isComplete: Bool

    public init(
        schemaVersion: Int = SessionSchema.currentJournalVersion,
        sessionID: UUID,
        runID: UUID,
        sequence: UInt64,
        sourceSegmentID: UUID,
        trackID: UUID,
        text: String,
        start: TimeInterval?,
        end: TimeInterval?,
        isComplete: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.runID = runID
        self.sequence = sequence
        self.sourceSegmentID = sourceSegmentID
        self.trackID = trackID
        self.text = text
        self.start = start
        self.end = end
        self.isComplete = isComplete
    }
}
