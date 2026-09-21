import AgentreDomain
import Testing

/// 提及的候选与正文序列化，规则对齐宿主 chat-input/mentions 的 xml.ts / rank-items.ts；
/// 候选的来路对齐控制台 SessionComposer：Agent 与账号设备，不摆项目（服务端响应里没有路径）。
@Suite("提及")
struct MentionTests {
    let sources = ComposerMentionSources(
        agents: [ComposerMentionAgent(id: 7, name: "reviewer"), ComposerMentionAgent(id: 8, name: "writer")],
        devices: [ComposerMentionDevice(fingerprint: "fp-r", name: "rack", online: true), ComposerMentionDevice(fingerprint: "", name: "ghost", online: true)]
    )

    @Test("候选按 Agent 在前、设备在后分组排序；没有指纹的设备整条不列")
    func rank() {
        #expect(ComposerMentions.rank(sources, query: "r").map(\.label) == ["reviewer", "writer", "rack"])
        #expect(ComposerMentions.rank(sources, query: "").map(\.label) == ["reviewer", "writer", "rack"])
        #expect(ComposerMentions.rank(sources, query: "ra").map(\.label) == ["rack"])
    }

    @Test("序列化：Agent 存 id，设备只存指纹；标签与属性转义")
    func xml() {
        #expect(MentionRef.agent(id: 7, name: "a<b>").xml == #"<agent id="7">a&lt;b&gt;</agent>"#)
        #expect(MentionRef.device(fingerprint: #"f"p"#, name: "rack & co").xml == #"<device fp="f&quot;p">rack &amp; co</device>"#)
    }

    @Test("发送时把正文里的 @名字 换成提及 XML：每个提及只换一处，删掉了的提及不换")
    func serialize() {
        let refs: [MentionRef] = [.agent(id: 7, name: "reviewer"), .device(fingerprint: "fp-r", name: "rack")]
        #expect(ComposerMentions.serialize("@reviewer 看一下 @reviewer", mentions: refs)
            == #"<agent id="7">reviewer</agent> 看一下 @reviewer"#)
        #expect(ComposerMentions.serialize("看 @rack", mentions: refs) == #"看 <device fp="fp-r">rack</device>"#)
    }

    @Test("只呈现纯文本的地方：提及 XML 还原成 @名字")
    func display() {
        #expect(ComposerMentions.displayText(#"请 <agent id="7">a&amp;b</agent> 看 <device fp="x">rack</device>"#) == "请 @a&b 看 @rack")
    }
}
