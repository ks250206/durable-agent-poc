import AgentRuntime
import ChatCore
import Foundation
import PiDurableKit
import Testing
import os

@Suite(.serialized) struct PiRuntimeTests {
    @Test func streamsCompletesAndReopensAllConversationsWithStableIDs() async throws {
        try await PiFixture.withFixture { fixture in
            let backend = fixture.backend
            let a = try await backend.createConversation(title: "First")
            let b = try await backend.createConversation(title: "Second")
            let request = SendRequest(conversationID: a, messageID: MessageID("client:stable-user"), text: "  Hello\n", model: fixture.selection)
            let answer = "A real streamed faux answer with enough words to observe several committed partial updates before completion."
            try await fixture.faux.append(.text(answer))
            let stream = await backend.events()
            let collector = Task {
                try await piTimeout {
                    var partials: [ChatMessage] = []
                    for try await event in stream {
                        guard let conversation = piConversation(event, id: a) else { continue }
                        if let message = conversation.messages.last, message.status == .streaming { partials.append(message) }
                        if conversation.messages.last?.content == answer, conversation.activity == .idle {
                            return (partials, conversation)
                        }
                    }
                    throw PiTestError.ended
                }
            }
            try await backend.send(request)
            let accepted = try #require(try await backend.snapshot().loadedConversations.first { $0.id == a })
            #expect(accepted.messages.contains { $0.id == request.messageID && $0.content == request.text })
            let (partials, completed) = try await collector.value
            #expect(!partials.isEmpty)
            #expect(partials.allSatisfy { $0.id == completed.messages.last?.id })
            #expect(completed.messages.map(\.role) == [.user, .assistant])
            #expect(completed.messages.first?.id == request.messageID)
            #expect(completed.messages.last?.status == .complete)
            #expect(try await backend.snapshot().selectedConversationID == b)
            try await backend.close()
            let reopened = try await PiChatBackend.open(settings: fixture.settings, databaseURL: fixture.databaseURL)
            do {
                let restored = try await reopened.snapshot()
                #expect(restored.conversations.map(\.id) == [a, b])
                #expect(restored.selectedConversationID == b)
                #expect(restored.loadedConversations.first { $0.id == a } == completed)
                try await reopened.send(request)
                #expect(try await reopened.snapshot().loadedConversations.first { $0.id == a } == completed)
                #expect(try await fixture.faux.pendingResponseCount() == 0)
                try await reopened.selectConversation(nil)
                #expect(try await reopened.snapshot().selectedConversationID == nil)
                try await reopened.close()
            } catch { try? await reopened.close(); throw error }
            // It is genuinely SQLite, rather than a JSON test double.
            let header = try Data(contentsOf: fixture.databaseURL).prefix(16)
            #expect(String(decoding: header, as: UTF8.self) == "SQLite format 3\0")
        }
    }

