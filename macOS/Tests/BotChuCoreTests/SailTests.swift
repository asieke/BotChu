import Foundation
import Testing
@testable import BotChuCore

private typealias S = SailSamples

// MARK: Requests

@Suite struct SailRequestTests {
    @Test func everyRequestIsABackgroundFlexRequestWithTheWholeConversation() throws {
        let input: [SailJSON] = [SailRequest.userMessage("Hi"), ["role": "assistant", "content": "Hello"], SailRequest.userMessage("Again")]
        let body = SailRequest.body(model: S.model, instructions: "Be brief.", input: input, tools: SailToolbox.definitions, effort: "high")
        #expect(body["model"] == .string(S.model))
        #expect(body["background"] == .bool(true))
        #expect(body["metadata"] == ["completion_window": "flex"])
        #expect(body["input"]?.array == input)
        #expect(body["instructions"] == "Be brief.")
        #expect(body["reasoning"] == ["effort": "high"])
        #expect(body["tools"]?.array?.compactMap { $0["name"]?.string } == ["read", "write", "edit", "bash"])
        // Flex is chosen by the metadata alone; nothing streams or leans on Sail's stored state.
        for key in ["stream", "previous_response_id", "service_tier", "store"] { #expect(body[key] == nil, "\(key)") }
        let bare = SailRequest.body(model: S.model, instructions: "", input: input, tools: [], effort: nil)
        #expect(bare["tools"] == nil && bare["reasoning"] == nil && bare["instructions"] == nil)
    }

    @Test func toolsAreNonStrictFunctionsShapedAsPisAre() {
        for tool in SailToolbox.definitions {
            #expect(tool["type"] == "function")
            #expect(tool["strict"] == .bool(false), "Optional parameters would break strict schemas")
            #expect(tool["parameters"]?["type"] == "object")
        }
        let edit = SailToolbox.definitions.first { $0["name"] == "edit" }
        #expect(edit?["parameters"]?["required"] == ["path", "oldText", "newText"])
    }

    @Test func messagesAndToolOutputsAreResponsesInputItems() {
        let image = Data([1, 2, 3])
        #expect(SailRequest.userMessage("Look", images: [image]) == [
            "role": "user",
            "content": [["type": "input_text", "text": "Look"],
                        ["type": "input_image", "image_url": .string("data:image/png;base64," + image.base64EncodedString())]],
        ])
        #expect(SailRequest.functionOutput(callID: "call_1", output: "ok") == ["type": "function_call_output", "call_id": "call_1", "output": "ok"])
    }

    @Test func submissionIsAPostWithTheKeyAndAnIdempotencyKey() async throws {
        let fixture = SailFixture([("POST", "/v1/responses", .ok(S.response("resp_1", "queued")))])
        let harness = try SailHarness()
        defer { harness.remove() }
        let body = SailRequest.body(model: S.model, instructions: "", input: [SailRequest.userMessage("Hi")], tools: [], effort: nil)
        let response = try await harness.client(fixture).submit(body, idempotencyKey: "idem-1", model: S.model)
        #expect(response.id == "resp_1")
        #expect(response.status == .queued)
        let request = try #require(fixture.requests.first)
        #expect(request.url?.absoluteString == "https://sail.test/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "idem-1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(fixture.bodies.first == body)
    }
}

// MARK: Responses

