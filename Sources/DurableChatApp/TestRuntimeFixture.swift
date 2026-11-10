import ChatCore
import Foundation

/// Available only via --test-runtime. Real temp SQLite/FauxProvider and a clearly labeled local CLI fixture.
/// No production credential service, sign-in, model call or user storage is used.
enum TestRuntimeFixture {
    private struct Archive: Encodable {
        var version = 1
        var selected: ConversationID?
        var conversations: [ConversationSnapshot]
        var sessions: [String: String] = [:]
        var accepted: [String: String] = [:]
    }
    static func prepareCursor(at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = #"""
        #!/bin/sh
        case "$1" in
          --help) echo 'Cursor --trust --print --mode ask --model --resume stream-json --stream-partial-output status login models' ;;
          status) echo '{"authenticated":true}' ;;
          models) echo 'simulated-cursor - SIMULATED Cursor fixture (no AI)' ;;
          login|logout) exit 0 ;;
          --print)
            /bin/cat >/dev/null
            echo '{"type":"assistant","timestamp_ms":1,"message":{"content":[{"type":"text","text":"SIMULATED Cursor response. No AI service was contacted. "}]}}'
            /bin/sleep 3
            echo '{"type":"result","subtype":"success","is_error":false,"result":"SIMULATED Cursor fixture response completed. No AI service was contacted."}'
            ;;
          *) exit 1 ;;
        esac
        """#
        let executable = root.appendingPathComponent("simulated-agent")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let id = ConversationID("cursor:conversation:simulated-history")
        let date = Date(timeIntervalSince1970: 0)
        let summary = ConversationSummary(id: id, title: "Simulated Cursor • minimap history", createdAt: date, updatedAt: date)
        let messages = (0..<48).map { index in
            ChatMessage(id: MessageID("cursor:fixture:\(index)"), conversationID: id,
                        role: index.isMultiple(of: 2) ? .user : .assistant,
                        content: "SIMULATED message \(index + 1). " + String(repeating: "This is local sample history for transcript and minimap checks. ", count: 4), createdAt: date)
        }
        try JSONEncoder().encode(Archive(conversations: [ConversationSnapshot(summary: summary, messages: messages)]))
            .write(to: root.appendingPathComponent("conversations.json"), options: .atomic)
    }
}
