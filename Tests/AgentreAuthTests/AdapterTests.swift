import AgentreDomain
import AgentreREST
import AgentreStore
import Foundation
import Testing

/// 截住 URLSession 请求的协议桩：记下请求，按预设作答。
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var captured: URLRequest?
    nonisolated(unsafe) static var capturedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.captured = request
        Self.capturedBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return data
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 410, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("gone".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 只接 cache-probe.invalid 的桩：以允许缓存的方式答一份带密钥的应答。
final class CachingStubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cache-probe.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":{"providers":[{"api_key":"sk-secret"}]}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct AdapterTests {
    @Test("URLSession 传输：方法、头、正文原样发出，状态码与正文原样交回")
    func urlSessionTransport() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let transport = URLSessionTransport(session: URLSession(configuration: configuration))

        let response = try await transport.send(HTTPRequest(
            method: "POST", url: URL(string: "https://app.agentrehub.com/v1/oauth/device/token")!,
            headers: ["Content-Type": "application/json"], body: Data("{}".utf8)
        ))

        #expect(response == HTTPResponse(status: 410, body: Data("gone".utf8)))
        let request = try #require(StubURLProtocol.captured)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(StubURLProtocol.capturedBody == Data("{}".utf8))
    }

    @Test("默认的 URLSession 传输不把应答留进应用的 URL 缓存（引擎目录的应答里带着供应商的 API key）")
    func defaultTransportKeepsNoResponses() async throws {
        let url = URL(string: "https://cache-probe.invalid/v1/engine/snapshot")!
        URLProtocol.registerClass(CachingStubURLProtocol.self)
        defer { URLProtocol.unregisterClass(CachingStubURLProtocol.self) }
        URLCache.shared.removeCachedResponse(for: URLRequest(url: url))
        _ = try? await URLSessionTransport().send(HTTPRequest(method: "GET", url: url))
        try await Task.sleep(for: .milliseconds(300))
        #expect(URLCache.shared.cachedResponse(for: URLRequest(url: url)) == nil)
    }

    @Test("服务器地址：大小写不同、写明默认端口的同一地址认作同一台服务器", arguments: [
        "HTTPS://App.AgentreHub.com", "https://app.agentrehub.com:443", "https://APP.agentrehub.com/",
    ])
    func serverAddressNormalises(text: String) {
        #expect(ServerAddress(string: text) == .production)
        #expect(ServerAddress(string: "http://Docker.local:80") == ServerAddress(string: "http://docker.local"))
        #expect(ServerAddress(string: "http://docker.local:8443") != ServerAddress(string: "http://docker.local"))
    }

    @Test("服务器地址：默认生产；保存后新实例读回；存了坏值读回生产地址")
    func serverAddressStore() throws {
        let suite = "agentre.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(UserDefaultsServerAddressStore(defaults: defaults).load() == .production)

        let dev = try #require(ServerAddress(string: "http://docker.local:8443"))
        UserDefaultsServerAddressStore(defaults: defaults).save(dev)
        #expect(UserDefaultsServerAddressStore(defaults: defaults).load() == dev)

        defaults.set("ftp://nope", forKey: UserDefaultsServerAddressStore.key)
        #expect(UserDefaultsServerAddressStore(defaults: defaults).load() == .production)
    }
}
