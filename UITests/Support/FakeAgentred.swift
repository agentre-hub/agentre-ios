import AgentreWire
import Foundation
import SwiftProtobuf

/// 伪 agentred：一台机器上的会话清单与每条会话的持久帧，按 wire 方法作答。
///
/// 行为照搬已核实的 agentred，而不是「什么都接」——凡与真实对端不同的地方都是一条会被盖住的缺陷：
/// - 会话只在一轮跑着时登记在内存表里：runtime.run 登记，一轮收场即摘掉；不在表里时
///   runtime.setPermissionMode 回「没有进行中的一轮」（-32010，agentre/internal/daemon/handlers/runtime.go:1454-1462、:1682-1689）。
/// - runtime.run 带上的 permission_mode 原样记下可查（RuntimeRunRequest 字段 16）。
/// - runtime.run 先发不带号的 turn_started，再落用户那一帧（带号），然后才回应答；此后的事件由
///   这一轮自己陆续产出（runtime.go:578-590）。一轮收场先落带号的 done（runtime_transcript.go 的 finish），
///   再发不带号、补拉不回来的 run_result_done。
/// - 实时帧只推给 attach 过（或发起了这一轮）的通道；断开的通道收不到，回来后按游标 pull。
///
/// 一切调用都在服务端的 `queue` 上。
final class FakeAgentred: @unchecked Sendable {
    static let protocolVersion = "0.3.0"
    static let boxName = "uitest-box"
    static let boxFingerprint = "fp-uitest-box"

    enum Reply {
        case result(any SwiftProtobuf.Message)
        case error(Int32, String)
    }

    /// 下一轮 runtime.run 之后机器做什么。
    enum TurnPlan {
        /// 要跑一条命令：先报工具调用与权限请求，等人作答；允许后给出结果与一句回复、收场。
        case askPermission(command: String, output: String, reply: String)
        /// 这一轮一直跑着，直到测试调 `completeHeldTurn`。
        case hold
    }

    struct Session {
        var summary: Agentre_Wire_SessionSummary
        var frames: [Agentre_Wire_DurableNotification] = []
    }

    let fingerprint: String
    let name: String
    let deviceID: Int64
    var queue: DispatchQueue!

    private var sessions: [String: Session] = [:]
    private var activeTurns: Set<String> = []
    private var subscribers: [String: Set<RelayPeer>] = [:]
    private var pendingPermissions: [String: (requestID: String, callID: String, output: String, reply: String)] = [:]
    private var heldTurns: [String] = []
    private var planQueue: [TurnPlan] = []

    private(set) var runs: [Agentre_Wire_RuntimeRunRequest] = []
    private(set) var permissionModeCalls: [Agentre_Wire_RuntimeSetPermissionModeRequest] = []
    private(set) var permissionReplies: [Agentre_Wire_RuntimeSubmitToolPermissionRequest] = []
    private(set) var unhandledMethods: [String] = []

    init(fingerprint: String = FakeAgentred.boxFingerprint, name: String = FakeAgentred.boxName, deviceID: Int64 = 10) {
        self.fingerprint = fingerprint
        self.name = name
        self.deviceID = deviceID
    }

    // MARK: 测试一侧（在 queue 上调用）

    /// 机器上已有的一条会话（别的端发起的），带一段历史。
    func seed(conversationID: String, peerFingerprint: String, title: String, cwd: String, history: [(user: String, reply: String)]) {
        var summary = Agentre_Wire_SessionSummary()
        summary.conversationID = conversationID
        summary.peerFingerprint = peerFingerprint
        summary.title = title
        summary.cwd = cwd
        summary.backendType = "claudecode"
        summary.agentSyncID = FakeAgentreServer.agentSyncID
        summary.lifecycleState = "idle"
        sessions[conversationID] = Session(summary: summary)
        for turn in history {
            record(conversationID, .userMessage(Self.userMessage(turn.user, source: peerFingerprint)))
            record(conversationID, .textDelta(Self.text(turn.reply)))
        }
    }

    func plan(_ plans: TurnPlan...) {
        planQueue.append(contentsOf: plans)
    }

    /// 被 `.hold` 住的那一轮收场：回一句话、落一帧收场。
    func completeHeldTurn(reply: String) {
        guard !heldTurns.isEmpty else { return }
        let conversationID = heldTurns.removeFirst()
        record(conversationID, .textDelta(Self.text(reply)))
        finishTurn(conversationID)
    }

    // MARK: 通道一侧

    func forget(_ peer: RelayPeer) {
        for key in subscribers.keys { subscribers[key]?.remove(peer) }
    }

