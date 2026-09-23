import AgentreDomain
import AgentreTestSupport
@testable import AgentreUI
import Foundation
import SwiftUI
import Testing

/// 错误呈现层的守卫：任何对用户可见的失败，都由应用解析成事实后以用户语言重述；
/// 错误码与对端原串一个字都到不了屏幕上。
@MainActor
@Suite("失败呈现")
struct FailurePresentationTests {
    static let languages = ["en", "zh-Hans"]

    static func localized(_ key: String, _ language: String) throws -> String {
        let path = try #require(AgentreUIResources.bundle.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path)).localizedString(forKey: key, value: "⟨missing⟩", table: "Me")
    }

    /// 测试进程当前语言下的译文（屏上读到的就是它）。
    static func current(_ key: String) -> String {
        AgentreUIResources.bundle.localizedString(forKey: key, value: "⟨missing⟩", table: "Me")
    }

    /// 带着对端原串与错误码的各色错误：服务端的 msg、HTTP 状态码、系统错误的描述、自定义错误的描述。
    struct PeerError: Error, CustomStringConvertible, LocalizedError {
        var description: String { "E4031 device_revoked: peer said boom" }
        var errorDescription: String? { "E4031 device_revoked: peer said boom" }
    }

    static let battery: [(any Error, FailureFact?)] = [
        (URLError(.notConnectedToInternet), .offline),
        (URLError(.networkConnectionLost), .offline),
        (URLError(.dataNotAllowed), .offline),
        (URLError(.cannotFindHost), .serverUnreachable),
        (URLError(.cannotConnectToHost), .serverUnreachable),
        (URLError(.secureConnectionFailed), .serverUnreachable),
        (URLError(.timedOut), .timedOut),
        (URLError(.cancelled), nil),
        (CancellationError(), nil),
        (AuthError.refreshRejected, .signedOut),
        (AuthError.signedOut, .signedOut),
        (AuthError.unexpectedResponse(status: 401), .signedOut),
        (AuthError.unexpectedResponse(status: 403), .notPermitted),
        (AuthError.unexpectedResponse(status: 404), .unrecognisedResponse),
        (AuthError.unexpectedResponse(status: 418), .unrecognisedResponse),
        (AuthError.unexpectedResponse(status: 200), .unrecognisedResponse),
        (AuthError.unexpectedResponse(status: 502), .serverUnavailable),
        (AuthError.unexpectedResponse(status: 503), .serverUnavailable),
        (AccountError.revokeRefused, .revokeNeedsConsole),
        (NSError(domain: "agentre.peer", code: 4031, userInfo: [NSLocalizedDescriptionKey: "E4031 device_revoked: peer said boom"]), .unknown),
        (PeerError(), .unknown),
        (DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unexpected character 'x' at 12")), .unknown),
    ]

    /// 端口实现自己已解析成事实的失败（例如中继报的要更新 App）。
    struct AlreadyFactual: FactualFailure {
        var fact: FailureFact { .updateRequired }
    }

    @Test("端口实现已解析成事实的失败照用那个事实，不说成认不出")
    func factualFailureKeepsItsFact() {
        #expect(FailureFact(presenting: AlreadyFactual()) == .updateRequired)
    }

    @Test("每一种错误都被解析成一个事实；取消不是失败，不呈现")
    func errorsParseIntoFacts() {
        for (error, expected) in Self.battery {
            #expect(FailureFact(presenting: error) == expected, "\(error)")
        }
    }

    @Test("每个事实都有两种语言的重述，其中没有数字、没有下划线标识符、没有未翻译的键")
    func everyFactIsRestated() throws {
        let identifier = try Regex(#"[A-Za-z]+_[A-Za-z_]+"#)
        for fact in FailureFact.allCases {
            for language in Self.languages {
                let text = try Self.localized(failureKey(fact), language)
                #expect(text != "⟨missing⟩" && text != failureKey(fact), "\(fact) [\(language)]")
                #expect(text.allSatisfy { !$0.isNumber }, "\(fact) [\(language)]: \(text)")
                #expect(text.firstMatch(of: identifier) == nil, "\(fact) [\(language)]: \(text)")
            }
        }
        // 两个不同的事实不说同一句话。
        let english = try FailureFact.allCases.map { try Self.localized(failureKey($0), "en") }
        #expect(Set(english).count == english.count, "\(english)")
    }

    @Test("屏上的失败提示只有重述的事实：对端原串、错误码、系统描述都不出现")
    func noticeShowsOnlyTheFact() async throws {
        for (error, expected) in Self.battery {
            guard let fact = FailureFact(presenting: error) else { continue }
            #expect(fact == expected)
            let labels = await HostedScreen(FailureNotice(fact: fact, onRetry: {})).labels()
            let shown = labels.joined(separator: "\n")
            #expect(shown.contains(Self.current(failureKey(fact))), "\(fact): \(labels)")
            #expect(!shown.contains("E4031") && !shown.contains("device_revoked") && !shown.contains("boom"), "\(labels)")
            #expect(!shown.contains(error.localizedDescription), "\(labels)")
            #expect(shown.allSatisfy { !$0.isNumber }, "\(labels)")
        }
    }

    @Test("协议版本不等：以规格给定的那句话告知更新 App")
    func updateRequiredWording() throws {
        #expect(try Self.localized("failure.updateRequired", "zh-Hans") == "这个版本的 App 连不上你的服务端，请更新 App")
        #expect(try Self.localized("failure.updateRequired", "en") == "This version of the app can't connect to your server. Please update the app.")
    }

    @Test("有出口的事实才给出口：能重试的给重试，登出、拒绝、要更新的不给")
    func exits() async throws {
        #expect(FailureFact.offline.exit == .retry)
        #expect(FailureFact.timedOut.exit == .retry)
        #expect(FailureFact.serverUnavailable.exit == .retry)
        #expect(FailureFact.signedOut.exit == FailureExit.none)
        #expect(FailureFact.revokeNeedsConsole.exit == FailureExit.none)
        #expect(FailureFact.updateRequired.exit == FailureExit.none)
        #expect(FailureFact.noMachineAvailable(.offline).exit == FailureExit.none)

        let retry = await hitTargetReport(of: FailureNotice(fact: .offline, onRetry: {}))
        #expect(retry.targets.count == 1, "\(retry.targets)")
        #expect(retry.violations.isEmpty, "\(retry.violations)")
        let none = await hitTargetReport(of: FailureNotice(fact: .revokeNeedsConsole, onRetry: {}))
        #expect(none.targets.isEmpty, "\(none.targets)")
    }

    @Test("表现层源码不把错误对象本身渲染出来：没有 localizedDescription、没有字符串插值错误")
    func presentationSourcesNeverRenderErrors() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appending(path: "Sources/AgentreUI")
        let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count >= 5, "扫描范围为空：\(directory.path)")
        let patterns = try [
            Regex(#"\.localizedDescription"#),
            Regex(#"\.errorDescription"#),
            Regex(#"\.failureReason"#),
            Regex(#"String\(describing:\s*error"#),
            Regex(#"\\\(\s*error"#),
            Regex(#"verbatim:\s*error"#),
        ]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for pattern in patterns where source.firstMatch(of: pattern) != nil {
                Issue.record("\(file.lastPathComponent) 直接呈现了错误对象")
            }
        }
    }

    @Test("源码守卫自身认得出违规写法")
    func sourceGuardCatches() throws {
        let pattern = try Regex(#"\\\(\s*error"#)
        #expect(#"Text(verbatim: "\(error)")"#.firstMatch(of: pattern) != nil)
    }
}

/// 「没有可用的机器」是带原因的事实，不是无限等待。
@MainActor
@Suite("没有可用的机器")
struct NoMachineTests {
    @Test("每个原因在屏上是一句不同的事实，不带服务端的取值原串")
    func eachReasonIsAFact() async throws {
        var seen: Set<String> = []
        for reason in MachineUnavailableReason.allCases {
            let labels = await HostedScreen(FailureNotice(fact: .noMachineAvailable(reason), onRetry: {})).labels()
            let shown = labels.joined(separator: "\n")
            #expect(!shown.isEmpty)
            #expect(!shown.contains("_"), "\(labels)")
            seen.insert(shown)
        }
        #expect(seen.count == MachineUnavailableReason.allCases.count)
    }
}