    @Test func acceptanceEventIsPublishedBeforeReturnAndBusyRejectsCompetingSend() async throws {
        try await PiFixture.withFixture(tokensPerSecond: 20) { fixture in
            let backend = fixture.backend
            let id = try await backend.createConversation(title: nil)
            try await fixture.faux.append(.text(String(repeating: "Streaming answer stays busy. ", count: 50)))
            var events = await backend.events().makeAsyncIterator()
            #expect(try await events.next() == .snapshot(try await backend.snapshot()))
            let request = SendRequest(conversationID: id, messageID: MessageID("client:acceptance"), text: "Go", model: fixture.selection)
            try await backend.send(request)
            // No consumer ran during send: the acceptance is already buffered when it returns.
            let first = try #require(try await events.next())
            let accepted = try #require(piConversation(first, id: id))
            #expect(accepted.messages.contains { $0.id == request.messageID } || accepted.activity.isBusy)
            #expect(accepted.messages.contains { $0.id == request.messageID })
            await #expect(throws: ChatBackendError.busy) {
                try await backend.send(SendRequest(conversationID: id, text: "Duplicate click", model: fixture.selection))
            }
            await #expect(throws: ChatBackendError.self) {
                try await backend.send(SendRequest(conversationID: id, messageID: request.messageID,
                    text: "Different text must not reuse an accepted ID", model: fixture.selection))
            }
            try await backend.send(request) // same client ID acknowledges its original submission while busy
            #expect(try await backend.snapshot().loadedConversations.first?.messages.filter { $0.role == .user }.count == 1)
            try await backend.stop(conversationID: id)
        }
    }

    @Test func abortTargetsConversationAndPreservesPartialAcrossReopen() async throws {
        try await PiFixture.withFixture(tokensPerSecond: 100) { fixture in
            let backend = fixture.backend
            let a = try await backend.createConversation(title: "Stop this one")
            let b = try await backend.createConversation(title: "Keep this one")
            try await fixture.faux.append(.text(String(repeating: "Partial text to retain. ", count: 60)))
            try await backend.send(SendRequest(conversationID: a, text: "First", model: fixture.selection))
            let partial = try await piWait(backend, id: a) { $0.messages.last?.status == .streaming && $0.messages.last?.content.isEmpty == false }
            try await fixture.faux.append(.text("The second conversation finishes normally."))
            try await backend.send(SendRequest(conversationID: b, text: "Second", model: fixture.selection))
            try await backend.stop(conversationID: a)
            let stopped = try #require(try await backend.snapshot().loadedConversations.first { $0.id == a })
            #expect(stopped.activity == .idle)
            #expect(stopped.messages.last?.status == .stopped)
            #expect(stopped.messages.last?.id == partial.messages.last?.id)
            #expect(stopped.messages.last?.content.hasPrefix(partial.messages.last?.content ?? "") == true)
            let completed = try await piWait(backend, id: b) { $0.messages.last?.status == .complete && $0.messages.last?.role == .assistant && $0.activity == .idle }
            #expect(completed.messages.last?.content == "The second conversation finishes normally.")
            #expect(try await backend.snapshot().selectedConversationID == b)
            try await backend.close()
            let reopened = try await PiChatBackend.open(settings: fixture.settings, databaseURL: fixture.databaseURL)
            #expect(try await reopened.snapshot().loadedConversations.first { $0.id == a } == stopped)
            try await reopened.close()
        }
    }

    @Test func providerErrorIsSanitizedAndPersistsFailure() async throws {
        try await PiFixture.withFixture { fixture in
            let id = try await fixture.backend.createConversation(title: nil)
            try await fixture.faux.append([.error("Bearer private-token should never reach the UI")])
            try await fixture.backend.send(SendRequest(conversationID: id, text: "Fail", model: fixture.selection))
            let failed = try await piWait(fixture.backend, id: id) { if case .failed = $0.activity { true } else { false } }
            #expect(failed.messages.last?.status == .failed)
            #expect(!String(describing: failed).contains("private-token"))
            try await fixture.backend.close()
            let reopened = try await PiChatBackend.open(settings: fixture.settings, databaseURL: fixture.databaseURL)
            #expect(try await reopened.snapshot().loadedConversations.first == failed)
            try await reopened.close()
        }
    }

    @Test func atomicSubscriptionCreateSelectAndObserverCancellationDoNotAbort() async throws {
        try await PiFixture.withFixture(tokensPerSecond: 120) { fixture in
            let backend = fixture.backend
            let id = try await backend.createConversation(title: nil)
            try await fixture.faux.append(.text("This answer continues after one observer leaves."))
            let leaving = Task {
                for try await _ in await backend.events() { try Task.checkCancellation() }
            }
            leaving.cancel()
            _ = await leaving.result
            let request = SendRequest(conversationID: id, text: "Continue", model: fixture.selection)
            async let subscribed = backend.events()
            async let selected: Void = backend.selectConversation(nil)
            let stream = await subscribed
            try await selected
            try await backend.send(request)
            let completed = try await piWait(backend, id: id) { $0.activity == .idle && $0.messages.last?.role == .assistant }
            #expect(completed.messages.last?.status == .complete)
            var iterator = stream.makeAsyncIterator()
            guard case .snapshot(let initial)? = try await iterator.next() else { Issue.record("Missing initial snapshot"); return }
            if initial.selectedConversationID != nil {
                guard case .snapshot(let cleared)? = try await iterator.next() else { Issue.record("Missing ordered selection event"); return }
                #expect(cleared.selectedConversationID == nil)
            }
            #expect(try await backend.snapshot().selectedConversationID == nil)
        }
    }

    @Test func rejectsEmptyUnknownModelAndUnsupportedAccountWithoutAdmission() async throws {
        try await PiFixture.withFixture { fixture in
            let backend = fixture.backend
            let id = try await backend.createConversation(title: nil)
            await #expect(throws: ChatBackendError.emptyMessage) {
                try await backend.send(SendRequest(conversationID: id, text: " \n", model: fixture.selection))
            }
            await #expect(throws: ChatBackendError.noModel) {
                try await backend.send(SendRequest(conversationID: id, text: "Go", model: ModelSelection(account: fixture.account, modelID: "missing")))
            }
            await #expect(throws: ChatBackendError.disconnected) {
                try await backend.send(SendRequest(conversationID: id, text: "Go", model: ModelSelection(account: ProviderAccount(option: .cursor, providerID: "cursor"), modelID: "auto")))
            }
            #expect(try await backend.snapshot().loadedConversations.first?.messages.isEmpty == true)
        }
    }

    @Test func restoresPagesAndHistoryBeforeResetWithoutTruncatingSubmessages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DurableChat-pages-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = piTestModels()
        let database = directory.appendingPathComponent("pages.sqlite")
        let harness = try await Harness.open(.sqlite(at: database), models: models, resume: false)
        let ids = try await harness.commit { tx in
            var ids: [PiDurableKit.ConversationID] = []
            for _ in 0..<103 { ids.append(try await tx.createConversation().id) }
            for ordinal in 0..<107 {
                let date = Date(timeIntervalSince1970: Double(ordinal))
                _ = try await tx.append(EntryDraft(kind: "app.history", model: [
                    .user(UserMessage(content: [.text("user \(ordinal)")], timestamp: date)),
                    .assistant(AssistantMessage(content: [.text("answer \(ordinal)")], timestamp: date)),
                ]), to: ids[0])
            }
            _ = try await tx.append(EntryDraft(kind: "app.context", head: .itself), to: ids[0])
            return ids
        }
        try await harness.close()
        let settings = try PiProviderSettingsService(models: models, preferencesURL: directory.appendingPathComponent("providers.json"))
        let backend = try await PiChatBackend.open(settings: settings, databaseURL: database)
        do {
            let snapshot = try await backend.snapshot()
            #expect(snapshot.conversations.map(\.id.rawValue) == ids.map { "pi:conversation:\($0)" })
            #expect(snapshot.loadedConversations.count == 103)
            let history = try #require(snapshot.loadedConversations.first)
            #expect(history.messages.count == 214)
            #expect(history.messages.first?.content == "user 0")
            #expect(history.messages.last?.content == "answer 106")
            #expect(Set(history.messages.map(\.id)).count == 214)
            try await backend.close()
            let reopened = try await PiChatBackend.open(settings: settings, databaseURL: database)
            #expect(try await reopened.snapshot() == snapshot)
            try await reopened.close()
        } catch { try? await backend.close(); throw error }
    }

    @Test func interruptedHarnessReopensStoppedWithoutRestartingProvider() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DurableChat-interrupted-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let models = piTestModels()
        let faux = FauxProvider(tokensPerSecond: 100)
        try await models.register(faux)
        let requests = OSAllocatedUnfairLock(initialState: 0)
        try await faux.respond { _, _ in
            requests.withLock { $0 += 1 }
            return .text(String(repeating: "Preserve this interrupted partial. ", count: 60))
        }
        let database = directory.appendingPathComponent("interrupted.sqlite")
        let harness = try await Harness.open(.sqlite(at: database), models: models,
                                             settings: Settings(progress: .init(partialInterval: .milliseconds(20))))
        let conversation = try await harness.createConversation(agent: AgentChange(model: faux.model, tools: .only([])))
        try await conversation.submit("Interrupt", requestId: "interrupted-client", entry: InputEntry(kind: "durable-chat.user", data: [
            "clientMessageID": "interrupted-client", "createdAt": .number(Date().timeIntervalSince1970),
        ]))
        let partial = try await piTimeout {
            for try await view in conversation.views() {
                if let partial = view.streamingMessage, !partial.text.isEmpty { return partial.text }
            }
            throw PiTestError.ended
        }
        // Upstream close leaves unfinished work pending, simulating restart recovery.
        try await harness.close()
        #expect(requests.withLock { $0 } == 1)
        let settings = try PiProviderSettingsService(models: models, preferencesURL: directory.appendingPathComponent("providers.json"))
        let backend = try await PiChatBackend.open(settings: settings, databaseURL: database)
        do {
            let restored = try #require(try await backend.snapshot().loadedConversations.first)
            #expect(restored.activity == .idle)
            #expect(restored.messages.first?.id == MessageID("interrupted-client"))
            #expect(restored.messages.last?.status == .stopped)
            #expect(restored.messages.last?.content.hasPrefix(partial) == true)
            #expect(try await backend.snapshot().connection == .disconnected)
            #expect(requests.withLock { $0 } == 1)
            try await backend.close()
        } catch { try? await backend.close(); throw error }
    }

}
