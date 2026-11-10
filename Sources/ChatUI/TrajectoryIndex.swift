import ChatCore
import Foundation

/// Source order is authoritative; timestamps never reorder or infer durations.
enum TrajectoryIndex {
    static func matching(_ messages: [ChatMessage], query: String, role: MessageRole?, locale: Locale) -> [Int] {
        messages.indices.filter { index in
            (role == nil || messages[index].role == role) &&
                (query.isEmpty || messages[index].content.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) != nil)
        }
    }
}
