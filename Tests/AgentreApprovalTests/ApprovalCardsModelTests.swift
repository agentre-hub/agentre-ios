import AgentreDomain
@testable import AgentreUI
import Testing

/// 作答经端口发出、送达后落定；没送达如实呈现。
@MainActor
@Suite("审批与提问的作答")
struct ApprovalCardsModelTests {
    let port = FakeAnswering()

    var model: ApprovalCardsModel { ApprovalCardsModel(conversation: savedConversation, answering: port) }

    @Test("三档处置依次映射到 allow / always_allow_session，请求带会话身份与发起端指纹", arguments: [
        (PermissionDisposition.reject, false, false, ApprovalPermissionState.denied),
        (.allowForSession, true, true, .allowedForSession),
        (.allowOnce, true, false, .allowed),
    ])
    func dispositionsGoThroughThePort(disposition: PermissionDisposition, allow: Bool, always: Bool, settled: ApprovalPermissionState) async {
        let cards = model
        let request = permission()
        await cards.submit(disposition, for: request)
        let sent = await port.permissions
        #expect(sent == [ToolPermissionReply(conversation: conversationKey, peerFingerprint: "peer-1", requestID: "p1", disposition: disposition)])
        #expect(sent.first?.disposition.allow == allow)
        #expect(sent.first?.disposition.alwaysAllowSession == always)
        #expect(cards.state(of: request) == settled)
    }

    @Test("送达之前不落定、也不收第二次作答")
    func settlesOnlyAfterDelivery() async throws {
        let cards = model
        let request = permission()
        await port.hold()
        let first = Task { await cards.submit(.allowOnce, for: request) }
        try await eventually("作答发出") { await port.permissions.count == 1 }
        #expect(cards.state(of: request) == .open(submitting: true, failed: false))
        await cards.submit(.reject, for: request)
        await port.release()
        await first.value
        #expect(await port.permissions.count == 1)
        #expect(cards.state(of: request) == .allowed)
    }

    @Test("没送达：卡片回到待处置并标出提交失败，可以再点")
    func failedSubmitIsShown() async {
        let cards = model
        let request = permission()
        await port.setFailing(true)
        await cards.submit(.allowOnce, for: request)
        #expect(cards.state(of: request) == .open(submitting: false, failed: true))
        await port.setFailing(false)
        await cards.submit(.allowForSession, for: request)
        #expect(cards.state(of: request) == .allowedForSession)
        #expect(await port.permissions.count == 2)
    }

    @Test("转录里已落定的请求照转录呈现，不能再作答")
    func resolvedInTranscript() async {
        let cards = model
        #expect(cards.state(of: permission(resolved: true, allowed: true)) == .allowed)
        #expect(cards.state(of: permission(resolved: true, allowed: false)) == .denied)
        await cards.submit(.allowOnce, for: permission(resolved: true, allowed: false))
        #expect(await port.permissions.isEmpty)
        // 本机点的是本会话始终允许，转录随后报本会话始终允许：落定为「已允许(本会话)」。
        await cards.submit(.allowForSession, for: permission("p2"))
        #expect(cards.state(of: permission("p2", resolved: true, allowed: true, alwaysAllow: true)) == .allowedForSession)
    }

    @Test("别的端先答了：本机这一答不当结局，卡片等转录里的决议；决议到了照决议落定")
    func alreadyHandledWaitsForTheTranscript() async {
        let cards = model
        await port.setHandledElsewhere(true)
        await cards.submit(.allowOnce, for: permission())
        #expect(cards.state(of: permission()) == .open(submitting: true, failed: false))
        #expect(cards.state(of: permission(resolved: true, allowed: false)) == .denied)

        let asked = question()
        await cards.skip(asked)
        #expect(cards.state(of: asked) == .open(submitting: true))
        #expect(cards.state(of: question(answered: true)) == .answered)
    }

