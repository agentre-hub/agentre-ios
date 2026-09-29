import AgentreDomain
import Foundation
import Testing

/// 02 对话屏上的显示取值（规格「逐屏视觉契约·02 对话」与测试决策「显示取值」）：日期胶囊的分日与
/// 「今天 / 昨天」、组头耗时的「分:秒」、每步结果、回复署名、导航栏副标题取的状态。
@Suite("对话屏显示取值")
struct ConversationDisplayTests {
    static let shanghai: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    static func millis(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Int64 {
        let date = shanghai.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(millis) / 1000) }

    // MARK: 日期胶囊

    @Test("胶囊按本机日历的自然日判今天 / 昨天 / 更早：跨零点即换日，不按 24 小时算")
    func capsuleDay() {
        let now = Self.date(Self.millis(2026, 9, 29, 0, 20))
        #expect(CapsuleDay.of(Self.date(Self.millis(2026, 9, 29, 0, 5)), now: now, calendar: Self.shanghai) == .today)
        #expect(CapsuleDay.of(Self.date(Self.millis(2026, 9, 28, 23, 59)), now: now, calendar: Self.shanghai) == .yesterday)
        #expect(CapsuleDay.of(Self.date(Self.millis(2026, 9, 28, 0, 1)), now: now, calendar: Self.shanghai) == .yesterday)
        #expect(CapsuleDay.of(Self.date(Self.millis(2026, 9, 27, 23, 59)), now: now, calendar: Self.shanghai) == .earlier)
        // 源端时钟比本机快：写日期而不是「今天」。
        #expect(CapsuleDay.of(Self.date(Self.millis(2026, 9, 30, 9, 0)), now: now, calendar: Self.shanghai) == .earlier)
    }

    @Test("每个自然日的第一条消息前插一枚胶囊，写那条消息的时刻；时刻不知道（0）的消息既不插也不换日")
    func capsuleRows() {
        var doc = TranscriptDocument()
        doc.messages = [
            TranscriptMessage(id: "u1", role: .user, text: "昨晚", time: Self.millis(2026, 9, 28, 22, 0)),
            TranscriptMessage(id: "a1", role: .assistant, blocks: [.text("好")], time: Self.millis(2026, 9, 28, 23, 59)),
            TranscriptMessage(id: "u2", role: .user, text: "不知时刻"),
            TranscriptMessage(id: "u3", role: .user, text: "过了零点", time: Self.millis(2026, 9, 29, 0, 10)),
            TranscriptMessage(id: "a3", role: .assistant, blocks: [.text("嗯")], time: Self.millis(2026, 9, 29, 9, 32)),
        ]
        let rows = TranscriptRows.build(doc, calendar: Self.shanghai)
        let days = rows.compactMap { row -> (String, Int64)? in
            if case .day(let time) = row.content { return (row.id, time) }
            return nil
        }
        #expect(days.map(\.1) == [Self.millis(2026, 9, 28, 22, 0), Self.millis(2026, 9, 29, 0, 10)])
        let order = rows.map(\.id)
        #expect(order.firstIndex(of: days[0].0)! < order.firstIndex(of: "message:u1:user")!)
        #expect(order.firstIndex(of: days[1].0)! == order.firstIndex(of: "message:u3:user")! - 1)
    }

    @Test("消息的时刻取开启它的那一帧：归约时照帧带来的时刻落在消息上")
    func messageTimeFromOpeningFrame() {
        let doc = TranscriptReducer.reduce([
            TimelineEntry(anchor: "s1", event: .userMessage("跑一下"), time: 1_000),
            TimelineEntry(anchor: "s2", event: .turnStarted, time: 1_500),
            TimelineEntry(anchor: "s3", event: .textDelta("好"), time: 2_000),
            TimelineEntry(anchor: "s4", event: .textDelta("的"), time: 9_000),
        ])
        #expect(doc.messages.map(\.time) == [1_000, 2_000])
    }

    @Test("合流保留每一帧的时刻：带号帧与不带号的实时帧各带自己的")
    func timelineKeepsTime() {
        var timeline = TranscriptTimeline()
        timeline.insert(seq: 2, event: .textDelta("b"), time: 20)
        timeline.insert(seq: 1, event: .userMessage("a"), time: 10)
        timeline.insert(seq: nil, event: .turnStarted, time: 30)
        #expect(timeline.entries.map(\.time) == [10, 20, 30])
    }

    // MARK: 耗时

    @Test("组头与 Subagent 的耗时写成「分:秒」：秒补足两位，分钟不封顶；不足一秒的正数记一秒")
    func clockDuration() {
        #expect(ClockDuration.text(milliseconds: 107_000) == "1:47")
        #expect(ClockDuration.text(milliseconds: 9_000) == "0:09")
        #expect(ClockDuration.text(milliseconds: 158_400) == "2:38")
        #expect(ClockDuration.text(milliseconds: 6_600) == "0:07")
        #expect(ClockDuration.text(milliseconds: 3_725_000) == "62:05")
        #expect(ClockDuration.text(milliseconds: 300) == "0:01")
    }

    // MARK: 每步结果

