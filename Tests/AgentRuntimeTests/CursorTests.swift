@testable import AgentRuntime
import ChatCore
import Darwin
import Foundation
import Testing

private struct CursorFixture {
    let root: URL
    let executable: URL
    var storage: URL { root.appendingPathComponent("app-data") }
    var model: ModelSelection { ModelSelection(account: CursorProviderSettingsService.account, modelID: "fixture-model") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Cursor fixture \(UUID())")
        executable = root.appendingPathComponent("cursor-agent")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func settings() async throws -> CursorProviderSettingsService {
        let service = try CursorProviderSettingsService(storageDirectory: storage)
        try await service.update(ProviderConfiguration(account: CursorProviderSettingsService.account, selectedModelID: model.modelID, executablePath: executable.path))
        return service
    }
    func backend() async throws -> CursorChatBackend {
        try CursorChatBackend(storageDirectory: storage, settings: await settings())
    }
    func marker(_ name: String, value: String = "1") throws {
        try value.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    func records() throws -> [[String: Any]] {
        let text = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }
    func printCalls() throws -> [[String: Any]] {
        try records().filter { ($0["argv"] as? [String])?.contains("--print") == true }
    }
    static let script = #"""
#!/usr/bin/python3
import json, os, pathlib, signal, subprocess, sys, time
root = pathlib.Path(__file__).parent
args = sys.argv[1:]
text = sys.stdin.read()
with (root / 'calls.jsonl').open('a') as f:
    f.write(json.dumps({'argv':args, 'stdin':text, 'cwd':os.getcwd(),
        'api_key_inherited':'CURSOR_API_KEY' in os.environ}) + '\n')
def emit(value):
    print(json.dumps(value), flush=True)
def hang():
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    child = subprocess.Popen(['/bin/sleep', '60'])
    (root / 'childpid').write_text(str(child.pid))
    (root / 'parentpid').write_text(str(os.getpid()))
    while True: time.sleep(.1)
if args == ['--help']:
    if (root / 'unsupported').exists(): print('unrelated executable')
    else: print('Cursor --trust --print --mode ask --model --resume --output-format stream-json --stream-partial-output status login models')
elif args == ['status', '--format', 'json']:
    if (root / 'blockstatus').exists():
        (root / 'status-started').write_text('1')
        while (root / 'blockstatus').exists(): time.sleep(.01)
    emit({'isAuthenticated':not (root / 'signedout').exists()})
elif args == ['models']:
    print('Available models\n\nfixture-model - Fixture model\nother - Other model')
elif args == ['login']:
    print('official browser login URL with fake-sensitive-value', flush=True)
    if (root / 'blocklogin').exists(): hang()
    (root / 'signedout').unlink(missing_ok=True)
elif args == ['logout']:
    (root / 'signedout').write_text('1')
elif '--print' in args:
    if '--trust' not in args: sys.exit(1)
    emit({'type':'system', 'subtype':'init', 'session_id':'fixture-session'})
    emit({'type':'assistant','timestamp_ms':1,'message':{'content':[{'type':'text','text':'partial '}]}})
    if text == 'hang': hang()
    if text == 'orphan':
        child = subprocess.Popen(['/bin/sleep','60'])
        (root / 'childpid').write_text(str(child.pid))
        sys.exit(0)
    if text == 'oversized':
        print('x' * (2 * 1024 * 1024 + 1), flush=True)
        sys.exit(0)
    if text == 'invalid':
        print('not json; fake-secret-should-never-escape', flush=True)
    elif text == 'failure':
        sys.stderr.write('fake-secret-should-never-escape' * 10000)
        sys.exit(17)
    elif text == 'error':
        emit({'type':'result','subtype':'error','is_error':True,'error':'fake-secret-should-never-escape'})
    elif text == 'noresult': pass
    else:
        emit({'type':'assistant','timestamp_ms':2,'model_call_id':'duplicate','message':{'content':[{'type':'text','text':'partial '}]}})
        emit({'type':'assistant','message':{'content':[{'type':'text','text':'partial answer'}]}})
        emit({'type':'result','subtype':'success','is_error':False,'result':'partial answer','session_id':'fixture-session'})
else:
    sys.exit(2)
"""#
}

private func eventually(_ condition: @escaping () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw CursorRuntimeError.timedOut }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func settled(_ backend: CursorChatBackend, _ id: ConversationID) async throws -> ConversationSnapshot {
    try await eventually { try await backend.snapshot().loadedConversations.first(where: { $0.id == id })?.activity.isBusy == false }
    return try #require(try await backend.snapshot().loadedConversations.first(where: { $0.id == id }))
}

@Suite(.serialized) struct CursorRuntimeTests {
    @Test func actualProcessArgumentsStdinIsolationAndFraming() async throws {
        let fixture = try CursorFixture(); defer { fixture.clean() }
        let backend = try await fixture.backend()
        try await backend.refreshConnection()
        #expect(try await backend.snapshot().connection == .connected)
        var events = await backend.events().makeAsyncIterator()
        #expect(try await events.next() == .snapshot(try await backend.snapshot()))
        let id = try await backend.createConversation(title: "Fixture")
        let created = try #require(try await events.next())
        guard case .snapshot(let initial) = created else { Issue.record("Expected authoritative create snapshot"); return }
        #expect(initial.selectedConversationID == id)
        #expect(initial.loadedConversations.first?.messages.isEmpty == true)
        let text = "  日本語 ' $(touch should-not-exist); --force\nsecond line  "
        let request = SendRequest(conversationID: id, messageID: MessageID("client-1"), text: text, model: fixture.model)
        try await backend.send(request)
        let accepted = try await backend.snapshot()
        #expect(accepted.loadedConversations.first?.activity.isBusy == true)
        #expect(accepted.loadedConversations.first?.messages.first?.id == request.messageID)
        guard case .conversationUpdated(let sending) = try await events.next() else { Issue.record("Missing acceptance event"); return }
        #expect(sending.messages.first?.content == text)
        #expect(sending.activity == .sending)
        let assistantID = try #require(sending.messages.last?.id)
        var streamingVersions: [ChatMessage] = []
        while let event = try await events.next() {
            if case .conversationUpdated(let update) = event {
                if let message = update.messages.last { streamingVersions.append(message) }
                if !update.activity.isBusy { break }
            }
        }
        #expect(streamingVersions.allSatisfy { $0.id == assistantID })
        #expect(streamingVersions.contains { $0.content == "partial " && $0.status == .streaming })
        #expect(!streamingVersions.contains { $0.content == "partial partial " })
        let completed = try await settled(backend, id)
        #expect(completed.messages.last?.id == assistantID)
        #expect(completed.messages.last?.content == "partial answer")
        #expect(completed.messages.last?.status == .complete)
        let call = try #require(fixture.printCalls().first)
        let argv = try #require(call["argv"] as? [String])
        #expect(argv == ["--print", "--mode", "ask", "--trust", "--output-format", "stream-json", "--stream-partial-output", "--model", "fixture-model", "--workspace", fixture.storage.appendingPathComponent("workspace").path])
        #expect(call["stdin"] as? String == text)
        let actualDirectory = try FileManager.default.attributesOfItem(atPath: #require(call["cwd"] as? String))
        let expectedDirectory = try FileManager.default.attributesOfItem(atPath: fixture.storage.appendingPathComponent("workspace").path)
        #expect(actualDirectory[.systemFileNumber] as? NSNumber == expectedDirectory[.systemFileNumber] as? NSNumber)
        #expect(actualDirectory[.systemNumber] as? NSNumber == expectedDirectory[.systemNumber] as? NSNumber)
        #expect(call["api_key_inherited"] as? Bool == false)
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.appendingPathComponent("workspace/should-not-exist").path))
        try await backend.send(request)
        #expect(try fixture.printCalls().count == 1)
    }

    @Test func durableReopenStableIDsSelectionSessionsAndIdempotency() async throws {
        let fixture = try CursorFixture(); defer { fixture.clean() }
        let service = try await fixture.settings()
        var backend: CursorChatBackend? = try CursorChatBackend(storageDirectory: fixture.storage, settings: service)
        let id = try await backend!.createConversation(title: "Durable")
        let request = SendRequest(conversationID: id, messageID: MessageID("persisted-client"), text: "first", model: fixture.model)
        try await backend!.send(request)
        let original = try await settled(backend!, id)
        backend = nil
        let reopened = try CursorChatBackend(storageDirectory: fixture.storage, settings: service)
        #expect(try await reopened.snapshot().selectedConversationID == id)
        #expect(try await reopened.snapshot().loadedConversations == [original])
        try await reopened.send(request)
        #expect(try fixture.printCalls().count == 1)
        try await reopened.send(SendRequest(conversationID: id, text: "second", model: fixture.model))
        let after = try await settled(reopened, id)
        #expect(after.messages.prefix(2) == original.messages.prefix(2))
        let resumed = try #require(fixture.printCalls().last)
        #expect((resumed["argv"] as? [String])?.suffix(2) == ["--resume", "fixture-session"])
        #expect(resumed["stdin"] as? String == "second")
        let duplicate = SendRequest(conversationID: id, messageID: request.messageID, text: "different", model: fixture.model)
        await #expect(throws: (any Error).self) { try await reopened.send(duplicate) }
        let freshSettings = try CursorProviderSettingsService(storageDirectory: fixture.storage)
        #expect(try await freshSettings.snapshot().first?.configuration.executablePath == fixture.executable.path)
    }

    @Test func errorsAreFramedAndSanitized() async throws {
        let fixture = try CursorFixture(); defer { fixture.clean() }
        let backend = try await fixture.backend()
        for text in ["invalid", "failure", "error", "noresult"] {
            let id = try await backend.createConversation(title: text)
            try await backend.send(SendRequest(conversationID: id, text: text, model: fixture.model))
            let conversation = try await settled(backend, id)
            #expect(conversation.messages.last?.status == .failed)
            #expect(conversation.messages.last?.content == "partial ")
            guard case .failed(let message) = conversation.activity else { Issue.record("Expected failed activity"); continue }
            #expect(!message.contains("fake-secret"))
        }
    }

    @Test func stopKillsChildrenPreservesPartialAndDoesNotChangeSelection() async throws {
        let fixture = try CursorFixture(); defer { fixture.clean() }
        let backend = try await fixture.backend()
        let a = try await backend.createConversation(title: "A")
        let b = try await backend.createConversation(title: "B")
        try await backend.send(SendRequest(conversationID: a, text: "hang", model: fixture.model))
        try await eventually { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("childpid").path) }
        let childPID = try #require(Int32(String(contentsOf: fixture.root.appendingPathComponent("childpid"), encoding: .utf8)))
        let parentPID = try #require(Int32(String(contentsOf: fixture.root.appendingPathComponent("parentpid"), encoding: .utf8)))
        try await backend.stop(conversationID: b)
        #expect(kill(parentPID, 0) == 0)
        try await backend.stop(conversationID: a)
        let stopped = try await backend.snapshot()
        #expect(stopped.selectedConversationID == b)
        let conversation = try #require(stopped.loadedConversations.first(where: { $0.id == a }))
        #expect(conversation.activity == .idle)
        #expect(conversation.messages.last?.status == .stopped)
        #expect(conversation.messages.last?.content == "partial ")
        try await eventually { kill(parentPID, 0) != 0 && kill(childPID, 0) != 0 }
        try await backend.send(SendRequest(conversationID: a, text: "continue", model: fixture.model))
        let resumed = try await settled(backend, a)
        #expect(resumed.messages.count == 4)
        let call = try #require(fixture.printCalls().last)
        #expect((call["argv"] as? [String])?.contains("--resume") == false)
        #expect((call["stdin"] as? String)?.contains("partial ") == true)
    }

    @Test func validatesEmptyModelConfigurationBusyAndIDCollisions() async throws {
        let fixture = try CursorFixture(); defer { fixture.clean() }
        let backend = try await fixture.backend()
        let id = try await backend.createConversation(title: nil)
        await #expect(throws: ChatBackendError.emptyMessage) { try await backend.send(SendRequest(conversationID: id, text: " \n", model: fixture.model)) }
        let wrong = ModelSelection(account: ProviderAccount(option: .apiKey, providerID: "openai"), modelID: "x")
        await #expect(throws: ChatBackendError.noModel) { try await backend.send(SendRequest(conversationID: id, text: "x", model: wrong)) }
        await #expect(throws: ChatBackendError.noModel) { try await backend.send(SendRequest(conversationID: id, text: "x", model: ModelSelection(account: fixture.model.account, modelID: "unknown"))) }
        await #expect(throws: ChatBackendError.noConversation) { try await backend.send(SendRequest(conversationID: ConversationID("missing"), text: "x", model: fixture.model)) }
        try fixture.marker("signedout")
        await #expect(throws: ChatBackendError.disconnected) { try await backend.send(SendRequest(conversationID: id, text: "x", model: fixture.model)) }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("signedout"))
        let request = SendRequest(conversationID: id, messageID: MessageID("busy-id"), text: "hang", model: fixture.model)
        try await backend.send(request)
        try await backend.send(request) // idempotent while busy
        await #expect(throws: ChatBackendError.busy) { try await backend.send(SendRequest(conversationID: id, text: "another", model: fixture.model)) }
        let b = try await backend.createConversation(title: nil)
        await #expect(throws: (any Error).self) { try await backend.send(SendRequest(conversationID: b, messageID: request.messageID, text: "hang", model: fixture.model)) }
        try await backend.stop(conversationID: id)
    }

    @Test func stopDuringPreflightPreventsLaterGeneration() async throws {
        let fixture = try CursorFixture(); defer { fixture.clean() }
        let backend = try await fixture.backend()
        let id = try await backend.createConversation(title: "Cancel preflight")
        try fixture.marker("blockstatus")
        let sending = Task { try await backend.send(SendRequest(conversationID: id, text: "Must not generate", model: fixture.model)) }
        try await eventually { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("status-started").path) }
        try await backend.stop(conversationID: id)
        await #expect(throws: CancellationError.self) { try await sending.value }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("blockstatus"))
        #expect(try fixture.printCalls().isEmpty)
        #expect(try await backend.snapshot().loadedConversations.first?.messages.isEmpty == true)
        // A stopped preflight must not clear or block a subsequent preparation.
        try await backend.send(SendRequest(conversationID: id, text: "New submission", model: fixture.model))
        #expect(try await settled(backend, id).messages.last?.status == .complete)
    }

    @Test func subscriberCancellationReleasesOnlySubscriber() async throws {
        let fixture = try CursorFixture(); defer { fixture.clean() }
        let backend = try await fixture.backend()
        let id = try await backend.createConversation(title: nil)
        let observer = Task { for try await _ in await backend.events() {} }
        try await eventually { await backend.subscriberCount == 1 }
        try await backend.send(SendRequest(conversationID: id, text: "hang", model: fixture.model))
        try await eventually { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("childpid").path) }
        observer.cancel()
        _ = await observer.result
        try await eventually { await backend.subscriberCount == 0 }
        #expect(try await backend.snapshot().loadedConversations.first?.activity.isBusy == true)
        var second = await backend.events().makeAsyncIterator()
        #expect(try await second.next() == .snapshot(try await backend.snapshot()))
        try await backend.stop(conversationID: id)
    }

    @Test func settingsDiscoveryUnsupportedCLIAndOfficialLoginCancellation() async throws {
        let fixture = try CursorFixture(); defer { fixture.clean() }
        let service = try await fixture.settings()
        let status = try #require(try await service.snapshot().first)
        #expect(status.authentication == .configured)
        #expect(status.models.map(\.id.modelID) == ["fixture-model", "other"])
        #expect(try CursorProcess.discover(executablePath: fixture.executable.path) == fixture.executable)
        #expect(try CursorProcess.discover(searchPath: fixture.root.path) == fixture.executable)
        #expect(throws: CursorRuntimeError.unavailable) { try CursorProcess.discover(executablePath: "/missing/cursor-agent") }
        #expect(throws: CursorRuntimeError.unavailable) { try CursorProcess.discover(executablePath: fixture.root.path) }
        await #expect(throws: (any Error).self) { try await service.setAPIKey("fake-key", for: fixture.model.account) }
        try fixture.marker("signedout")
        #expect(try await service.snapshot().first?.authentication == .signedOut)
        try await service.login(to: fixture.model.account)
        #expect(try await service.snapshot().first?.authentication == .configured)
        try await service.logout(from: fixture.model.account)
        #expect(try await service.snapshot().first?.authentication == .signedOut)
        try fixture.marker("blocklogin")
        let login = Task { try await service.login(to: fixture.model.account) }
        try await eventually { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("childpid").path) }
        #expect(try await service.snapshot().first?.authentication == .signingIn)
        await service.cancelLogin(to: fixture.model.account)
        await #expect(throws: CursorRuntimeError.cancelled) { try await login.value }
        try fixture.marker("unsupported")
        guard case .unavailable = try await service.snapshot().first?.authentication else { Issue.record("Expected unsupported CLI"); return }
        #expect(!String(describing: try await service.snapshot()).contains("fake-sensitive"))
    }

    @Test func recoveryRepairsInterruptedTurnsAndStorageIsExclusive() async throws {
        let fixture = try CursorFixture(); defer { fixture.clean() }
        let service = try await fixture.settings()
        var backend: CursorChatBackend? = try CursorChatBackend(storageDirectory: fixture.storage, settings: service)
        let id = try await backend!.createConversation(title: "Recovered")
        #expect(throws: CursorRuntimeError.storage) { try CursorChatBackend(storageDirectory: fixture.storage, settings: service) }
        try await backend!.send(SendRequest(conversationID: id, text: "complete", model: fixture.model))
        let before = try await settled(backend!, id)
        backend = nil
        let url = fixture.storage.appendingPathComponent("conversations.json")
        var data = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var conversations = try #require(data["conversations"] as? [[String: Any]])
        var messages = try #require(conversations[0]["messages"] as? [[String: Any]])
        messages[1]["status"] = "streaming"
        conversations[0]["messages"] = messages
        conversations[0]["activity"] = ["streaming": [:]]
        data["conversations"] = conversations
        try JSONSerialization.data(withJSONObject: data).write(to: url)
        let recovered = try CursorChatBackend(storageDirectory: fixture.storage, settings: service)
        let after = try #require(try await recovered.snapshot().loadedConversations.first)
        #expect(after.activity == .idle)
        #expect(after.messages[1].status == .stopped)
        #expect(after.messages.map(\.id) == before.messages.map(\.id))
        try await recovered.send(SendRequest(conversationID: id, text: "next", model: fixture.model))
        _ = try await settled(recovered, id)
        #expect((try fixture.printCalls().last?["argv"] as? [String])?.contains("--resume") == false)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func concurrentSubscriptionsAndPreflightPreserveUniqueIDs() async throws {
        let fixture = try CursorFixture(); defer { fixture.clean() }
        let backend = try await fixture.backend()
        var first = await backend.events().makeAsyncIterator()
        var second = await backend.events().makeAsyncIterator()
        #expect(try await first.next() == .snapshot(try await backend.snapshot()))
        #expect(try await second.next() == .snapshot(try await backend.snapshot()))
        let a = try await backend.createConversation(title: "A")
        #expect(try await first.next() == second.next())
        let b = try await backend.createConversation(title: "B")
        #expect(try await first.next() == second.next())
        try await backend.selectConversation(nil)
        #expect(try await first.next() == second.next())
        let sharedID = MessageID("concurrent-id")
        let one = Task { try await backend.send(SendRequest(conversationID: a, messageID: sharedID, text: "one", model: fixture.model)) }
        let two = Task { try await backend.send(SendRequest(conversationID: b, messageID: sharedID, text: "two", model: fixture.model)) }
        let results = await [one.result, two.result]
        #expect(results.filter { if case .success = $0 { true } else { false } }.count == 1)
        let snapshot = try await backend.snapshot()
        #expect(snapshot.loadedConversations.flatMap(\.messages).filter { $0.id == sharedID }.count == 1)
        #expect(snapshot.selectedConversationID == nil)
        _ = try await settled(backend, a)
        _ = try await settled(backend, b)
    }

    @Test func processExitRemainsReliableAcrossSuspendingConsumers() async throws {
        let fixture = try CursorFixture(); defer { fixture.clean() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<16 {
                group.addTask {
                    let process = CursorProcess(executable: fixture.executable, workingDirectory: fixture.storage)
                    do {
                        try await process.run(arguments: ["--print", "--trust"], input: i.isMultiple(of: 3) ? "failure" : "success", timeout: 5) { _ in
                            try await Task.sleep(for: .milliseconds(2))
                        }
                        #expect(!i.isMultiple(of: 3))
                    } catch CursorRuntimeError.processFailed(17) { #expect(i.isMultiple(of: 3)) }
                }
            }
            try await group.waitForAll()
        }
        #expect(try fixture.printCalls().count == 16)
    }

    @Test func processTaskCancellationTimeoutLaunchAndOutputBounds() async throws {
        let fixture = try CursorFixture(); defer { fixture.clean() }
        let process = CursorProcess(executable: fixture.executable, workingDirectory: fixture.storage)
        let running = Task { try await process.run(arguments: ["--print", "--trust"], input: "hang") { _ in } }
        try await eventually { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("childpid").path) }
        running.cancel()
        await #expect(throws: CursorRuntimeError.cancelled) { try await running.value }
        let timed = CursorProcess(executable: fixture.executable, workingDirectory: fixture.storage)
        await #expect(throws: CursorRuntimeError.timedOut) { try await timed.run(arguments: ["--print", "--trust"], input: "hang", timeout: 0.2) { _ in } }
        let missing = CursorProcess(executable: fixture.root.appendingPathComponent("missing"), workingDirectory: fixture.storage)
        await #expect(throws: CursorRuntimeError.launch) { try await missing.run(arguments: []) { _ in } }
        let oversized = CursorProcess(executable: fixture.executable, workingDirectory: fixture.storage)
        await #expect(throws: CursorRuntimeError.invalidOutput) { try await oversized.run(arguments: ["--print", "--trust"], input: "oversized") { _ in } }
        let orphan = CursorProcess(executable: fixture.executable, workingDirectory: fixture.storage)
        await #expect(throws: CursorRuntimeError.timedOut) { try await orphan.run(arguments: ["--print", "--trust"], input: "orphan", timeout: 0.3) { _ in } }
        let orphanPID = try #require(Int32(String(contentsOf: fixture.root.appendingPathComponent("childpid"), encoding: .utf8)))
        try await eventually { kill(orphanPID, 0) != 0 }
        let cancelled = CursorProcess(executable: fixture.executable, workingDirectory: fixture.storage)
        cancelled.cancel()
        await #expect(throws: CursorRuntimeError.cancelled) { try await cancelled.run(arguments: []) { _ in } }
    }
}