    @Test("转录报的是本会话始终允许：即使本机没点过也落定为「已允许(本会话)」")
    func transcriptAlwaysAllow() {
        #expect(model.state(of: permission(resolved: true, allowed: true, alwaysAllow: true)) == .allowedForSession)
    }

    @Test("本机点的是本会话始终允许、转录报的是仅本次允许：照转录落定为「已允许」")
    func transcriptOutcomeWinsOverLocalTap() async {
        let cards = model
        await cards.submit(.allowForSession, for: permission("p2"))
        #expect(cards.state(of: permission("p2", resolved: true, allowed: true)) == .allowed)
    }

    @Test("没有请求 id 的卡片不作答：不发出空的 request_id，也不与别的无 id 卡片共用状态")
    func emptyRequestIDIsNotSubmitted() async {
        let cards = model
        await cards.submit(.allowOnce, for: permission(""))
        #expect(await port.permissions.isEmpty)
        #expect(cards.state(of: permission("")) == .open(submitting: false, failed: false))
        let asked = question("")
        cards.setAnswer("main", at: 0, of: asked)
        await cards.submitAnswers(for: asked)
        await cards.skip(asked)
        #expect(await port.answers.isEmpty)
        #expect(cards.state(of: asked) == .open(submitting: false))
    }

    @Test("提问：每一问都填了才能提交；答案以自填标签发出，送达后为已回答")
    func answerQuestion() async {
        let cards = model
        let request = question("q1", ["用哪个分支？", "要不要跑 e2e？"])
        cards.setAnswer("main", at: 0, of: request)
        cards.setAnswer("   ", at: 1, of: request)
        await cards.submitAnswers(for: request)
        #expect(await port.answers.isEmpty)
        #expect(cards.inputError(of: request) != nil)
        cards.setAnswer("要", at: 1, of: request)
        #expect(cards.answer(0, of: request) == "main")
        await cards.submitAnswers(for: request)
        #expect(await port.answers == [QuestionReply(
            conversation: conversationKey, peerFingerprint: "peer-1", requestID: "q1",
            questions: ["用哪个分支？", "要不要跑 e2e？"],
            answers: [
                QuestionAnswer(questionIndex: 0, labels: [QuestionAnswer.otherLabel], otherText: "main"),
                QuestionAnswer(questionIndex: 1, labels: [QuestionAnswer.otherLabel], otherText: "要"),
            ],
            skipped: false
        )])
        #expect(cards.state(of: request) == .answered)
    }

    @Test("提问：没填完不发；跳过发出空答案；转录报已回答即为已回答")
    func skipAndIncomplete() async {
        let cards = model
        let request = question()
        await cards.submitAnswers(for: request)
        #expect(await port.answers.isEmpty)
        await cards.skip(request)
        #expect(await port.answers.map(\.skipped) == [true])
        #expect(await port.answers.first?.answers == [])
        #expect(cards.state(of: request) == .skipped)
        #expect(cards.state(of: question("q9", answered: true)) == .answered)
    }

    @Test("提问：没送达即失效，不再作答")
    func failedAnswerExpires() async {
        let cards = model
        let request = question()
        cards.setAnswer("main", at: 0, of: request)
        await port.setFailing(true)
        await cards.submitAnswers(for: request)
        #expect(cards.state(of: request) == .expired)
        await cards.skip(request)
        #expect(await port.answers.count == 1)
    }

    @Test("单选：点一个即选它、点另一个即换成它、再点已选的即取消")
    func singleSelect() {
        let cards = model
        let request = optionQuestion()
        cards.toggleOption("main", at: 0, of: request)
        #expect(cards.selectedLabels(0, of: request) == ["main"])
        cards.toggleOption("dev", at: 0, of: request)
        #expect(cards.selectedLabels(0, of: request) == ["dev"])
        cards.toggleOption("dev", at: 0, of: request)
        #expect(cards.selectedLabels(0, of: request).isEmpty)
    }

    @Test("多选：逐个加入、按点选次序排列，再点即移出")
    func multiSelect() {
        let cards = model
        let request = optionQuestion(multi: true)
        cards.toggleOption("test", at: 1, of: request)
        cards.toggleOption("lint", at: 1, of: request)
        #expect(cards.selectedLabels(1, of: request) == ["test", "lint"])
        cards.toggleOption("test", at: 1, of: request)
        #expect(cards.selectedLabels(1, of: request) == ["lint"])
        #expect(cards.selectedLabels(0, of: request).isEmpty, "两问各记各的")
    }

    @Test("自定义答案：填了字即选中自定义（单选时顶替已选的选项），清空即取消")
    func customAnswer() {
        let cards = model
        let request = optionQuestion(multi: true)
        cards.toggleOption("main", at: 0, of: request)
        cards.setAnswer("release", at: 0, of: request)
        #expect(cards.selectedLabels(0, of: request) == [QuestionAnswer.otherLabel])
        cards.setAnswer("", at: 0, of: request)
        #expect(cards.selectedLabels(0, of: request).isEmpty)

        cards.toggleOption("lint", at: 1, of: request)
        cards.setAnswer("typecheck", at: 1, of: request)
        #expect(cards.selectedLabels(1, of: request) == ["lint", QuestionAnswer.otherLabel])
    }

    @Test("提交前逐问核对：一问没选即「请先选择一个选项」，选了自定义却没填字即「请填写自定义答案」；都不发出")
    func submitValidation() async {
        let cards = model
        let request = optionQuestion(multi: true)
        cards.toggleOption("main", at: 0, of: request)
        await cards.submitAnswers(for: request)
        #expect(cards.inputError(of: request) == .optionRequired)

        cards.setAnswer("   ", at: 1, of: request)
        await cards.submitAnswers(for: request)
        #expect(cards.inputError(of: request) == .otherRequired)
        #expect(await port.answers.isEmpty)
        #expect(cards.state(of: request) == .open(submitting: false))
    }

    @Test("选中的 label 经作答端口发出：每问一条、按问题次序，自定义答案带上填的字")
    func selectedLabelsGoThroughThePort() async {
        let cards = model
        let request = optionQuestion(multi: true)
        cards.toggleOption("dev", at: 0, of: request)
        cards.toggleOption("e2e", at: 1, of: request)
        cards.setAnswer("typecheck", at: 1, of: request)
        await cards.submitAnswers(for: optionQuestion(multi: true))
        #expect(cards.inputError(of: request) == nil)
        #expect(await port.answers == [QuestionReply(
            conversation: conversationKey, peerFingerprint: "peer-1", requestID: "q1",
            questions: ["用哪个分支？", "跑哪些检查？"],
            answers: [
                QuestionAnswer(questionIndex: 0, labels: ["dev"], otherText: ""),
                QuestionAnswer(questionIndex: 1, labels: ["e2e", QuestionAnswer.otherLabel], otherText: "typecheck"),
            ],
            skipped: false
        )])
        #expect(cards.state(of: request) == .answered)
    }

    @Test("核对不过之后改对再提交：报错消失并发出")
    func errorClearsOnValidSubmit() async {
        let cards = model
        let request = optionQuestion()
        await cards.submitAnswers(for: request)
        #expect(cards.inputError(of: request) == .optionRequired)
        cards.toggleOption("main", at: 0, of: request)
        await cards.submitAnswers(for: request)
        #expect(cards.inputError(of: request) == nil)
        #expect(await port.answers.map(\.answers) == [[QuestionAnswer(questionIndex: 0, labels: ["main"], otherText: "")]])
    }

    @Test("长输入默认收起，逐张展开、收起")
    func expansion() {
        let cards = model
        #expect(!cards.isExpanded("p1"))
        cards.toggleExpanded("p1")
        #expect(cards.isExpanded("p1") && !cards.isExpanded("p2"))
        cards.toggleExpanded("p1")
        #expect(!cards.isExpanded("p1"))
    }
}