    @Test("每步结果按工具种类：搜索形状「N 处」、读文件「N 行」、改文件「+N」；失败一律「失败」")
    func stepResults() {
        let grep = toolStep("g", use("g", "Grep", input: ["pattern": "seq", "path": "Tests/"]), result("g", "a.swift\nb.swift\n\nc.swift\n"))
        #expect(grep.facts().result == .matches(3))
        let read = toolStep("r", readUse("r"), result("r", "one line"))
        #expect(read.facts().result == .lines(1))
        let edit = toolStep("e", use("e", "Edit", input: ["file_path": "/repo/a.swift"], canonical: editCanonical([("/repo/a.swift", 38, 2)])), result("e"))
        #expect(edit.facts().result == .changed(plus: 38, minus: 2))
        let write = toolStep("w", use("w", "Write", input: ["file_path": "/repo/b.swift", "content": "x"],
                                       canonical: Canonical(kind: Canonical.Kind.fileWrite, fields: ["lines": 12])), result("w"))
        #expect(write.facts().result == .changed(plus: 12, minus: 0))
        let failedRead = toolStep("f", readUse("f"), result("f", "no such file", isError: true))
        #expect(failedRead.facts().result == .failed)
        let failedCommand = toolStep("c", use("c", input: ["command": "swift build"]), result("c", #"{"exitCode":1,"output":"a\nb"}"#))
        #expect(failedCommand.facts().result == .failed)
    }

    @Test("没有结构化结果的不写：成功的命令（「12 passed」只是原文）、认不出的工具、运行中的一步")
    func unstructuredResultsStayBlank() {
        let command = toolStep("c", use("c", input: ["command": "swift test"]), result("c", #"{"exitCode":0,"output":"12 passed"}"#))
        #expect(command.facts().result == nil)
        let mcp = toolStep("m", use("m", "mcp__pencil__execute", input: ["commands": "x"]), result("m", "done\nok"))
        #expect(mcp.facts().result == nil)
        let running = toolStep("r", readUse("r"))
        #expect(running.facts().result == nil)
        #expect(running.facts().pending == .running)
    }

    // MARK: 署名

    @Test("后端的显示名取宿主 shortLabel，表外取值原样")
    func backendShortLabel() {
        #expect(BackendLabel.short("claudecode") == "Claude Code")
        #expect(BackendLabel.short("codex") == "Codex")
        #expect(BackendLabel.short("hermes") == "Hermes")
        #expect(BackendLabel.short("piagent") == "Pi Agent")
        #expect(BackendLabel.short("openclaw") == "openclaw")
        #expect(BackendLabel.short("") == "")
    }

    @Test("收场时执行端报的模型落在这一轮的助手消息上")
    func turnModel() {
        let doc = TranscriptReducer.reduce([
            TimelineEntry(anchor: "s1", event: .userMessage("跑")),
            TimelineEntry(anchor: "s2", event: .textDelta("好")),
            TimelineEntry(anchor: "s3", event: .turnDone(TurnDone(durationMs: 1_000, model: "opus-5"))),
            TimelineEntry(anchor: "s4", event: .userMessage("再跑")),
            TimelineEntry(anchor: "s5", event: .textDelta("嗯")),
            TimelineEntry(anchor: "s6", event: .turnDone(TurnDone(durationMs: 1_000))),
        ])
        #expect(doc.messages.map(\.model) == ["", "opus-5", "", ""])
    }

    @Test("署名的模型：收场报的优先；运行中的这一轮取会话当前的模型；落定而没报过的不写")
    func signatureModel() {
        var doc = TranscriptDocument()
        doc.messages = [
            TranscriptMessage(id: "u1", role: .user, text: "一"),
            TranscriptMessage(id: "a1", role: .assistant, blocks: [.text("好")], model: "opus-5"),
            TranscriptMessage(id: "u2", role: .user, text: "二"),
            TranscriptMessage(id: "a2", role: .assistant, blocks: [.text("嗯")]),
            TranscriptMessage(id: "u3", role: .user, text: "三"),
            TranscriptMessage(id: "a3", role: .assistant, blocks: [.text("在跑")]),
        ]
        doc.running = true
        let models = TranscriptRows.build(doc, currentModel: "sonnet-5").compactMap { row -> String?? in
            if case .agentHeader(let model) = row.content { return .some(model) }
            return nil
        }
        #expect(models == ["opus-5", nil, "sonnet-5"])

        doc.running = false
        let settled = TranscriptRows.build(doc, currentModel: "sonnet-5").compactMap { row -> String?? in
            if case .agentHeader(let model) = row.content { return .some(model) }
            return nil
        }
        #expect(settled == ["opus-5", nil, nil])
    }

    // MARK: 导航栏副标题

    @Test("副标题取的状态：这一轮在跑且有没处置的审批或提问为等你回复；只在跑为正在输入；其余不算")
    func subtitleActivity() {
        var doc = TranscriptDocument()
        doc.messages = [TranscriptMessage(id: "a1", role: .assistant, blocks: [.text("好")])]
        #expect(doc.activity == .idle)
        doc.running = true
        #expect(doc.activity == .typing)

        let open = PermissionRequest(requestID: "p1", toolCallID: "", toolName: "Bash")
        doc.messages[0].blocks.append(.permission(open))
        #expect(doc.activity == .waiting)
        var resolved = open
        resolved.resolved = true
        doc.messages[0].blocks[1] = .permission(resolved)
        #expect(doc.activity == .typing)

        doc.messages[0].blocks.append(.question(QuestionRequest(requestID: "q1", toolCallID: "", questions: [])))
        #expect(doc.activity == .waiting)
        // 一轮已收场还挂着的请求不再有人等：不算等你回复。
        doc.running = false
        #expect(doc.activity == .idle)
    }
}
