import AgentreDomain
import AgentreRelay
import AgentreWire
import Foundation
import SwiftProtobuf
import Testing

private let key = ConversationKey(machineFingerprint: "origin-fp", conversationID: "conv-1")

@Suite struct ApprovalAdapterTests {
    @Test("工具权限三档：经承载机的 machine: 通道发 runtimeSubmitToolPermission，allow / always_allow_session 按档位", arguments: PermissionDisposition.allCases)
    func submitsToolPermission(_ disposition: PermissionDisposition) async throws {
        let harness = await Harness.started()
        let adapter = RelayApprovalAnswering(connection: harness.connection, carrier: { _ in "carrier-fp" })
        let reply = ToolPermissionReply(conversation: key, peerFingerprint: "peer-1", requestID: "r1", disposition: disposition)
        async let sent = adapter.submitToolPermission(reply)
        let (socket, id) = try await harness.machineChannel("carrier-fp")
        let request = try await socket.nextRequest(on: id, method: .runtimeSubmitToolPermission)
        let body = try request.body(Agentre_Wire_RuntimeSubmitToolPermissionRequest.self)
        #expect(body.conversationID == "conv-1")
        #expect(body.peerFingerprint == "peer-1")
        #expect(body.requestID == "r1")
        #expect(body.allow == disposition.allow)
        #expect(body.alwaysAllowSession == disposition.alwaysAllowSession)
        #expect(body.denyReason.isEmpty)
        socket.respond(id, to: request, with: Agentre_Wire_PeerSessionControlResponse())
        #expect(try await sent == .accepted)
    }

    @Test("已被别处处理过的一问照样算送达（不是失败），但如实报出「别的端先答了」：结局不是本机这一答")
    func alreadyHandledIsDelivered() async throws {
        let harness = await Harness.started()
        let adapter = RelayApprovalAnswering(connection: harness.connection)
        async let sent = adapter.submitToolPermission(
            ToolPermissionReply(conversation: key, peerFingerprint: "", requestID: "r1", disposition: .reject)
        )
        let (socket, id) = try await harness.machineChannel("origin-fp")
        let request = try await socket.nextRequest(on: id, method: .runtimeSubmitToolPermission)
        var response = Agentre_Wire_PeerSessionControlResponse()
        response.alreadyHandled = true
        socket.respond(id, to: request, with: response)
        #expect(try await sent == .alreadyHandled)
    }

    @Test("提问作答同样如实报出 already_handled")
    func answerAlreadyHandled() async throws {
        let harness = await Harness.started()
        let adapter = RelayApprovalAnswering(connection: harness.connection)
        async let sent = adapter.submitAnswer(QuestionReply(
            conversation: key, peerFingerprint: "", requestID: "q1", questions: ["Which DB?"], answers: [], skipped: true
        ))
        let (socket, id) = try await harness.machineChannel("origin-fp")
        let request = try await socket.nextRequest(on: id, method: .runtimeSubmitAnswer)
        var response = Agentre_Wire_PeerSessionControlResponse()
        response.alreadyHandled = true
        socket.respond(id, to: request, with: response)
        #expect(try await sent == .alreadyHandled)
    }

    @Test("提问作答：问题原文、每问的标签与自填、跳过标志逐格带上")
    func submitsAnswer() async throws {
        let harness = await Harness.started()
        let adapter = RelayApprovalAnswering(connection: harness.connection, carrier: { _ in "carrier-fp" })
        let reply = QuestionReply(
            conversation: key, peerFingerprint: "peer-1", requestID: "q1", questions: ["Which DB?", "Why?"],
            answers: [
                QuestionAnswer(questionIndex: 0, labels: ["Postgres"], otherText: ""),
                QuestionAnswer(questionIndex: 1, labels: [QuestionAnswer.otherLabel], otherText: "speed"),
            ],
            skipped: false
        )
        async let sent = adapter.submitAnswer(reply)
        let (socket, id) = try await harness.machineChannel("carrier-fp")
        let request = try await socket.nextRequest(on: id, method: .runtimeSubmitAnswer)
        let body = try request.body(Agentre_Wire_RuntimeSubmitAnswerRequest.self)
        #expect(body.conversationID == "conv-1")
        #expect(body.peerFingerprint == "peer-1")
        #expect(body.requestID == "q1")
        #expect(body.questions.map(\.question) == ["Which DB?", "Why?"])
        #expect(body.answers.map(\.questionIndex) == [0, 1])
        #expect(body.answers.map(\.labels) == [["Postgres"], ["__other__"]])
        #expect(body.answers.map(\.otherText) == ["", "speed"])
        #expect(!body.skipped)
        socket.respond(id, to: request, with: Agentre_Wire_PeerSessionControlResponse())
        #expect(try await sent == .accepted)
    }

    @Test("跳过：answers 为空、skipped 为真")
    func skipsQuestion() async throws {
        let harness = await Harness.started()
        let adapter = RelayApprovalAnswering(connection: harness.connection)
        async let sent = adapter.submitAnswer(QuestionReply(
            conversation: key, peerFingerprint: "", requestID: "q1", questions: ["Which DB?"], answers: [], skipped: true
        ))
        let (socket, id) = try await harness.machineChannel("origin-fp")
        let request = try await socket.nextRequest(on: id, method: .runtimeSubmitAnswer)
        let body = try request.body(Agentre_Wire_RuntimeSubmitAnswerRequest.self)
        #expect(body.skipped)
        #expect(body.answers.isEmpty)
        socket.respond(id, to: request, with: Agentre_Wire_PeerSessionControlResponse())
        #expect(try await sent == .accepted)
    }

    @Test("错误应答与到期无应答都以领域失败收场（抛错即没送达）", arguments: FailureScenario.allCases)
    func failuresAreDomainFacts(_ scenario: FailureScenario) async throws {
        let permission = try await failure(scenario, method: .runtimeSubmitToolPermission, on: "origin-fp") { harness in
            try await RelayApprovalAnswering(connection: harness.connection).submitToolPermission(
                ToolPermissionReply(conversation: key, peerFingerprint: "", requestID: "r1", disposition: .allowOnce)
            )
        }
        #expect(permission as? RelayFailure == scenario.expected)
        let answer = try await failure(scenario, method: .runtimeSubmitAnswer, on: "origin-fp") { harness in
            try await RelayApprovalAnswering(connection: harness.connection).submitAnswer(
                QuestionReply(conversation: key, peerFingerprint: "", requestID: "q1", questions: [], answers: [], skipped: true)
            )
        }
        #expect(answer as? RelayFailure == scenario.expected)
    }
}
