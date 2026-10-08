import AgentreDomain
import Testing

/// 「平台 · 种类 版本」按上报原样、缺哪项不写哪项（规格「06」「08」，机器详情导航栏副标题与机器卡片共用）。
@Suite("机器：上报的平台摘要")
struct MachineReportedSummaryTests {
    private func machine(platform: String = "", kind: String = "", version: String = "") -> Machine {
        Machine(id: 1, fingerprint: "fp", name: "m", kind: kind, platform: platform, version: version, online: true)
    }

    @Test("三项都报了：平台 · 种类 版本")
    func allThree() {
        #expect(machine(platform: "darwin/arm64", kind: "desktop", version: "0.9.2").reportedSummary == "darwin/arm64 · desktop 0.9.2")
    }

    @Test("agentred 只报系统、不报架构：原样呈现，不臆造架构")
    func agentredWithoutArch() {
        #expect(machine(platform: "linux", kind: "agentred", version: "0.9.2").reportedSummary == "linux · agentred 0.9.2")
    }

    @Test("缺哪项就不写哪项，不留多余的分隔符")
    func omitsMissingParts() {
        #expect(machine(platform: "darwin", kind: "", version: "").reportedSummary == "darwin")
        #expect(machine(platform: "", kind: "agentred", version: "0.9.2").reportedSummary == "agentred 0.9.2")
        #expect(machine(platform: "", kind: "", version: "").reportedSummary == nil)
    }
}
