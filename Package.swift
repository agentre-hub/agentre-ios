// swift-tools-version: 6.2
//
// AgentreKit 是 agentre-ios 的全部代码主体；应用目标（project.yml）只做装配。
//
// 本清单一次性声明全部 target 后冻结：后续任务只在各自目录内写，不改这里。
// 依赖方向由本清单结构性强制——一个 target 只能 import 这里为它声明过的模块：
//
//   AgentreDomain ← AgentreREST / AgentreRelay / AgentreStore（各自实现领域层的协议）
//   AgentreDomain + AgentreDesign ← AgentreUI（表现层看不见任何实现与 AgentreWire）
//
// 资源：每个功能在自己目录里带 <Feature>.xcstrings，SwiftPM 自动把字符串目录当资源处理，
// 所以新增一张表不需要改本清单。

import PackageDescription

let wire = Target.Dependency.product(name: "AgentreWire", package: "swift")

let libraries: [Target.Dependency] = [
    "AgentreDomain", "AgentreDesign", "AgentreREST", "AgentreRelay", "AgentreStore", "AgentreUI",
]

func testTarget(_ name: String, exclude: [String] = []) -> Target {
    .testTarget(name: name, dependencies: ["AgentreTestSupport", wire] + libraries, exclude: exclude)
}

let package = Package(
    name: "AgentreKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "AgentreKit", targets: ["AgentreDomain", "AgentreDesign", "AgentreREST", "AgentreRelay", "AgentreStore", "AgentreUI"]),
    ],
    dependencies: [
        .package(path: "Vendor/agentre/pkg/wire/swift"),
    ],
    targets: [
        .target(name: "AgentreDomain"),
        .target(name: "AgentreDesign"),
        .target(name: "AgentreREST", dependencies: ["AgentreDomain"]),
        .target(name: "AgentreRelay", dependencies: ["AgentreDomain", wire]),
        .target(name: "AgentreStore", dependencies: ["AgentreDomain", wire]),
        .target(name: "AgentreUI", dependencies: ["AgentreDomain", "AgentreDesign"]),
        .target(name: "AgentreTestSupport", dependencies: ["AgentreDomain", "AgentreDesign"]),
        // Hosted/ 要真实钥匙串：无宿主的包测试进程没有钥匙串权限（-34018），
        // 那几份用例改由 project.yml 里以应用为宿主的 AgentreHostedTests 编译运行。
        testTarget("AgentreAuthTests", exclude: ["Hosted"]),
        testTarget("AgentreDesignTests"),
        testTarget("AgentreRelayTests"),
        testTarget("AgentreStoreTests"),
        testTarget("AgentreMessagesTests"),
        testTarget("AgentreMachineTests"),
        testTarget("AgentreTranscriptTests"),
        testTarget("AgentreApprovalTests"),
        testTarget("AgentreComposerTests"),
        testTarget("AgentreNewConversationTests"),
        testTarget("AgentreAccountTests"),
    ],
    swiftLanguageModes: [.v6]
)
