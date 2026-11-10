@testable import AgentRuntime
import ChatCore
import Foundation
import Testing
import Darwin

@Suite(.serialized) struct CodexRuntimeTests {
    @Test func accountKindsPagingAndGlobalLoginRemainUntouched() async throws {
        let f = try CodexFixture(); defer { f.clean() }
        let service = try await f.settings()
        let status = try #require(try await service.snapshot().first)
        #expect(status.authentication == .configured)
        #expect(status.models.map(\.id.modelID) == ["fixture-model", "other"])
        #expect(status.models.allSatisfy { $0.id.account == CodexProviderSettingsService.account })
        // Free and future plans are accepted without a paid-plan allowlist.
        #expect(try CodexProviderSettingsService.authentication(.object([
            "requiresOpenaiAuth": .bool(true), "account": .object(["type": .string("chatgpt"), "email": .null, "planType": .string("future-plan")])
        ])) == .configured)
        try f.marker("apiKey", name: "auth-kind")
        let api = try #require(try await service.snapshot().first)
        guard case .unavailable(let reason) = api.authentication else { Issue.record("API-key login accepted"); return }
        #expect(reason.contains("API-key")); #expect(api.models.isEmpty)
        try f.marker("signedout", name: "auth-kind")
        #expect(try await service.snapshot().first?.authentication == .signedOut)
        for kind in ["chatgptAuthTokens", "amazonBedrock", "future-auth"] {
            try f.marker(kind, name: "auth-kind")
            guard case .unavailable(let text) = try await service.snapshot().first?.authentication else { Issue.record("Unknown auth accepted"); return }
            #expect(text.contains("kind"))
        }
        await #expect(throws: (any Error).self) { try await service.login(to: f.model.account) }
        await #expect(throws: (any Error).self) { try await service.logout(from: f.model.account) }
        await #expect(throws: (any Error).self) { try await service.setAPIKey("fake-key", for: f.model.account) }
        await service.cancelLogin(to: f.model.account)
        #expect(try String(contentsOf: f.root.appendingPathComponent("auth-state"), encoding: .utf8) == "fixture-auth-sentinel")
        #expect(try f.calls().allSatisfy { !["account/login/start", "account/logout"].contains($0["method"] as? String ?? "") })
        #expect(try f.calls("schema-failure").isEmpty)
        await service.shutdown()
        await #expect(throws: CodexRuntimeError.closed) { _ = try await service.snapshot() }
    }

    @Test func discoveryConfigurationAndCatalogLoopFailSafely() async throws {
        let f = try CodexFixture(); defer { f.clean() }
        let service = try await f.settings()
        #expect(try CodexProcess.discover(searchPath: f.root.path) == f.executable)
        #expect(throws: CodexRuntimeError.unavailable) { try CodexProcess.discover(executablePath: "relative/codex") }
        #expect(throws: CodexRuntimeError.unavailable) { try CodexProcess.discover(executablePath: f.root.path) }
        #expect(throws: CodexRuntimeError.unavailable) { try CodexProcess.discover(executablePath: "/missing/codex") }
        await #expect(throws: ChatBackendError.noModel) { try await service.update(ProviderConfiguration(account: ProviderAccount(option: .chatGPT, providerID: "openai-codex"))) }
        try f.marker("cursorloop")
        guard case .unavailable = try await service.snapshot().first?.authentication else { Issue.record("Loop accepted"); return }
        let url = f.storage.appendingPathComponent("preferences.json")
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("fake-key"))
        #expect(ChatBackendRouter.route(for: f.model.account) == nil) // #21 has not been wired.
        await service.shutdown()
    }

    @Test func atomicAcceptanceStreamingOrderingStableIDsAndDurableContinuation() async throws {
        let f = try CodexFixture(); defer { f.clean() }
        let settings = try await f.settings(), backend = try f.backend(settings: settings)
        var events = await backend.events().makeAsyncIterator()
        #expect(try await events.next() == .snapshot(try await backend.snapshot()))
        let id = try await backend.createConversation(title: "First")
        #expect(id.rawValue.hasPrefix("codex:conversation:"))
        #expect(try await events.next() == .snapshot(try await backend.snapshot()))
        let request = SendRequest(conversationID: id, messageID: MessageID("client-message"), text: "  original text\n", model: f.model)
        try await backend.send(request)
        guard case .conversationUpdated(let accepted) = try await events.next() else { Issue.record("Missing acceptance"); return }
        #expect(accepted.activity == .sending)
        #expect(accepted.messages.map(\.id) == [request.messageID])
        #expect(accepted.messages.first?.content == request.text)
        // Disk has the acceptance before send returns, independently of event consumer timing.
        let disk = try String(contentsOf: f.storage.appendingPathComponent("conversations.json"), encoding: .utf8)
        #expect(disk.contains("client-message")); #expect(disk.contains("accepted"))
        var firstAssistant: MessageID?
        while let event = try await events.next() {
            if case .conversationUpdated(let c) = event {
                if let a = c.messages.first(where: { $0.role == .assistant }) {
                    if let firstAssistant { #expect(firstAssistant == a.id) } else { firstAssistant = a.id }
                }
                if !c.activity.isBusy { break }
            }
        }
        let settled = try await codexSettled(backend, id)
        #expect(settled.messages.map(\.content) == [request.text, "Hello", "World"])
        #expect(settled.messages.allSatisfy { $0.status == .complete })
        try await backend.send(request)
        #expect(try f.calls("turn/start").count == 1)
        await #expect(throws: (any Error).self) { try await backend.send(SendRequest(conversationID: id, messageID: request.messageID, text: "changed", model: f.model)) }
        await #expect(throws: (any Error).self) { try await backend.send(SendRequest(conversationID: id, messageID: request.messageID, text: request.text, model: ModelSelection(account: f.model.account, modelID: "other"))) }
        await backend.shutdown()
        // Explicit shutdown releases the lock while the old object still exists.
        let reopened = try f.backend(settings: settings)
        #expect(try await reopened.snapshot().loadedConversations.first?.messages == settled.messages)
        #expect(try await reopened.snapshot().selectedConversationID == id)
        try await reopened.send(request)
        try await reopened.send(SendRequest(conversationID: id, text: "next", model: f.model))
        let again = try await codexSettled(reopened, id)
        #expect(again.messages.count == 6)
        #expect(Array(again.messages.prefix(3)) == settled.messages)
        #expect(try f.calls("thread/start").count == 1)
        #expect(try f.calls("thread/resume").count == 1)
        #expect(try f.calls("schema-failure").isEmpty)
        for launch in try f.calls("launch") {
            let env = try #require(launch["env"] as? [String])
            #expect(!env.contains(where: { $0.contains("API_KEY") || $0.hasPrefix("CODEX_") || $0.hasPrefix("DYLD_") }))
            #expect((launch["cwd"] as? String)?.hasPrefix(try CodexFiles.canonicalPath(f.storage)) == true)
            #expect((launch["argv"] as? [String])?.contains("sandbox_mode=\"read-only\"") == true)
        }
        await reopened.shutdown(); await settings.shutdown()
    }

    @Test func stopInterruptsOnlyOriginPreservesPartialAndRejectsLateEvents() async throws {
        let f = try CodexFixture(); defer { f.clean() }
        let settings = try await f.settings(), backend = try f.backend(settings: settings)
        let id = try await backend.createConversation(title: "Origin")
        try await backend.send(SendRequest(conversationID: id, text: "hang", model: f.model))
        try await codexEventually { try await backend.snapshot().loadedConversations.first?.messages.last?.content == "Hel" }
        let other = try await backend.createConversation(title: "Selected elsewhere")
        try await backend.stop(conversationID: other)
        #expect(try await backend.snapshot().loadedConversations.first?.activity.isBusy == true)
        try await backend.stop(conversationID: id)
        let stopped = try #require(try await backend.snapshot().loadedConversations.first)
        #expect(stopped.activity == .idle)
        #expect(stopped.messages.last?.content == "Hel")
        #expect(stopped.messages.last?.status == .stopped)
        #expect(try await backend.snapshot().selectedConversationID == other)
        #expect(try f.calls("turn/interrupt").count == 1)
        let pid = try #require(Int32(String(contentsOf: f.root.appendingPathComponent("childpid"), encoding: .utf8)))
        try await codexEventually { kill(pid, 0) != 0 }
        #expect(try await backend.snapshot().loadedConversations.first == stopped)
        await backend.shutdown()
        let reopened = try f.backend(settings: settings)
        #expect(try await reopened.snapshot().loadedConversations.first == stopped)
        try await reopened.send(SendRequest(conversationID: id, text: "continue", model: f.model))
        #expect(try await codexSettled(reopened, id).messages.prefix(2) == stopped.messages.prefix(2))
        #expect(try f.calls("thread/resume").count == 1)
        await reopened.shutdown(); await settings.shutdown()
    }

    @Test func stopAndCallerCancellationBeforeAdmissionDoNotStartTurns() async throws {
        let f = try CodexFixture(); defer { f.clean() }
        let settings = try await f.settings(), backend = try f.backend(settings: settings)
        let id = try await backend.createConversation(title: nil)
        try f.marker("preflight")
        let pending = Task { try await backend.send(SendRequest(conversationID: id, text: "never admitted", model: f.model)) }
        try await codexEventually { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("probing").path) }
        try await backend.stop(conversationID: id)
        await #expect(throws: (any Error).self) { try await pending.value }
        #expect(try f.calls("turn/start").isEmpty)
        #expect(try await backend.snapshot().loadedConversations.first?.messages.isEmpty == true)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("probing"))
        let cancelled = Task { try await backend.send(SendRequest(conversationID: id, text: "cancelled", model: f.model)) }
        try await codexEventually { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("probing").path) }
        cancelled.cancel()
        await #expect(throws: (any Error).self) { try await cancelled.value }
        #expect(try f.calls("turn/start").isEmpty)
        try f.marker("")
        try await backend.send(SendRequest(conversationID: id, text: "admitted", model: f.model))
        #expect(try await codexSettled(backend, id).messages.count == 3)
        await backend.shutdown(); await settings.shutdown()
    }

    @Test func stopBeforeTurnResponseAndSubscriberCancellationCleanUp() async throws {
        let f = try CodexFixture(); defer { f.clean() }
        let settings = try await f.settings(), backend = try f.backend(settings: settings)
        let id = try await backend.createConversation(title: nil)
        let observer = Task { for try await _ in await backend.events() {} }
        try await codexEventually { await backend.subscriberCount == 1 }
        try await backend.send(SendRequest(conversationID: id, text: "before-response", model: f.model))
        try await codexEventually { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("turnpending").path) }
        observer.cancel(); _ = await observer.result
        try await codexEventually { await backend.subscriberCount == 0 }
        #expect(try await backend.snapshot().loadedConversations.first?.activity.isBusy == true)
        try await backend.stop(conversationID: id)
        #expect(try await backend.snapshot().loadedConversations.first?.activity == .idle)
        #expect(try f.calls("turn/interrupt").isEmpty) // no known turn ID: kill the owned connection instead
        await backend.shutdown(); await settings.shutdown()
        for launch in try f.calls("launch") {
            if let pid = launch["pid"] as? Int32 { #expect(kill(pid, 0) != 0) }
        }
    }

    @Test func serverRequestsAreUnsupportedNeverAutoapproved() async throws {
        let f = try CodexFixture(); defer { f.clean() }
        let settings = try await f.settings(), backend = try f.backend(settings: settings)
        let id = try await backend.createConversation(title: nil)
        try await backend.send(SendRequest(conversationID: id, text: "approval", model: f.model))
        try await codexEventually { try f.calls().filter { ($0["id"] as? String)?.hasPrefix("server-") == true }.count == 5 }
        for response in try f.calls().filter({ ($0["id"] as? String)?.hasPrefix("server-") == true }) {
            #expect(response["result"] == nil)
            #expect((response["error"] as? [String: Any])?["code"] as? Int == -32601)
        }
        try await backend.stop(conversationID: id)
        let data = try String(contentsOf: f.storage.appendingPathComponent("conversations.json"), encoding: .utf8)
        #expect(!data.contains("fake-sensitive-token"))
        await backend.shutdown(); await settings.shutdown()
    }

    @Test func validatesAdmissionBusyConflictsAndStorageExclusivity() async throws {
        let f = try CodexFixture(); defer { f.clean() }
        let settings = try await f.settings(), backend = try f.backend(settings: settings)
        #expect(throws: CodexRuntimeError.storage) { try f.backend(settings: settings) }
        let id = try await backend.createConversation(title: nil)
        await #expect(throws: ChatBackendError.emptyMessage) { try await backend.send(SendRequest(conversationID: id, text: " \n", model: f.model)) }
        await #expect(throws: ChatBackendError.noConversation) { try await backend.send(SendRequest(conversationID: ConversationID("missing"), text: "x", model: f.model)) }
        await #expect(throws: ChatBackendError.noModel) { try await backend.send(SendRequest(conversationID: id, text: "x", model: ModelSelection(account: f.model.account, modelID: "missing"))) }
        let request = SendRequest(conversationID: id, messageID: MessageID("shared"), text: "hang", model: f.model)
        try await backend.send(request)
        await #expect(throws: ChatBackendError.busy) { try await backend.send(SendRequest(conversationID: id, text: "x", model: f.model)) }
        let other = try await backend.createConversation(title: nil)
        await #expect(throws: (any Error).self) { try await backend.send(SendRequest(conversationID: other, messageID: request.messageID, text: request.text, model: f.model)) }
        await backend.shutdown()
        await #expect(throws: CodexRuntimeError.closed) { _ = try await backend.createConversation(title: nil) }
        let reopened = try f.backend(settings: settings)
        #expect(try await reopened.snapshot().loadedConversations.first?.activity == .idle)
        let permissions = try FileManager.default.attributesOfItem(atPath: f.storage.appendingPathComponent("conversations.json").path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        await reopened.shutdown(); await settings.shutdown()
    }

    @Test func concurrentIDClaimsFinalItemOrderAndCrashRecovery() async throws {
        let f = try CodexFixture(); defer { f.clean() }
        let settings = try await f.settings(), backend = try f.backend(settings: settings)
        let a = try await backend.createConversation(title: "A"), b = try await backend.createConversation(title: "B")
        let shared = MessageID("concurrent")
        let one = Task { try await backend.send(SendRequest(conversationID: a, messageID: shared, text: "ordering", model: f.model)) }
        let two = Task { try await backend.send(SendRequest(conversationID: b, messageID: shared, text: "ordering", model: f.model)) }
        let results = await [one.result, two.result]
        #expect(results.filter { if case .success = $0 { true } else { false } }.count == 1)
        _ = try await codexSettled(backend, a); _ = try await codexSettled(backend, b)
        let conversation = try #require(try await backend.snapshot().loadedConversations.first { !$0.messages.isEmpty })
        #expect(conversation.messages.map(\.content) == ["ordering", "Hello", "World"])
        #expect(try f.calls("turn/start").count == 1)
        await backend.shutdown()
        // Simulate a process crash by marking the saved turn in flight. Recovery is local-only.
        let url = f.storage.appendingPathComponent("conversations.json")
        var archive = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var conversations = try #require(archive["conversations"] as? [[String: Any]])
        let i = try #require(conversations.firstIndex { ($0["messages"] as? [[String: Any]])?.isEmpty == false })
        var messages = try #require(conversations[i]["messages"] as? [[String: Any]])
        messages[2]["status"] = "streaming"; conversations[i]["messages"] = messages
        conversations[i]["activity"] = ["streaming": [:]]; archive["conversations"] = conversations
        try JSONSerialization.data(withJSONObject: archive).write(to: url)
        let recovered = try f.backend(settings: settings)
        let restored = try #require(try await recovered.snapshot().loadedConversations.first { $0.id == conversation.id })
        #expect(restored.messages.map(\.id) == conversation.messages.map(\.id))
        #expect(restored.messages.map(\.content) == conversation.messages.map(\.content))
        #expect(restored.messages.last?.status == .stopped); #expect(restored.activity == .idle)
        try await recovered.send(SendRequest(conversationID: conversation.id, messageID: shared, text: "ordering", model: f.model))
        #expect(try f.calls("turn/start").count == 1) // accepted request is never replayed
        try await recovered.send(SendRequest(conversationID: conversation.id, text: "new", model: f.model))
        #expect(try await codexSettled(recovered, conversation.id).messages.count == 6)
        #expect(try f.calls("thread/resume").count == 1)
        await recovered.shutdown(); await settings.shutdown()
    }

    @Test func settingsShutdownAndConfigurationChangeCancelProbes() async throws {
        let f = try CodexFixture(); defer { f.clean() }
        let settings = try await f.settings(timeout: 5)
        try f.marker("preflight")
        let pending = Task { try await settings.snapshot() }
        try await codexEventually { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("probing").path) }
        try await settings.update(ProviderConfiguration(account: f.model.account, selectedModelID: "other", executablePath: f.executable.path))
        await #expect(throws: (any Error).self) { _ = try await pending.value }
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("probing"))
        let another = Task { try await settings.snapshot() }
        try await codexEventually { FileManager.default.fileExists(atPath: f.root.appendingPathComponent("probing").path) }
        await settings.shutdown()
        await #expect(throws: (any Error).self) { _ = try await another.value }
        for launch in try f.calls("launch") {
            let pid = try #require(launch["pid"] as? Int32)
            #expect(kill(pid, 0) != 0)
        }
    }

    @Test func processMalformedOversizedExitTimeoutCancellationAndOrphans() async throws {
        let f = try CodexFixture(); defer { f.clean() }
        for (mode, expected) in [("malformed", CodexRuntimeError.invalidOutput), ("oversized", .invalidOutput), ("timeout", .timedOut), ("orphan", .timedOut), ("exit", .exited), ("stderr", .exited)] {
            try f.marker(mode)
            let process = CodexProcess(executable: f.executable, workingDirectory: f.root, requestTimeout: 5)
            await #expect(throws: expected) { try await process.start() }
            await process.shutdown()
            if mode == "orphan" {
                let pid = try #require(Int32(String(contentsOf: f.root.appendingPathComponent("childpid"), encoding: .utf8)))
                try await codexEventually { kill(pid, 0) != 0 }
            }
        }
        // A full stdin pipe must unblock when the owned process is killed on deadline.
        try f.marker("no-read")
        let blockedWriter = CodexProcess(executable: f.executable, workingDirectory: f.root, requestTimeout: 5)
        try await blockedWriter.start()
        await #expect(throws: CodexRuntimeError.timedOut) {
            _ = try await blockedWriter.request("model/list", .object(["padding": .string(String(repeating: "x", count: 1024 * 1024))]))
        }
        await blockedWriter.shutdown()
        try f.marker("timeout")
        let process = CodexProcess(executable: f.executable, workingDirectory: f.root, requestTimeout: 5)
        let pending = Task { try await process.start() }
        try await Task.sleep(for: .milliseconds(60)); pending.cancel()
        await #expect(throws: (any Error).self) { try await pending.value }
        await process.shutdown()
        try f.marker("")
        let rpc = CodexProcess(executable: f.executable, workingDirectory: f.root)
        try await rpc.start()
        await #expect(throws: CodexRuntimeError.rpc) { _ = try await rpc.request("unsupported", .object([:])) }
        #expect(!CodexRuntimeError.rpc.localizedDescription.contains("fake-sensitive-token"))
        await rpc.shutdown()
        let missing = CodexProcess(executable: f.root.appendingPathComponent("missing"), workingDirectory: f.root)
        await #expect(throws: CodexRuntimeError.launch) { try await missing.start() }
        await missing.shutdown()
    }

    @Test func unsafeResponseTurnFailureAndTotalDeadlineAreSanitized() async throws {
        let f = try CodexFixture(); defer { f.clean() }
        let settings = try await f.settings()
        let backend = try CodexChatBackend(storageDirectory: f.storage, settings: settings, requestTimeout: 5, turnTimeout: 8)
        let id = try await backend.createConversation(title: nil)
        try f.marker("unsafe")
        try await backend.send(SendRequest(conversationID: id, text: "x", model: f.model))
        guard case .failed = try await codexSettled(backend, id).activity else { Issue.record("Unsafe sandbox accepted"); return }
        #expect(try f.calls("turn/start").isEmpty)
        try f.marker("")
        try await backend.send(SendRequest(conversationID: id, text: "rpc-error", model: f.model))
        guard case .failed(let message) = try await codexSettled(backend, id).activity else { Issue.record("Failure lost"); return }
        #expect(!message.contains("fake-sensitive-token"))
        try await backend.send(SendRequest(conversationID: id, text: "hang", model: f.model))
        guard case .failed = try await codexSettled(backend, id).activity else { Issue.record("Deadline not enforced"); return }
        await backend.shutdown(); await settings.shutdown()
    }
}
