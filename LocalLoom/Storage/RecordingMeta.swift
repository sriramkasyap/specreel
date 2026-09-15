import Foundation

// MARK: - RecordingMeta

/// On-disk `meta.json` model for a single recording folder.
/// Schema matches TRD §1.4 exactly.
public struct RecordingMeta: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var description: String
    public var createdAt: Date
    public var duration: Double
    public var width: Int
    public var height: Int
    public var fps: Int
    public var fileSize: Int64
    public var source: Source
    public var hasWebcam: Bool
    public var hasMic: Bool
    public var hasSystemAudio: Bool

    public struct Source: Codable, Hashable, Sendable {
        public var type: SourceType
        public var app: String?
        public var title: String?

        public init(type: SourceType, app: String? = nil, title: String? = nil) {
            self.type = type
            self.app = app
            self.title = title
        }
    }

    public enum SourceType: String, Codable, Hashable, Sendable, CaseIterable {
        case display
        case window
        case region
    }

    public init(
        id: String,
        title: String,
        description: String = "",
        createdAt: Date = Date(),
        duration: Double,
        width: Int,
        height: Int,
        fps: Int,
        fileSize: Int64,
        source: Source,
        hasWebcam: Bool = false,
        hasMic: Bool = false,
        hasSystemAudio: Bool = false
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.createdAt = createdAt
        self.duration = duration
        self.width = width
        self.height = height
        self.fps = fps
        self.fileSize = fileSize
        self.source = source
        self.hasWebcam = hasWebcam
        self.hasMic = hasMic
        self.hasSystemAudio = hasSystemAudio
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case id, title, description, createdAt, duration
        case width, height, fps, fileSize, source
        case hasWebcam, hasMic, hasSystemAudio
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        createdAt = try Self.decodeDate(from: container, forKey: .createdAt)
        duration = try container.decode(Double.self, forKey: .duration)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        fps = try container.decode(Int.self, forKey: .fps)
        fileSize = try Self.decodeFileSize(from: container)
        source = try container.decode(Source.self, forKey: .source)
        hasWebcam = try container.decodeIfPresent(Bool.self, forKey: .hasWebcam) ?? false
        hasMic = try container.decodeIfPresent(Bool.self, forKey: .hasMic) ?? false
        hasSystemAudio = try container.decodeIfPresent(Bool.self, forKey: .hasSystemAudio) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encode(Self.iso8601String(from: createdAt), forKey: .createdAt)
        try container.encode(duration, forKey: .duration)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(fps, forKey: .fps)
        try container.encode(fileSize, forKey: .fileSize)
        try container.encode(source, forKey: .source)
        try container.encode(hasWebcam, forKey: .hasWebcam)
        try container.encode(hasMic, forKey: .hasMic)
        try container.encode(hasSystemAudio, forKey: .hasSystemAudio)
    }

    private static func decodeDate(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> Date {
        if let string = try? container.decode(String.self, forKey: key) {
            if let date = iso8601Date(from: string) { return date }
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Invalid ISO8601 date string: \(string)"
            )
        }
        // Accept numeric timestamps as a recovery path for partial/hand-edited JSON.
        if let interval = try? container.decode(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: interval)
        }
        throw DecodingError.keyNotFound(key, .init(codingPath: container.codingPath, debugDescription: "createdAt missing"))
    }

    private static func decodeFileSize(from container: KeyedDecodingContainer<CodingKeys>) throws -> Int64 {
        if let value = try? container.decode(Int64.self, forKey: .fileSize) {
            return value
        }
        if let value = try? container.decode(Int.self, forKey: .fileSize) {
            return Int64(value)
        }
        if let value = try? container.decode(Double.self, forKey: .fileSize) {
            return Int64(value)
        }
        throw DecodingError.keyNotFound(
            CodingKeys.fileSize,
            .init(codingPath: container.codingPath, debugDescription: "fileSize missing")
        )
    }

    // MARK: - ISO8601

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func iso8601Date(from string: String) -> Date? {
        iso8601Fractional.date(from: string) ?? iso8601Plain.date(from: string)
    }

    public static func iso8601String(from date: Date) -> String {
        iso8601Plain.string(from: date)
    }
}

// MARK: - Validation

public extension RecordingMeta {
    enum ValidationError: Error, LocalizedError, Equatable, Sendable {
        case emptyData
        case invalidJSON(String)
        case missingField(String)
        case invalidField(String, detail: String)
        case partialJSON(missing: [String])

        public var errorDescription: String? {
            switch self {
            case .emptyData:
                return "meta.json is empty"
            case .invalidJSON(let detail):
                return "meta.json is not valid JSON: \(detail)"
            case .missingField(let name):
                return "meta.json missing required field: \(name)"
            case .invalidField(let name, let detail):
                return "meta.json field '\(name)' is invalid: \(detail)"
            case .partialJSON(let missing):
                return "meta.json is partial; missing: \(missing.joined(separator: ", "))"
            }
        }
    }