    func answer(_ method: Agentre_Wire_RpcMethod, _ payload: Data, from peer: RelayPeer) -> Reply {
        do {
            switch method {
            case .sessionList: return .result(list(try .init(serializedBytes: payload)))
            case .sessionCounts: return .result(counts())
            case .sessionAttach: return attach(try .init(serializedBytes: payload), from: peer)
            case .sessionPull: return pull(try .init(serializedBytes: payload))
            case .runtimeCapabilities: return .result(capabilities())
            case .runtimeRun: return run(try .init(serializedBytes: payload), from: peer)
            case .runtimeSubmitToolPermission: return submitPermission(try .init(serializedBytes: payload))
            case .runtimeSetPermissionMode: return setPermissionMode(try .init(serializedBytes: payload))
            case .runtimeDrainPending: return .result(Agentre_Wire_RuntimeDrainPendingResponse())
            case .skillsCommands: return .result(Agentre_Wire_SkillCommandsResponse())
            default:
                unhandledMethods.append("\(method)")
                return .error(-32601, "method not found")
            }
        } catch {
            return .error(-32602, "invalid params")
        }
    }

    private func list(_ request: Agentre_Wire_SessionListRequest) -> Agentre_Wire_SessionListResponse {
        let keyword = request.keyword.lowercased()
        let matching = sessions.values.map(\.summary)
            .filter { request.conversationIds.isEmpty || request.conversationIds.contains($0.conversationID) }
            .filter { keyword.isEmpty || $0.title.lowercased().contains(keyword) }
            .sorted { $0.lastMessageAt > $1.lastMessageAt }
        let offset = Int(request.cursor) ?? 0
        let limit = request.limit > 0 ? Int(request.limit) : 50
        let page = Array(matching.dropFirst(offset).prefix(limit))
        var response = Agentre_Wire_SessionListResponse()
        response.sessions = page
        response.hasMore_p = offset + page.count < matching.count
        response.cursor = response.hasMore_p ? String(offset + page.count) : ""
        response.total = Int64(matching.count)
        return response
    }

    private func counts() -> Agentre_Wire_SessionCountsResponse {
        var response = Agentre_Wire_SessionCountsResponse()
        let all = sessions.values.map(\.summary)
        response.total = Int64(all.count)
        response.running = Int64(all.count { $0.lifecycleState == "running" })
        response.waiting = Int64(all.count { $0.waitingForInput })
        return response
    }

    private func attach(_ request: Agentre_Wire_SessionAttachRequest, from peer: RelayPeer) -> Reply {
        guard let session = sessions[request.conversationID], owns(session, request.peerFingerprint, peer) else {
            return .error(-32014, "runtime: session not found")
        }
        subscribers[request.conversationID, default: []].insert(peer)
        var response = Agentre_Wire_SessionAttachResponse()
        response.conversationID = request.conversationID
        response.backendType = session.summary.backendType
        response.lifecycleState = session.summary.lifecycleState
        response.latestSeq = session.summary.latestSeq
        return .result(response)
    }

    private func pull(_ request: Agentre_Wire_SessionPullRequest) -> Reply {
        guard let session = sessions[request.conversationID] else { return .error(-32014, "runtime: session not found") }
        let limit = request.limit > 0 ? Int(request.limit) : 200
        let after = session.frames.filter { $0.seq > request.cursor }
        let page = Array(after.prefix(limit))
        var response = Agentre_Wire_SessionPullResponse()
        response.notifications = page
        response.cursor = page.last?.seq ?? request.cursor
        response.hasMore_p = after.count > page.count
        response.oldestSeq = session.frames.first?.seq ?? 0
        return .result(response)
    }

    private func capabilities() -> Agentre_Wire_RuntimeCapabilitiesResponse {
        var meta = Agentre_Wire_PermissionModeMeta()
        meta.allowedModes = ["default", "acceptEdits", "plan"]
        meta.defaultMode = "default"
        meta.switchableDuringTurn = true
        meta.order = meta.allowedModes
        meta.launchDefaultMode = "default"
        var response = Agentre_Wire_RuntimeCapabilitiesResponse()
        response.permissionMode = meta
        return response
    }

    private func run(_ request: Agentre_Wire_RuntimeRunRequest, from peer: RelayPeer) -> Reply {
        let id = request.conversationID
        guard !id.isEmpty else { return .error(-32602, "invalid params") }
        if let existing = sessions[id], !owns(existing, request.peerFingerprint, peer) {
            return .error(-32014, "runtime: session not found")
        }
        runs.append(request)
        if sessions[id] == nil {
            var summary = Agentre_Wire_SessionSummary()
            summary.conversationID = id
            // 发起端：请求点名的那台，否则就是这条通道的对端（devicefp.Initiator）。
            summary.peerFingerprint = request.peerFingerprint.isEmpty ? peer.fingerprint : request.peerFingerprint
            summary.title = request.title
            summary.cwd = request.cwd
            summary.agentSyncID = request.agentSyncID
            summary.projectSyncID = request.projectSyncID
            summary.backendType = request.backend.type
            sessions[id] = Session(summary: summary)
        }
        activeTurns.insert(id)
        sessions[id]?.summary.lifecycleState = "running"
        subscribers[id, default: []].insert(peer)
        var started = Agentre_Wire_RpcNotification()
        started.turnStarted = Agentre_Wire_TurnStartedNotification.with { $0.conversationID = id }
        broadcast(id, started)
        let userSeq = record(id, .userMessage(Self.userMessage(request.userText, source: request.sourceDevice, name: request.sourceDeviceName)))
        var response = Agentre_Wire_RuntimeRunResponse()
        response.conversationID = id
        response.userMessageSeq = userSeq
        response.userMessageMinSeq = userSeq
        // 这一轮的事件在应答之后才陆续到（fanout 是另一个协程）。
        let plan = planQueue.isEmpty ? TurnPlan.hold : planQueue.removeFirst()
        queue.async { [self] in begin(plan, in: id) }
        return .result(response)
    }

