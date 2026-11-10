import Foundation

/// Opaque backend-namespaced identifiers. Persist and reuse them; never derive IDs from row positions or text.
/// Pi adapters should map durable IDs deterministically (e.g. "pi:conversation:1", "pi:entry:42:0").
public struct StableID<Tag>: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ConversationIDTag: Sendable {}
public enum MessageIDTag: Sendable {}
public typealias ConversationID = StableID<ConversationIDTag>
public typealias MessageID = StableID<MessageIDTag>
