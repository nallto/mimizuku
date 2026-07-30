import MimizukuCore

extension StreamKind {
    var trackOrigin: SessionTrack.Origin {
        switch self {
        case .microphone: .microphone
        case .systemAudio: .systemAudio
        }
    }

    var displayLabel: String {
        switch self {
        case .microphone: "自分"
        case .systemAudio: "相手"
        }
    }
}

extension SessionTrack.Origin {
    var streamKind: StreamKind? {
        switch self {
        case .microphone: .microphone
        case .systemAudio: .systemAudio
        case .importedAudio: nil
        }
    }
}