    private func begin(_ plan: TurnPlan, in conversationID: String) {
        switch plan {
        case .askPermission(let command, let output, let reply):
            let callID = "call-\(UUID().uuidString.prefix(8))"
            let requestID = "perm-\(UUID().uuidString.prefix(8))"
            let input = Data(#"{"command":"\#(command)"}"#.utf8)
            record(conversationID, .toolCall(.with { $0.id = callID; $0.name = "Bash"; $0.input = input }))
            record(conversationID, .toolPermissionRequest(.with {
                $0.requestID = requestID
                $0.toolCallID = callID
                $0.toolName = "Bash"
                $0.input = input
            }))
            sessions[conversationID]?.summary.waitingForInput = true
            pendingPermissions[conversationID] = (requestID, callID, output, reply)
        case .hold:
            heldTurns.append(conversationID)
        }
    }

    private func submitPermission(_ request: Agentre_Wire_RuntimeSubmitToolPermissionRequest) -> Reply {
        permissionReplies.append(request)
        let id = request.conversationID
        var response = Agentre_Wire_PeerSessionControlResponse()
        guard let pending = pendingPermissions[id], pending.requestID == request.requestID else {
            response.alreadyHandled = true
            return .result(response)
        }
        pendingPermissions[id] = nil
        sessions[id]?.summary.waitingForInput = false
        queue.async { [self] in
            record(id, .toolPermissionResolved(.with {
                $0.requestID = request.requestID
                $0.allowed = request.allow
                $0.alwaysAllow = request.alwaysAllowSession
            }))
            if request.allow {
                record(id, .toolResult(.with { $0.toolCallID = pending.callID; $0.content = pending.output }))
            }
            record(id, .textDelta(Self.text(pending.reply)))
            finishTurn(id)
        }
        return .result(response)
    }

    private func setPermissionMode(_ request: Agentre_Wire_RuntimeSetPermissionModeRequest) -> Reply {
        permissionModeCalls.append(request)
        guard activeTurns.contains(request.conversationID) else {
            return .error(-32010, "agentruntime: no active turn for session")
        }
        record(request.conversationID, .permissionModeChanged(.with { $0.mode = request.mode }))
        return .result(Agentre_Wire_Empty())
    }

    // MARK: 帧

    private func owns(_ session: Session, _ peerFingerprint: String, _ peer: RelayPeer) -> Bool {
        let initiator = peerFingerprint.isEmpty ? peer.fingerprint : peerFingerprint
        return session.summary.peerFingerprint == initiator
    }

    /// 落一帧持久帧（带号），并推给订阅了这条会话的通道。
    @discardableResult
    private func record(_ conversationID: String, _ event: Agentre_Wire_RuntimeEventNotification.OneOf_Event) -> Int64 {
        guard var session = sessions[conversationID] else { return 0 }
        let seq = (session.frames.last?.seq ?? 0) + 1
        var runtimeEvent = Agentre_Wire_RuntimeEventNotification()
        runtimeEvent.conversationID = conversationID
        runtimeEvent.seq = seq
        runtimeEvent.event = event
        var notification = Agentre_Wire_RpcNotification()
        notification.runtimeEvent = runtimeEvent
        var durable = Agentre_Wire_DurableNotification()
        durable.seq = seq
        durable.payload = notification
        durable.createtime = FakeAgentreServer.nowMillis
        session.frames.append(durable)
        session.summary.latestSeq = seq
        session.summary.lastMessageAt = durable.createtime
        sessions[conversationID] = session
        broadcast(conversationID, notification)
        return seq
    }

    /// 一轮收场：先落带号的 done（turnTranscript.finish 的 publishDurable），再发不带号的 run_result_done，
    /// 随后把会话从内存表里摘掉。
    private func finishTurn(_ conversationID: String) {
        record(conversationID, .done(.with { $0.durationMs = 1_800 }))
        var done = Agentre_Wire_RunResultDoneNotification()
        done.conversationID = conversationID
        done.durationMs = 1_800
        var notification = Agentre_Wire_RpcNotification()
        notification.runResultDone = done
        activeTurns.remove(conversationID)
        sessions[conversationID]?.summary.lifecycleState = "idle"
        sessions[conversationID]?.summary.waitingForInput = false
        broadcast(conversationID, notification)
    }

    private func broadcast(_ conversationID: String, _ notification: Agentre_Wire_RpcNotification) {
        for peer in subscribers[conversationID] ?? [] where !peer.isClosed { peer.push(notification) }
    }

    private static func userMessage(_ text: String, source: String, name: String = "") -> Agentre_Wire_UserMessage {
        .with {
            $0.text = text
            $0.sourceDevice = source
            $0.sourceDeviceName = name
        }
    }

    private static func text(_ text: String) -> Agentre_Wire_TextDelta {
        .with { $0.text = text }
    }
}