@Suite struct SailResponseTests {
    @Test func statusesAreDistinct() {
        #expect(["queued", "in_progress", "completed", "incomplete", "failed", "cancelled", "canceled", "requires_review"].map(SailStatus.init)
                == [.queued, .inProgress, .completed, .incomplete, .failed, .cancelled, .cancelled, .other("requires_review")])
        let ended: [SailStatus] = [.completed, .incomplete, .failed, .cancelled]
        let going: [SailStatus] = [.queued, .inProgress, .other("requires_review")]
        #expect(ended.allSatisfy { $0.isTerminal })
        #expect(going.allSatisfy { !$0.isTerminal }, "An unknown status is polled on")
        #expect(SailStatus.inProgress.label == "in progress")
    }

    @Test func outputReadsAsTextFunctionCallsAndNextInput() throws {
        let body = S.response("resp_1", "completed", output: "[\(S.reasoning),\(S.message("Running it.")),\(S.call("call_1", "bash", #"{"command":"ls"}"#))]", extra: S.usage)
        let response = try SailResponse.parse(Data(body.utf8))
        #expect(response.model == S.model)
        #expect(response.inputTokens == 1200 && response.outputTokens == 34)
        #expect(response.texts == ["Running it."])
        #expect(response.functionCalls == [SailFunctionCall(callID: "call_1", name: "bash", arguments: #"{"command":"ls"}"#)])
        // Ids, statuses and reasoning stay out of what is sent back.
        #expect(response.conversationItems == [
            ["role": "assistant", "content": "Running it."],
            ["type": "function_call", "call_id": "call_1", "name": "bash", "arguments": #"{"command":"ls"}"#],
        ])
    }

    @Test func failuresAndIncompleteResponsesSayWhy() throws {
        let failed = try SailResponse.parse(Data(S.response("resp_2", "failed", extra: #","error":{"code":"server_error","message":"The model crashed."}"#).utf8))
        #expect(failed.status == .failed)
        #expect(failed.errorMessage == "The model crashed.")
        #expect(failed.errorCode == "server_error")
        let incomplete = try SailResponse.parse(Data(S.response("resp_3", "incomplete", output: "[\(S.message("Half"))]",
                                                                extra: #","incomplete_details":{"reason":"max_output_tokens"}"#).utf8))
        #expect(incomplete.incompleteReason == "max_output_tokens")
        #expect(incomplete.texts == ["Half"])
        #expect(throws: SailFailure.self) { try SailResponse.parse(Data("<html>Bad gateway</html>".utf8)) }
    }

    @Test func modelsComeFromSailsList() throws {
        let models = try SailCatalog.parse(Data(#"{"object":"list","data":[{"id":"zeta/coder","context_length":131072},{"id":"alpha/agent","name":"Alpha Agent"},{"id":"alpha/agent"}]}"#.utf8))
        #expect(models.map(\.id) == ["alpha/agent", "zeta/coder"])
        #expect(models.first?.name == "Alpha Agent")
        #expect(models.last?.contextLength == 131_072)
        #expect(throws: SailFailure.self) { try SailCatalog.parse(Data(#"{"data":[]}"#.utf8)) }
    }
}

// MARK: Retries and polling

@Suite struct SailClientTests {
    @Test func aSubmissionIsRetriedWithTheSameIdempotencyKeyHonouringRetryAfter() async throws {
        let fixture = SailFixture([
            ("POST", "/v1/responses", .http(429, #"{"error":{"message":"Slow down"}}"#, headers: ["Retry-After": "7"])),
            ("POST", "/v1/responses", .failure(.timedOut)),
            ("POST", "/v1/responses", .http(503, "Service Unavailable")),
            ("POST", "/v1/responses", .ok(S.response("resp_1", "queued"))),
        ])
        let harness = try SailHarness()
        defer { harness.remove() }
        let notes = SailLog<SailProgress>()
        let response = try await harness.client(fixture).submit(["model": "m"], idempotencyKey: "idem-1", model: "m") { notes.add($0) }
        #expect(response.id == "resp_1")
        #expect(fixture.requests.map { $0.value(forHTTPHeaderField: "Idempotency-Key") } == Array(repeating: "idem-1", count: 4))
        #expect(Set(fixture.requests.compactMap(\.httpBody)).count == 1, "Every attempt sends the same body")
        // Retry-After as given, then exponential backoff (1 s, 2 s).
        #expect(harness.sleeps.all == [7, 2, 4])
        #expect(notes.all.count == 3)
        if case let .retrying(reason, wait)? = notes.all.first {
            #expect(reason == "HTTP 429: Slow down")
            #expect(wait == 7)
        } else {
            Issue.record("The first retry wasn't reported")
        }
    }

    @Test func backoffDoublesUpToItsLimitAndRetryAfterIsCapped() {
        let policy = SailRetryPolicy()
        #expect((1...8).map { policy.delay(afterAttempt: $0, retryAfter: nil, random: 1) } == [1, 2, 4, 8, 16, 32, 60, 60])
        #expect(policy.delay(afterAttempt: 3, retryAfter: nil, random: 0) == 2, "At least half the backoff")
        #expect(policy.delay(afterAttempt: 1, retryAfter: 86_400, random: 1) == 900)
        let poll = SailPollSchedule()
        #expect((0...6).map { poll.interval(afterPolls: $0) } == [2, 3, 4.5, 6.75, 10.125, 15.1875, 22.78125])
        #expect(poll.interval(afterPolls: 20) == 30)
    }

    @Test func retryAfterReadsSecondsMillisecondsAndDates() throws {
        func headers(_ fields: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: S.base, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: fields)!
        }
        #expect(SailHTTP.retryAfter(headers(["Retry-After": "12"])) == 12)
        #expect(SailHTTP.retryAfter(headers(["retry-after-ms": "1500", "Retry-After": "9"])) == 1.5)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SailHTTP.retryAfter(headers(["Retry-After": "Fri, 15 Jan 2027 08:00:30 GMT"]), now: now) == 30)
        #expect(SailHTTP.retryAfter(headers([:])) == nil)
        #expect(SailHTTP.retryAfter(headers(["Retry-After": "soon"])) == nil)
    }

    @Test func refusalsAreNotRetriedAndAFlexRefusalOffersTheChoices() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        let flex = SailFixture([("POST", "/v1/responses", .http(400, #"{"error":{"message":"completion_window 'flex' is not supported for this model"}}"#))])
        do {
            _ = try await harness.client(flex).submit(["model": "m"], idempotencyKey: "k", model: "big/model")
            Issue.record("A refusal must not succeed")
        } catch let failure as SailFailure {
            #expect(failure.kind == .flex)
            #expect(failure.message.contains("big/model"))
            #expect(failure.message.contains("Settings ▸ Sail"))
            #expect(failure.message.contains("doesn't move work to a faster, pricier completion window"))
        }
        let key = SailFixture([("POST", "/v1/responses", .http(401, #"{"error":{"message":"Invalid API key"}}"#))])
        await #expect(throws: SailFailure(.key, status: 401, "Sail refused the API key (HTTP 401: Invalid API key). Check it in BotChu ▸ Settings ▸ Sail.")) {
            try await harness.client(key).submit(["model": "m"], idempotencyKey: "k", model: "m")
        }
        let other = SailFixture([("POST", "/v1/responses", .http(400, #"{"error":{"message":"input is required"}}"#))])
        await #expect(throws: SailFailure(.rejected, status: 400, "Sail rejected the request for m (HTTP 400: input is required).")) {
            try await harness.client(other).submit(["model": "m"], idempotencyKey: "k", model: "m")
        }
        #expect(harness.sleeps.all.isEmpty)
    }

    @Test func aSubmissionGivesUpAfterItsAttemptsKeepingItsKey() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        let fixture = SailFixture(Array(repeating: ("POST", "/v1/responses", SailFixture.Answer.http(502, "Bad Gateway")), count: 3))
        var client = harness.client(fixture)
        client.retry.submitAttempts = 3
        do {
            _ = try await client.submit(["model": "m"], idempotencyKey: "k", model: "m")
            Issue.record("Three 502s must not succeed")
        } catch let failure as SailFailure {
            #expect(failure.kind == .unavailable)
            #expect(failure.message.contains("idempotency key is kept"))
        }
        #expect(harness.sleeps.all == [1, 2])
    }

    @Test func pollingWaitsThroughQueueAndFailuresUntilTheResponseEnds() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        let fixture = SailFixture([
            ("GET", "/v1/responses/resp_1", .ok(S.response("resp_1", "queued"))),
            ("GET", "/v1/responses/resp_1", .failure(.timedOut)),
            ("GET", "/v1/responses/resp_1", .http(503, "busy", headers: ["Retry-After": "20"])),
            ("GET", "/v1/responses/resp_1", .ok("<html>gateway</html>")),
            ("GET", "/v1/responses/resp_1", .ok(S.response("resp_1", "in_progress"))),
            ("GET", "/v1/responses/resp_1", .ok(S.response("resp_1", "completed", output: "[\(S.message("Done"))]"))),
        ])
        let notes = SailLog<SailProgress>()
        let final = try await harness.client(fixture).wait(for: SailResponse(id: "resp_1", status: .queued)) { notes.add($0) }
        #expect(final.status == .completed)
        #expect(final.texts == ["Done"])
        #expect(fixture.remaining == 0)
        // A timed-out poll, a 503 and a garbled answer are each waited out; the inference goes on.
        #expect(harness.sleeps.all == [2, 3, 1, 20, 4, 15.1875])
        let statuses = notes.all.compactMap { note -> SailStatus? in if case .status(let response) = note { return response.status } else { return nil } }
        #expect(statuses == [.inProgress, .completed], "Only changes are reported")
        #expect(notes.all.count == 5)
    }

    @Test func pollingRetryAfterOnASuccessfulAnswerSetsTheNextPoll() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        let fixture = SailFixture([
            ("GET", "/v1/responses/resp_1", .ok(S.response("resp_1", "queued"), headers: ["Retry-After": "120"])),
            ("GET", "/v1/responses/resp_1", .ok(S.response("resp_1", "completed"))),
        ])
        _ = try await harness.client(fixture).wait(for: SailResponse(id: "resp_1", status: .queued))
        #expect(harness.sleeps.all == [2, 120])
    }

    @Test func aResponseSailNoLongerHasEndsTheWait() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        let fixture = SailFixture([("GET", "/v1/responses/resp_9", .http(404, #"{"error":{"message":"No response found"}}"#))])
        await #expect(throws: SailFailure(.notFound, status: 404, "Sail no longer has response resp_9 (HTTP 404: No response found).")) {
            try await harness.client(fixture).wait(for: SailResponse(id: "resp_9", status: .queued))
        }
    }

    @Test func modelsAreListedWithTheKey() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        let fixture = SailFixture([("GET", "/v1/models", .ok(#"{"data":[{"id":"sail-test/agent-1"}]}"#))])
        #expect(try await harness.client(fixture).models().map(\.id) == ["sail-test/agent-1"])
        #expect(fixture.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let refused = SailFixture([("GET", "/v1/models", .http(401, "{}"))])
        await #expect(throws: SailFailure.self) { try await harness.client(refused).models() }
    }
}

// MARK: The agent

@Suite struct SailAgentTests {
    @Test func aToolCallIsRunAndItsOutputContinuesTheConversation() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        let fixture = SailFixture([
            ("POST", "/v1/responses", .ok(S.response("resp_1", "queued"))),
            ("GET", "/v1/responses/resp_1", .ok(S.response("resp_1", "in_progress"))),
            ("GET", "/v1/responses/resp_1", .ok(S.response("resp_1", "completed", output: "[\(S.message("Listing.")),\(S.call("call_1", "bash", #"{"command":"printf 'a\\nb'"}"#))]", extra: S.usage))),
            ("POST", "/v1/responses", .ok(S.response("resp_2", "queued"))),
            ("GET", "/v1/responses/resp_2", .ok(S.response("resp_2", "completed", output: "[\(S.message("Two files: a and b."))]"))),
        ])
        let ok = await harness.run(fixture, SailAgent.Turn(sessionID: "s1", resume: false, model: S.model, prompt: "List them"))
        #expect(ok)
        #expect(fixture.remaining == 0)

        // Each submission has its own key and carries the whole conversation, the tool's output included.
        #expect(fixture.requests.filter { $0.httpMethod == "POST" }.map { $0.value(forHTTPHeaderField: "Idempotency-Key") } == ["key-1", "key-2"])
        let second = try #require(fixture.bodies.last?["input"]?.array)
        #expect(second.count == 4)
        #expect(second[0] == SailRequest.userMessage("List them"))
        #expect(second[1] == ["role": "assistant", "content": "Listing."])
        #expect(second[2]["type"] == "function_call")
        #expect(second[3] == SailRequest.functionOutput(callID: "call_1", output: "a\nb"))
        #expect(fixture.bodies.allSatisfy { $0["background"] == .bool(true) && $0["metadata"] == ["completion_window": "flex"] })

        let events = harness.events.all
        #expect(events.first == .session("s1"), "Once the session is saved")
        #expect(events.dropFirst().first == .flex(row: "key-1", detail: "Submitting to Sail Flex · \(S.model)", state: .waiting))
        #expect(events.contains(.model(S.model)))
        #expect(events.contains(.toolStarted(id: "call_1", name: "bash", arguments: ["command": "printf 'a\\nb'"])))
        #expect(events.contains(.toolFinished(id: "call_1", name: "bash", output: "a\nb", isError: false, exitCode: 0)))
        #expect(events.contains(.flex(row: "key-1", detail: "Completed on Sail Flex · resp_1 · 0 s · 1200 in, 34 out", state: .done)))
        #expect(events.contains(.flex(row: "key-1", detail: "Running on Sail Flex · resp_1 · \(S.model)", state: .waiting)))
        #expect(!events.contains { event in
            if case let .flex(_, detail, .waiting) = event { return detail.hasPrefix("Completed") }
            return false
        }, "An ended response is reported once, as ended")
        #expect(events.last == .finished)

        // The session holds the conversation and nothing pending.
        let session = try #require(try harness.store.load("s1"))
        #expect(session.pending == nil)
        #expect(session.items.count == 5)
        #expect(session.items.last == ["role": "assistant", "content": "Two files: a and b."])

        // As the chat shows it: the queued work as a row, then the reply, the tool and the answer.
        let thread = harness.thread
        #expect(thread.filter { $0.role == .assistant }.map(\.text) == ["Listing.", "Two files: a and b."])
        let rows = thread.filter { $0.toolName == SailAgent.rowName }
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.toolState == .done })
        #expect(thread.first { $0.toolName == "bash" }?.toolOutput == "a\nb")
    }

    @Test func aReplyAnnouncingItsNextStepWithoutTheCallIsAskedToGoOn() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        // As DeepSeek-V4.1-Flash ended turns on 2026-10-28: a short reply naming the next step, and no call.
        let fixture = SailFixture([
            ("POST", "/v1/responses", .ok(S.response("resp_1", "completed", output: "[\(S.call("call_1", "bash", #"{"command":"true"}"#))]"))),
            ("POST", "/v1/responses", .ok(S.response("resp_2", "completed", output: "[\(S.message("Core is green. Now the two rendering tests that failed, one at a time:"))]"))),
            ("POST", "/v1/responses", .ok(S.response("resp_3", "completed", output: "[\(S.call("call_2", "bash", #"{"command":"true"}"#))]"))),
            ("POST", "/v1/responses", .ok(S.response("resp_4", "completed", output: "[\(S.message("Both pass now."))]"))),
        ])
        #expect(await harness.run(fixture, SailAgent.Turn(sessionID: "s-go-on", resume: false, model: S.model, prompt: "Fix the tests")))
        #expect(fixture.remaining == 0)
        let third = try #require(fixture.bodies.dropFirst(2).first?["input"]?.array)
        #expect(third.last == SailRequest.userMessage(SailInstructions.keepGoing))
        #expect(harness.thread.filter { $0.role == .assistant }.map(\.text)
                == ["Core is green. Now the two rendering tests that failed, one at a time:", "Both pass now."])
        #expect(harness.events.all.last == .finished)
    }

    @Test func aModelThatKeepsAnnouncingIsTakenAtItsWordAfterTwoNudges() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        let fixture = SailFixture((1...3).map { n in
            ("POST", "/v1/responses", .ok(S.response("resp_\(n)", "completed", output: "[\(S.message("Let me check the logs:"))]")))
        })
        #expect(await harness.run(fixture, SailAgent.Turn(sessionID: "s-nudged", resume: false, model: S.model, prompt: "Why?")))
        #expect(fixture.remaining == 0)
        let session = try #require(try harness.store.load("s-nudged"))
        #expect(session.items.filter { $0 == SailRequest.userMessage(SailInstructions.keepGoing) }.count == 2)
        #expect(session.items.last == ["role": "assistant", "content": "Let me check the logs:"])
    }

    @Test(arguments: [
        // Turn endings Sail's DeepSeek-V4.1-Flash gave on 2026-10-28, each mid-task.
        ("Now updating the README, which currently states the opposite. Let me find every claim:", true),
        ("All 863 Core tests pass. Waiting for the release and window-test phases:", true),
        ("Core is green. Now the two rendering tests that failed, one at a time:", true),
        ("Main is clean, all work is in the worktree. Continuing with the README now.", true),
        ("Running the suite again...", true),
        ("The fix is in. Let me run the tests.", true),
        ("", true),
        // Answers.
        ("Opened PR #41; it isn't merged.", false),
        ("Done. Let me know if you want the README changed too.", false),
        ("What would you like to do — benchmark it, or merge the PR?", false),
        ("Three things are left:\n\n- the README\n- the tests\n- the PR", false),
    ])
    func repliesThatStopShortAreToldFromAnswers(reply: String, stopsShort: Bool) {
        #expect(SailInstructions.announcesNextStep(reply) == stopsShort)
    }

    @Test func aResumedTurnSendsTheWholeConversationAgainWithoutPreviousResponseID() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        let first = SailFixture([("POST", "/v1/responses", .ok(S.response("resp_1", "completed", output: "[\(S.message("The word is ZEBRA."))]")))])
        #expect(await harness.run(first, SailAgent.Turn(sessionID: "s2", resume: false, model: S.model, prompt: "Remember ZEBRA")))
        let second = SailFixture([("POST", "/v1/responses", .ok(S.response("resp_2", "completed", output: "[\(S.message("ZEBRA"))]")))])
        #expect(await harness.run(second, SailAgent.Turn(sessionID: "s2", resume: true, model: S.model, prompt: "What was the word?")))
        let input = try #require(second.bodies.first?["input"]?.array)
        #expect(input == [SailRequest.userMessage("Remember ZEBRA"), ["role": "assistant", "content": "The word is ZEBRA."],
                          SailRequest.userMessage("What was the word?")])
        #expect(second.bodies.first?["previous_response_id"] == nil)
    }

    @Test func aSavedResponseIDIsPolledAgainAfterAnInterruptionNotResubmitted() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        // A run that ended while resp_1 was queued.
        let body = SailRequest.body(model: S.model, instructions: "Be brief.", input: [SailRequest.userMessage("Write the report")],
                                    tools: SailToolbox.definitions, effort: nil)
        try harness.store.save(SailSession(id: "s3", items: [SailRequest.userMessage("Write the report")],
                                           pending: SailPending(idempotencyKey: "old-key", body: body, model: S.model, responseID: "resp_1",
                                                                status: "queued", submittedAt: S.start), updatedAt: S.start))
        let fixture = SailFixture([
            ("GET", "/v1/responses/resp_1", .ok(S.response("resp_1", "completed", output: "[\(S.message("Report written."))]"))),
            ("POST", "/v1/responses", .ok(S.response("resp_2", "completed", output: "[\(S.message("Yes, it's done."))]"))),
        ])
        let ok = await harness.run(fixture, SailAgent.Turn(sessionID: "s3", resume: true, model: S.model, prompt: "Is it done?"))
        #expect(ok)
        #expect(fixture.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == ["GET /v1/responses/resp_1", "POST /v1/responses"])
        // The picked-up reply comes before the new message, in the conversation and in the chat.
        let input = try #require(fixture.bodies.first?["input"]?.array)
        #expect(input == [SailRequest.userMessage("Write the report"), ["role": "assistant", "content": "Report written."],
                          SailRequest.userMessage("Is it done?")])
        #expect(harness.events.all.first == .flex(row: "old-key", detail: "Picking up response resp_1, submitted \(SailAgent.clock(S.start)), on Sail Flex",
                                                  state: .waiting))
        #expect(harness.thread.filter { $0.role == .assistant }.map(\.text) == ["Report written.", "Yes, it's done."])
    }

    @Test func aSubmissionWithoutAResponseIsSentAgainWithItsOwnKeyAndBody() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        let body = SailRequest.body(model: S.model, instructions: "Earlier instructions", input: [SailRequest.userMessage("Start")], tools: [], effort: nil)
        try harness.store.save(SailSession(id: "s4", items: [SailRequest.userMessage("Start")],
                                           pending: SailPending(idempotencyKey: "old-key", body: body, model: S.model, submittedAt: S.start)))
        let fixture = SailFixture([
            ("POST", "/v1/responses", .ok(S.response("resp_1", "completed", output: "[\(S.message("Started."))]"))),
            ("POST", "/v1/responses", .ok(S.response("resp_2", "completed", output: "[\(S.message("Continuing."))]"))),
        ])
        #expect(await harness.run(fixture, SailAgent.Turn(sessionID: "s4", resume: true, model: S.model, prompt: "Go on")))
        let keys = fixture.requests.map { $0.value(forHTTPHeaderField: "Idempotency-Key") }
        #expect(keys == ["old-key", "key-1"])
        #expect(fixture.bodies.first == body, "The same submission, so Sail can tell it's the same")
    }

    @Test func toolCallsOfAPickedUpResponseAreReportedNotRun() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        let marker = harness.work.appendingPathComponent("ran.txt")
        let body = SailRequest.body(model: S.model, instructions: "", input: [SailRequest.userMessage("Do it")], tools: [], effort: nil)
        try harness.store.save(SailSession(id: "s5", items: [SailRequest.userMessage("Do it")],
                                           pending: SailPending(idempotencyKey: "old-key", body: body, model: S.model, responseID: "resp_1",
                                                                status: "in_progress", submittedAt: S.start)))
        let fixture = SailFixture([
            ("GET", "/v1/responses/resp_1", .ok(S.response("resp_1", "completed", output: "[\(S.call("call_9", "bash", #"{"command":"touch ran.txt"}"#))]"))),
            ("POST", "/v1/responses", .ok(S.response("resp_2", "completed", output: "[\(S.message("Okay, stopping."))]"))),
        ])
        #expect(await harness.run(fixture, SailAgent.Turn(sessionID: "s5", resume: true, model: S.model, prompt: "Never mind")))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "A stopped turn's tool call isn't run later")
        let input = try #require(fixture.bodies.first?["input"]?.array)
        #expect(input.count == 4)
        #expect(input[2]["call_id"] == "call_9")
        #expect(input[2]["output"]?.string?.hasPrefix("Not run:") == true)
        #expect(input[3] == SailRequest.userMessage("Never mind"))
        #expect(harness.thread.first { $0.toolID == "call_9" }?.toolState == .failed)
    }

    @Test func callsLeftRunningByAnEndedRunAreClosedBeforeTheNextMessage() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        try harness.store.save(SailSession(id: "s6", items: [
            SailRequest.userMessage("Build it"),
            ["type": "function_call", "call_id": "call_1", "name": "bash", "arguments": #"{"command":"make"}"#],
        ]))
        let fixture = SailFixture([("POST", "/v1/responses", .ok(S.response("resp_1", "completed", output: "[\(S.message("Okay."))]")))])
        #expect(await harness.run(fixture, SailAgent.Turn(sessionID: "s6", resume: true, model: S.model, prompt: "Status?")))
        let input = try #require(fixture.bodies.first?["input"]?.array)
        #expect(input[2]["type"] == "function_call_output")
        #expect(input[2]["output"]?.string?.hasPrefix("Interrupted:") == true)
        #expect(input[3] == SailRequest.userMessage("Status?"))
    }

    @Test(arguments: [
        ("failed", #","error":{"code":"server_error","message":"Out of capacity"}"#, "Sail couldn't complete response resp_1: Out of capacity."),
        ("cancelled", "", "Sail cancelled response resp_1. BotChu never asks it to; check the Sail dashboard."),
        ("incomplete", #","incomplete_details":{"reason":"max_output_tokens"}"#,
         "Sail stopped response resp_1 before it finished (max_output_tokens). What it wrote is above; send a message to go on."),
    ])
    func eachEndingIsReportedAsItself(status: String, extra: String, message: String) async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        let output = status == "incomplete" ? "[\(S.message("Partial answer"))]" : "[]"
        let fixture = SailFixture([
            ("POST", "/v1/responses", .ok(S.response("resp_1", "queued"))),
            ("GET", "/v1/responses/resp_1", .ok(S.response("resp_1", status, output: output, extra: extra))),
        ])
        #expect(!(await harness.run(fixture, SailAgent.Turn(sessionID: "s7", resume: false, model: S.model, prompt: "Go"))))
        let events = harness.events.all
        #expect(events.last == .failed(message))
        #expect(!events.contains(.finished))
        #expect(events.contains { if case .flex(_, _, .failed) = $0 { true } else { false } })
        #expect(events.contains(.text("Partial answer")) == (status == "incomplete"))
        // The submission is over: the next turn doesn't poll it again.
        #expect(try harness.store.load("s7")?.pending == nil)
    }

    @Test func aResponseThatFailsOverFlexOffersTheChoicesToo() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        let fixture = SailFixture([
            ("POST", "/v1/responses", .ok(S.response("resp_1", "queued"))),
            ("GET", "/v1/responses/resp_1", .ok(S.response("resp_1", "failed", extra: #","error":{"code":"unsupported_completion_window","message":"Flex is not available for this model"}"#))),
        ])
        #expect(!(await harness.run(fixture, SailAgent.Turn(sessionID: "s14", resume: false, model: S.model, prompt: "Go"))))
        guard case .failed(let message)? = harness.events.all.last else { Issue.record("No failure"); return }
        #expect(message.hasPrefix("Sail won't run \(S.model) on Flex (response resp_1 failed: Flex is not available for this model)."))
        #expect(message.contains("Choose a model that takes Flex"))
    }

    @Test func aRefusedSubmissionLeavesNothingPendingAndAnUnreachableOneIsKept() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        let refused = SailFixture([("POST", "/v1/responses", .http(422, #"{"error":{"message":"completion_window flex unavailable for model"}}"#))])
        #expect(!(await harness.run(refused, SailAgent.Turn(sessionID: "s8", resume: false, model: S.model, prompt: "Go"))))
        #expect(try harness.store.load("s8")?.pending == nil)
        if case .failed(let message)? = harness.events.all.last { #expect(message.contains("won't run \(S.model) on Flex")) } else { Issue.record("No failure") }

        var answers: [(String, String, SailFixture.Answer)] = []
        for _ in 0..<8 { answers.append(("POST", "/v1/responses", .failure(.notConnectedToInternet))) }
        let offline = SailFixture(answers)
        #expect(!(await harness.run(offline, SailAgent.Turn(sessionID: "s9", resume: false, model: S.model, prompt: "Go"))))
        let kept = try #require(try harness.store.load("s9")?.pending)
        #expect(kept.idempotencyKey == "key-1")
        #expect(kept.responseID == nil)

        // A 2xx Sail may have acted on, whose body can't be read, isn't a refusal: the next run
        // sends it again with its key, so Sail returns that submission instead of starting another.
        let garbled = SailFixture([("POST", "/v1/responses", .http(202, "<html>gateway</html>"))])
        #expect(!(await harness.run(garbled, SailAgent.Turn(sessionID: "s10", resume: false, model: S.model, prompt: "Go"))))
        let uncertain = try #require(try harness.store.load("s10")?.pending)
        #expect(uncertain.responseID == nil)
        let again = SailFixture([
            ("POST", "/v1/responses", .ok(S.response("resp_1", "completed", output: "[\(S.message("Went."))]"))),
            ("POST", "/v1/responses", .ok(S.response("resp_2", "completed", output: "[\(S.message("Again."))]"))),
        ])
        #expect(await harness.run(again, SailAgent.Turn(sessionID: "s10", resume: true, model: S.model, prompt: "Again")))
        #expect(again.requests.first?.value(forHTTPHeaderField: "Idempotency-Key") == uncertain.idempotencyKey)
        #expect(again.bodies.first == uncertain.body)
    }

    @Test func stoppingLeavesTheResponseAtSailAndSaysSo() async throws {
        let live = SailLive()
        live.submitted(row: "key-1", response: "resp_1")
        let notice = try #require(live.stop())
        #expect(notice == .flex(row: "key-1", detail: SailAgent.detachedDetail(response: "resp_1"), state: .detached))
        #expect(SailAgent.detachedDetail(response: "resp_1").contains("Sail can't cancel response resp_1, so it may still finish and be billed"))
        // The row stays open until the run ends, then reads as interrupted: never as cancelled.
        var parser = SailParser()
        var messages: [ChatMessage] = []
        var assembler = ThreadAssembler()
        for line in [SailEvent.flex(row: "key-1", detail: "Queued on Sail Flex · resp_1 · m", state: .waiting).line, notice.line] {
            for event in parser.parse(line: line) { assembler.apply(event, to: &messages) }
        }
        ThreadAssembler.closeRunningTools(&messages)
        #expect(messages.count == 1)
        #expect(messages[0].toolState == .interrupted)
        #expect(messages[0].toolInput?.hasPrefix("Stopped in BotChu only") == true)
        live.settled()
        #expect(live.stop() == nil, "Nothing to say when nothing is out at Sail")
    }

    @Test func aMissingSessionKeyOrModelStopsBeforeAnyRequest() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        let fixture = SailFixture([])
        #expect(!(await harness.run(fixture, SailAgent.Turn(sessionID: "gone", resume: true, model: S.model, prompt: "Hi"))))
        #expect(!(await harness.run(fixture, SailAgent.Turn(sessionID: "s10", resume: false, model: " ", prompt: "Hi"))))
        var agent = harness.agent(fixture)
        agent.client.key = ""
        let events = SailLog<SailEvent>()
        #expect(!(await agent.run(SailAgent.Turn(sessionID: "s11", resume: false, model: S.model, prompt: "Hi")) { events.add($0) }))
        let failures = (harness.events.all + events.all).compactMap { event -> String? in if case .failed(let message) = event { message } else { nil } }
        #expect(failures.count == 3)
        #expect(failures[0].contains("no longer on this Mac"))
        #expect(failures[1].contains("No Sail model is chosen"))
        #expect(failures[2].contains("no Sail API key"))
        #expect(fixture.requests.isEmpty)
        #expect(try harness.store.load("s10") == nil, "A turn that couldn't start leaves no session to resume")
    }

    @Test func onlyResponsesAreEverSentNeverACancellation() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        let fixture = SailFixture([
            ("POST", "/v1/responses", .ok(S.response("resp_1", "queued"))),
            ("GET", "/v1/responses/resp_1", .ok(S.response("resp_1", "cancelled"))),
        ])
        _ = await harness.run(fixture, SailAgent.Turn(sessionID: "s12", resume: false, model: S.model, prompt: "Go"))
        #expect(fixture.requests.allSatisfy { ($0.httpMethod == "POST" && $0.url?.path == "/v1/responses") || ($0.httpMethod == "GET" && $0.url?.path.hasPrefix("/v1/responses/") == true) })
        #expect(!fixture.requests.contains { $0.httpMethod == "DELETE" || $0.url?.path.hasSuffix("/cancel") == true })
    }
}

// MARK: Keys stay secret

@Suite struct SailSecretTests {
    @Test func theKeyReachesOnlyTheAuthorizationHeader() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        let fixture = SailFixture([
            ("POST", "/v1/responses", .ok(S.response("resp_1", "completed", output: "[\(S.call("call_1", "bash", #"{"command":"env"}"#))]"))),
            ("POST", "/v1/responses", .ok(S.response("resp_2", "completed", output: "[\(S.message("Done."))]"))),
        ])
        #expect(await harness.run(fixture, SailAgent.Turn(sessionID: "s13", resume: false, model: S.model, prompt: "Show the environment")))
        let printed = harness.events.all.map(\.line).joined(separator: "\n")
        #expect(printed.contains("BOTCHU_BIN_DIR"), "The tool did print its environment")
        #expect(!printed.contains(S.key), "Not in the events or the tool's environment")
        let saved = try String(contentsOf: harness.store.url(for: "s13"), encoding: .utf8)
        #expect(!saved.contains(S.key))
        #expect(!fixture.bodies.map(\.text).joined().contains(S.key))
        #expect(SailToolbox.toolEnvironment([Sail.keyVariable: "x", Sail.baseVariable: "y", "PATH": "/bin"]) == ["PATH": "/bin"])
        #expect(AgentRun.childEnvironment([Sail.keyVariable: "x", "PATH": "/bin"]) == ["PATH": "/bin"])
        let attributes = try FileManager.default.attributesOfItem(atPath: harness.store.url(for: "s13").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func sessionIDsAreFileNamesBotChuMade() {
        #expect(SailSessionStore.isValid("0b9a7c2e-1d2f-4c3b-9a8e-7f6d5c4b3a21"))
        for bad in ["", "../escape", "a/b", "with space", String(repeating: "a", count: 129), "é"] { #expect(!SailSessionStore.isValid(bad), "\(bad)") }
    }
}

// MARK: Tools

@Suite struct SailToolTests {
    func call(_ name: String, _ arguments: SailJSON) -> SailFunctionCall {
        SailFunctionCall(callID: "c", name: name, arguments: arguments.text)
    }

    @Test func writeReadAndEditFilesInTheWorkingFolder() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        let tools = SailToolbox(directory: harness.work, environment: [:])
        #expect(await tools.run(call("write", ["path": "notes/a.txt", "content": "one\ntwo\nthree\n"])).output == "Wrote 14 bytes to notes/a.txt.")
        #expect(await tools.run(call("read", ["path": "notes/a.txt"])).output == "one\ntwo\nthree")
        #expect(await tools.run(call("read", ["path": "notes/a.txt", "offset": 2, "limit": 1])).output == "two\n\n[Lines 2–2 of 3. Read on with offset 3.]")
        let edited = await tools.run(call("edit", ["path": "notes/a.txt", "oldText": "two", "newText": "2"]))
        #expect(!edited.isError)
        #expect(try String(contentsOf: harness.work.appendingPathComponent("notes/a.txt"), encoding: .utf8) == "one\n2\nthree\n")
        let missing = await tools.run(call("edit", ["path": "notes/a.txt", "oldText": "four", "newText": "4"]))
        #expect(missing.isError && missing.output.contains("isn't in notes/a.txt"))
        _ = await tools.run(call("write", ["path": "twice.txt", "content": "x x"]))
        let twice = await tools.run(call("edit", ["path": "twice.txt", "oldText": "x", "newText": "y"]))
        #expect(twice.isError && twice.output.contains("2 times"))
        #expect(await tools.run(call("read", ["path": "nope.txt"])).isError)
        #expect(await tools.run(call("read", ["path": "notes"])).output.contains("is a folder"))
        #expect(await tools.run(call("fly", [:])).isError)
        #expect(await tools.run(SailFunctionCall(callID: "c", name: "read", arguments: "not json")).isError)
    }

    @Test func bashReportsOutputExitCodeAndTimeout() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        var tools = SailToolbox(directory: harness.work, environment: ["PATH": "/usr/bin:/bin"])
        let ok = await tools.run(call("bash", ["command": "pwd; echo err >&2"]))
        #expect(ok.output.contains(harness.work.lastPathComponent) && ok.output.contains("err"))
        #expect(ok.exitCode == 0 && !ok.isError)
        let failed = await tools.run(call("bash", ["command": "exit 3"]))
        #expect(failed.isError && failed.exitCode == 3)
        #expect(failed.output == "(no output)\n\n[Exit code 3]")
        tools.defaultTimeout = 1
        let slow = await tools.run(call("bash", ["command": "sleep 20"]))
        #expect(slow.isError && slow.output.contains("Stopped after 1 s"))
    }

    @Test func longOutputKeepsItsEnd() {
        let text = (1...3_000).map(String.init).joined(separator: "\n")
        let tail = SailToolbox.tail(text)
        #expect(tail.hasPrefix("[Earlier output cut: the last 2000 of 3000 lines.]"))
        #expect(tail.hasSuffix("\n3000"))
    }
}

// MARK: The helper and BotChu

@Suite struct SailCommandTests {
    @Test func botChuRunsTheHelperWithItsSessionModelEffortAndKey() {
        let first = CommandBuilder.invocation(kind: .sail, prompt: "hi", model: S.model, sessionID: nil, reasoningEffort: .medium,
                                              openRouterKey: "or-key", sailKey: S.key, newID: { "fixed-id" })
        #expect(first.arguments == ["--session-id", "fixed-id", "--model", S.model, "--effort", "medium", "hi"])
        #expect(first.sessionID == "fixed-id")
        #expect(first.environment == [Sail.keyVariable: S.key], "Only Sail's key")
        let next = CommandBuilder.invocation(kind: .sail, prompt: "-again", model: nil, sessionID: "fixed-id")
        #expect(next.arguments == ["--session-id", "fixed-id", "--resume", " -again"])
        #expect(next.environment.isEmpty)
        #expect(CommandBuilder.resumeID(kind: .sail, invocation: first, reported: "other") == "fixed-id")
        #expect(!CommandBuilder.takesInputMidTurn(.sail))
        #expect(!CommandBuilder.runsToolFree(.sail))
        #expect(CommandBuilder.invocation(kind: .pi, prompt: "hi", model: nil, sessionID: nil, sailKey: S.key).environment.isEmpty)
    }

    @Test func helperArgumentsParse() throws {
        let options = try SailCommand.parse(["--session-id", "s", "--resume", "--model", "m", "--effort", "low", "--image", "/a.png",
                                             "--image", "/b.png", "--state-dir", "/tmp/x", "--", "-prompt"])
        #expect(options.sessionID == "s" && options.resume && options.model == "m" && options.effort == "low")
        #expect(options.images == ["/a.png", "/b.png"])
        #expect(options.stateDirectory == "/tmp/x")
        #expect(options.prompt == "-prompt")
        #expect(try SailCommand.parse(["hello"]).prompt == "hello")
        #expect(throws: SailFailure.self) { try SailCommand.parse(["--fly", "x"]) }
        #expect(throws: SailFailure.self) { try SailCommand.parse(["one", "two"]) }
        #expect(throws: SailFailure.self) { try SailCommand.parse(["--model"]) }
        #expect(throws: SailFailure.self) { try SailCommand.parse([]) }
    }

    @Test func theHelperSaysWhatIsMissingAsAnEvent() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        let lines = SailLog<String>()
        let status = await SailCommand.main(arguments: ["--session-id", "s", "--state-dir", harness.root.path, "--model", "m", "Hi"],
                                            environment: [:], directory: harness.work, handleSignals: false) { lines.add($0) }
        #expect(status == 1)
        #expect(lines.all.map { SailEvent(line: $0) } == [.failed("There's no Sail API key. Add yours in BotChu ▸ Settings ▸ Sail.")])
        let bad = await SailCommand.main(arguments: ["--nope"], environment: [:], directory: harness.work, handleSignals: false) { lines.add($0) }
        #expect(bad == 2)
    }

    @Test func imagesGoToTheHelperAsOptions() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sail-image-\(UUID()).png")
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let plain = CommandBuilder.invocation(kind: .sail, prompt: "Look", model: S.model, sessionID: "s")
        let attached = try ImageDelivery.attaching([file], to: plain, kind: .sail, prompt: "Look")
        #expect(attached.arguments == ["--session-id", "s", "--resume", "--model", S.model, "--image", file.path, "--", "Look"])
        let options = try SailCommand.parse(attached.arguments)
        #expect(options.images == [file.path] && options.prompt == "Look")
    }

    @Test func everyEventSurvivesItsLine() {
        let events: [SailEvent] = [
            .session("s"), .model("m"), .flex(row: "k", detail: "Queued", state: .waiting), .flex(row: "k", detail: "Done", state: .done),
            .flex(row: "k", detail: "x", state: .failed), .flex(row: "k", detail: "y", state: .detached), .text("Hello\nthere"),
            .toolStarted(id: "c", name: "bash", arguments: ["command": "ls"]),
            .toolFinished(id: "c", name: "bash", output: "a", isError: false, exitCode: 0),
            .toolFinished(id: "d", name: "read", output: "b", isError: true, exitCode: nil), .failed("No"), .finished,
        ]
        for event in events {
            #expect(!event.line.contains("\n"))
            #expect(SailEvent(line: event.line) == event)
        }
        #expect(SailEvent(line: "warning: something") == nil)
        #expect(SailEvent(line: #"{"type":"later"}"#) == nil)
    }

    @Test func theParserShowsQueuedWorkAsARowAndToolsAsPisAre() {
        var parser = StreamParsers.make(for: .sail)
        let lines = [
            SailEvent.flex(row: "k1", detail: "Submitting to Sail Flex · m", state: .waiting),
            .flex(row: "k1", detail: "Queued on Sail Flex · resp_1 · m", state: .waiting),
            .session("s1"),
            .flex(row: "k1", detail: "Completed on Sail Flex · resp_1 · 4 min", state: .done),
            .model("m-2026"),
            .text("Running ls."),
            .toolStarted(id: "call_1", name: "bash", arguments: ["command": "ls"]),
            .toolFinished(id: "call_1", name: "bash", output: "a.txt\n", isError: false, exitCode: 0),
            .flex(row: "k2", detail: "Cancelled by Sail · resp_2", state: .failed),
            .failed("Sail cancelled response resp_2."),
        ].map(\.line) + ["not json"]
        #expect(lines.flatMap { parser.parse(line: $0) } == [
            .toolStarted(id: "k1", name: "Sail Flex", input: "Submitting to Sail Flex · m"),
            .toolStarted(id: "k1", name: "Sail Flex", input: "Queued on Sail Flex · resp_1 · m"),
            .session("s1"),
            .toolStarted(id: "k1", name: "Sail Flex", input: "Completed on Sail Flex · resp_1 · 4 min"),
            .toolFinished(id: "k1", name: "Sail Flex", output: "Completed on Sail Flex · resp_1 · 4 min", isError: false),
            .model("m-2026"),
            .text("Running ls."),
            .toolStarted(id: "call_1", name: "bash", input: "ls", arguments: #"{"command":"ls"}"#),
            .toolFinished(id: "call_1", name: "bash", output: "a.txt\n", isError: false, exitCode: 0),
            .toolStarted(id: "k2", name: "Sail Flex", input: "Cancelled by Sail · resp_2"),
            .toolFinished(id: "k2", name: "Sail Flex", output: "Cancelled by Sail · resp_2", isError: true),
            .failed("Sail cancelled response resp_2."),
        ])
        // One row per submission, reading as how it ended.
        var assembler = ThreadAssembler()
        var messages: [ChatMessage] = []
        var again = StreamParsers.make(for: .sail)
        for line in lines { for event in again.parse(line: line) { assembler.apply(event, to: &messages) } }
        let rows = messages.filter { $0.toolName == "Sail Flex" }
        #expect(rows.map(\.toolInput) == ["Completed on Sail Flex · resp_1 · 4 min", "Cancelled by Sail · resp_2"])
        #expect(rows.map(\.toolState) == [.done, .failed])
    }

    @Test func instructionsCarryTheFoldersAgentsFiles() throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        try "Root rules".write(to: harness.root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "Bot rules".write(to: harness.work.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "@AGENTS.md".write(to: harness.work.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        let text = SailInstructions.make(directory: harness.work, date: S.start)
        #expect(text.contains("You work in \(harness.work.path)"))
        #expect(text.contains("Today is ") && text.contains(" January 2027."))
        let root = try #require(text.range(of: "Root rules"))
        let bot = try #require(text.range(of: "Bot rules"))
        #expect(root.lowerBound < bot.lowerBound, "Outermost first")
        #expect(!text.contains("@AGENTS.md"), "CLAUDE.md is read only where there's no AGENTS.md")
    }

    @Test func sailRunsOnThisMacWithAKey() {
        #expect(SailLaunch.problem(remote: false, key: S.key) == nil)
        #expect(SailLaunch.problem(remote: false, key: " ") == "Add your Sail API key in BotChu ▸ Settings ▸ Sail first.")
        #expect(SailLaunch.problem(remote: false, key: nil) != nil)
        #expect(SailLaunch.problem(remote: true, key: S.key)?.contains("This Mac only") == true)
    }

    @Test func theHelperIsFoundBesideTheApp() {
        #expect(Sail.helperCommand(besides: URL(fileURLWithPath: "/Applications/Bot Chu.app/Contents/MacOS/BotChu"))
                == "'/Applications/Bot Chu.app/Contents/MacOS/botchu-sail'")
        #expect(Sail.helperCommand(besides: nil) == "botchu-sail")
        #expect(Accounts.account(id: "sail").kind == .sail)
        #expect(AgentKind.profileFamilies == [.claude, .codex, .antigravity, .muse, .pi])
    }

    @Test func modelsComeFromSettingsUnlessTheConversationChoosesOne() {
        #expect(GenerationOptions.effectiveModel("", kind: .sail, openRouterDefault: "or/model", sailDefault: " sail/model ") == "sail/model")
        #expect(GenerationOptions.effectiveModel("own/model", kind: .sail, openRouterDefault: "", sailDefault: "sail/model") == "own/model")
        #expect(GenerationOptions.effectiveModel("", kind: .sail, openRouterDefault: "or/model") == "")
        #expect(GenerationOptions.effectiveModel("", kind: .pi, openRouterDefault: "or/model", sailDefault: "sail/model") == "or/model")
        let picker = ModelPickerData(kind: .sail, model: "", openRouterDefault: "or/model")
        #expect(picker.title == "Default from Settings")
        #expect(picker.choices.first?.title == "Use default from Settings")
        #expect(GenerationOptions.efforts(for: .sail, model: "any") == [.low, .medium, .high])
    }

    @Test func usageIsNeverInferred() async {
        do {
            _ = try await ProviderUsageClient.read(UsageRequest(account: Accounts.account(id: "sail"), command: "botchu-sail"), openRouterKey: "or-key")
            Issue.record("Sail has no usage reading")
        } catch {
            #expect((error as? UsageFailure)?.message.contains("dashboard") == true)
        }
    }
}

@Suite struct SailTurnUsageTests {
    @Test func capturedResponseKeepsOptionalDetailsAndRoundTripsEvent() throws {
        let response = try SailResponse.parse(Data(SailSamples.capturedUsage.utf8))
        #expect(response.cachedInputTokens == 0)
        #expect(response.reasoningTokens == 13)
        let usage = try #require(response.turnUsage)
        #expect(usage == TurnUsage(models: [ModelUsage(model: "deepseek-ai/DeepSeek-V4.1-Flash-1017",
            uncachedInput: 38, cacheRead: 0, output: 18, reasoning: 13)]))
        let event = SailEvent.usage(usage)
        #expect(SailEvent(line: event.line) == event)
        var parser = SailParser()
        #expect(parser.parse(line: event.line) == [.usage(usage)])
        #expect(SailResponse(id: "empty", status: .completed).turnUsage == nil)
        #expect(SailResponse(id: "negative", status: .completed, inputTokens: -1, outputTokens: -2, cachedInputTokens: -3, reasoningTokens: -4).turnUsage == nil)
        #expect(SailResponse(id: "cached", status: .completed, inputTokens: 100, outputTokens: 20,
                            cachedInputTokens: 80, reasoningTokens: 15).turnUsage?.models.first?.uncachedInput == 20)
    }

    @Test func multipleResponsesEmitOneTotalIncludingFailure() async throws {
        for fails in [false, true] {
            let harness = try SailHarness()
            defer { harness.remove() }
            let first = SailSamples.response("r1", "completed", output: "[\(SailSamples.message("I will continue:"))]", extra: SailSamples.usage)
            let second = SailSamples.response("r2", fails ? "failed" : "completed", output: "[\(SailSamples.message("Done."))]", extra: SailSamples.usage)
            let fixture = SailFixture([("POST", "/v1/responses", .ok(first)), ("POST", "/v1/responses", .ok(second))])
            let ok = await harness.run(fixture, .init(sessionID: "s", resume: false, model: SailSamples.model, prompt: "Go"))
            #expect(ok == !fails)
            let usages = harness.events.all.compactMap { if case .usage(let usage) = $0 { usage } else { nil } }
            #expect(usages == [TurnUsage(models: [ModelUsage(model: SailSamples.model, uncachedInput: 2400, output: 68)])])
            #expect(harness.events.all.dropLast().last == .usage(usages[0]))
        }
    }
}
