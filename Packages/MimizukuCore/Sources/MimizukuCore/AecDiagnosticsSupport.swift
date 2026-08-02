import Foundation

// MARK: - meta.json / speech.jsonl

/// 診断試行のメタデータ(meta.json)。writer の close 時に確定する。
public struct AecDiagnosticsMeta: Sendable, Equatable, Codable {
    public var schemaVersion: Int
    /// 試行 ID = 診断ディレクトリ名。
    public var trialID: String
    /// "both" | "micOnly"。
    public var mode: String
    /// 開始時の壁時計(ISO8601)。hostTime との対応が文字起こし突き合わせの補助になる。
    public var startedAt: Date
    /// 開始時のホストタイム(秒)。
    public var startHostTime: Double
    public var sampleRate: Double
    public var frameLength: Int
    /// 診断経路自身に欠損がなかったか。false の試行は CLI が正式数値を出さない。
    public var valid: Bool
    /// invalid の理由(writer overflow / write error / drain 失敗など)。
    public var invalidReasons: [String]
    /// writer バッファ溢れで失ったレコード数。
    public var droppedRecords: Int
    /// CAF 長との整合検査用のフレーム数。
    public var captureFrameCount: Int
    public var renderReceivedFrameCount: Int
    public var renderFedFrameCount: Int
    /// Speech 時刻(セッション原点 ―― runStreams 開始)と各ストリーム解析原点の対応。
    /// mic の値を speech.jsonl の start/end から引くと `Capture.speechTimeSeconds` 軸に
    /// なる(#94 の TranscriptRun が startOffset を加算するため)。旧試行では欠落する。
    public var speechStartOffsets: [String: Double]?

    public init(
        schemaVersion: Int = 1,
        trialID: String,
        mode: String,
        startedAt: Date,
        startHostTime: Double,
        sampleRate: Double = 48000,
        frameLength: Int = 480,
        valid: Bool,
        invalidReasons: [String],
        droppedRecords: Int,
        captureFrameCount: Int,
        renderReceivedFrameCount: Int,
        renderFedFrameCount: Int,
        speechStartOffsets: [String: Double]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.trialID = trialID
        self.mode = mode
        self.startedAt = startedAt
        self.startHostTime = startHostTime
        self.sampleRate = sampleRate
        self.frameLength = frameLength
        self.valid = valid
        self.invalidReasons = invalidReasons
        self.droppedRecords = droppedRecords
        self.captureFrameCount = captureFrameCount
        self.renderReceivedFrameCount = renderReceivedFrameCount
        self.renderFedFrameCount = renderFedFrameCount
        self.speechStartOffsets = speechStartOffsets
    }
}

/// 診断専用の文字起こし写し(speech.jsonl の 1 行)。正式なセッションデータ
/// (ADR-0007)には書かない。
public struct AecSpeechRecord: Sendable, Equatable, Codable {
    public var stream: String
    public var text: String
    public var isFinal: Bool
    /// Speech の audioTimeRange(秒)。マイク側は `Capture.speechTimeSeconds` と同一系。
    /// 時刻範囲を持たないセグメントは nil。
    public var start: Double?
    public var end: Double?

    public init(stream: String, text: String, isFinal: Bool, start: Double?, end: Double?) {
        self.stream = stream
        self.text = text
        self.isFinal = isFinal
        self.start = start
        self.end = end
    }
}

// MARK: - JSONL エンコード / デコード

public enum AecDiagnosticsJSONL {
    /// 1 レコードを 1 行の JSON(キー昇順・改行なし)へエンコードする。
    /// キー昇順は試行間 diff を安定させるための決定性。
    public static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard let line = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(value, EncodingError.Context(
                codingPath: [],
                debugDescription: "UTF-8 へ変換できない JSON 出力"
            ))
        }
        return line
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(line.utf8))
    }
}

// MARK: - RMS / 電力比

public enum AecAudioMetrics {
    /// Int16 フルスケール基準の RMS(dBFS)。完全無音(全サンプル 0)は −∞ を JSON に
    /// 載せられないため nil を返す。
    public static func rmsDBFS(_ samples: [Int16]) -> Double? {
        guard !samples.isEmpty else { return nil }
        var sum = 0.0
        for sample in samples {
            let value = Double(sample)
            sum += value * value
        }
        guard sum > 0 else { return nil }
        let rms = (sum / Double(samples.count)).squareRoot() / 32768.0
        return 20 * log10(rms)
    }

    /// 処理前後の電力比 `10·log10(P_raw / P_processed)`(dB)。
    /// これは ERLE ではない ―― raw に近端発話やノイズが含まれる窓では抑圧量を意味しない
    /// (echo-dominant candidate window に限って解釈する)。
    /// raw が完全無音なら nil。processed のみ完全無音なら +infinity(完全抑圧)。
    public static func powerRatioDB(raw: [Int16], processed: [Int16]) -> Double? {
        guard let rawPower = meanPower(raw) else { return nil }
        guard let processedPower = meanPower(processed) else { return .infinity }
        return 10 * log10(rawPower / processedPower)
    }

    private static func meanPower(_ samples: [Int16]) -> Double? {
        guard !samples.isEmpty else { return nil }
        var sum = 0.0
        for sample in samples {
            let value = Double(sample)
            sum += value * value
        }
        guard sum > 0 else { return nil }
        return sum / Double(samples.count)
    }
}