    /// Required top-level keys per TRD §1.4.
    static let requiredKeys: [String] = [
        "id", "title", "description", "createdAt", "duration",
        "width", "height", "fps", "fileSize", "source",
        "hasWebcam", "hasMic", "hasSystemAudio",
    ]

    /// Decode and validate from raw `meta.json` data.
    static func decode(from data: Data) throws -> RecordingMeta {
        guard !data.isEmpty else { throw ValidationError.emptyData }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ValidationError.invalidJSON(error.localizedDescription)
        }

        guard let dict = object as? [String: Any] else {
            throw ValidationError.invalidJSON("Root value must be an object")
        }

        try validateDictionary(dict)

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(RecordingMeta.self, from: data)
        } catch let error as DecodingError {
            throw mapDecodingError(error)
        } catch {
            throw ValidationError.invalidJSON(error.localizedDescription)
        }
    }

    /// Decode from a file URL.
    static func load(from url: URL) throws -> RecordingMeta {
        let data = try Data(contentsOf: url)
        return try decode(from: data)
    }

    /// Encode to pretty-printed JSON data with ISO8601 dates as strings.
    func encodeData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return try encoder.encode(self)
    }

    /// Structural checks on a parsed dictionary before Codable decode —
    /// surfaces malformed / partial JSON with field-level diagnostics.
    static func validateDictionary(_ dict: [String: Any]) throws {
        var missing: [String] = []
        for key in requiredKeys {
            if dict[key] == nil { missing.append(key) }
        }
        if !missing.isEmpty {
            if missing.count == requiredKeys.count {
                throw ValidationError.partialJSON(missing: missing)
            }
            // Treat any missing required key as partial.
            throw ValidationError.partialJSON(missing: missing)
        }

        if let id = dict["id"] as? String {
            if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError.invalidField("id", detail: "must be non-empty")
            }
        } else {
            throw ValidationError.invalidField("id", detail: "must be a string")
        }

        guard dict["title"] is String else {
            throw ValidationError.invalidField("title", detail: "must be a string")
        }
        guard dict["description"] is String else {
            throw ValidationError.invalidField("description", detail: "must be a string")
        }

        if let createdAt = dict["createdAt"] as? String {
            if iso8601Date(from: createdAt) == nil {
                throw ValidationError.invalidField("createdAt", detail: "not a valid ISO8601 date")
            }
        } else if dict["createdAt"] is NSNumber {
            // numeric epoch accepted by decoder recovery path
        } else {
            throw ValidationError.invalidField("createdAt", detail: "must be an ISO8601 string")
        }

        for key in ["duration", "width", "height", "fps", "fileSize"] {
            guard dict[key] is NSNumber else {
                throw ValidationError.invalidField(key, detail: "must be a number")
            }
        }

        guard let source = dict["source"] as? [String: Any] else {
            throw ValidationError.invalidField("source", detail: "must be an object")
        }
        guard let type = source["type"] as? String else {
            throw ValidationError.invalidField("source.type", detail: "must be a string")
        }
        let allowed = Set(SourceType.allCases.map(\.rawValue))
        guard allowed.contains(type) else {
            throw ValidationError.invalidField(
                "source.type",
                detail: "must be one of \(allowed.sorted().joined(separator: "|"))"
            )
        }
        if let app = source["app"], !(app is String) && !(app is NSNull) {
            throw ValidationError.invalidField("source.app", detail: "must be a string or null")
        }
        if let title = source["title"], !(title is String) && !(title is NSNull) {
            throw ValidationError.invalidField("source.title", detail: "must be a string or null")
        }

        for key in ["hasWebcam", "hasMic", "hasSystemAudio"] {
            guard dict[key] is Bool else {
                throw ValidationError.invalidField(key, detail: "must be a boolean")
            }
        }
    }

    /// Returns `nil` for well-formed meta; otherwise a validation error.
    static func validationError(in data: Data) -> ValidationError? {
        do {
            _ = try decode(from: data)
            return nil
        } catch let error as ValidationError {
            return error
        } catch {
            return .invalidJSON(error.localizedDescription)
        }
    }

    private static func mapDecodingError(_ error: DecodingError) -> ValidationError {
        switch error {
        case .keyNotFound(let key, _):
            return .missingField(key.stringValue)
        case .typeMismatch(_, let ctx):
            let name = ctx.codingPath.last?.stringValue ?? "unknown"
            return .invalidField(name, detail: ctx.debugDescription)
        case .valueNotFound(_, let ctx):
            let name = ctx.codingPath.last?.stringValue ?? "unknown"
            return .missingField(name)
        case .dataCorrupted(let ctx):
            let name = ctx.codingPath.last?.stringValue ?? "unknown"
            return .invalidField(name, detail: ctx.debugDescription)
        @unknown default:
            return .invalidJSON(String(describing: error))
        }
    }
}
