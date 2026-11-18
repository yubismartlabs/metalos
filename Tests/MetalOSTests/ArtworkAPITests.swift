import XCTest
@testable import MetalOS

final class ArtworkAPITests: XCTestCase {
    override func tearDown() {
        ArtworkFixtureProtocol.handler = nil
        super.tearDown()
    }
    private func api() -> ArtworkAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkFixtureProtocol.self]
        return ArtworkAPI(session: URLSession(configuration: configuration))
    }
    private var credentials: ArtworkCredentials {
        ArtworkCredentials(igdbClientID: "fixture-id", igdbClientSecret: "fixture-secret")
    }

    func testIGDBMatchesTitleAndReturnsSeparateCoverAndHeroWithSource() async throws {
        var paths: [String] = []
        ArtworkFixtureProtocol.handler = { request in
            paths.append(request.url!.path)
            switch request.url!.path {
            case "/oauth2/token":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
                let body = ArtworkFixtureProtocol.body(request)
                XCTAssertTrue(body.contains("client_id=fixture-id"))
                XCTAssertTrue(body.contains("client_secret=fixture-secret"))
                XCTAssertTrue(body.contains("grant_type=client_credentials"))
                XCTAssertNil(request.url!.query)
                return (200, #"{"access_token":"fixture-token","expires_in":3600,"token_type":"bearer"}"#)
            case "/v4/games":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Client-ID"), "fixture-id")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
                let body = ArtworkFixtureProtocol.body(request)
                XCTAssertTrue(body.contains(#"search "Portal 2""#))
                XCTAssertTrue(body.contains("cover.image_id"))
                XCTAssertTrue(body.contains("where version_parent = null"))
                return (200, #"""
                [
                  {"id":1,"name":"Portal","slug":"portal","cover":{"image_id":"cover-portal"}},
                  {"id":2,"name":"Portal 2","slug":"portal-2","cover":{"image_id":"cover-portal-2"},
                   "artworks":[
                     {"image_id":"hero-portrait","width":1080,"height":1920,"alpha_channel":false},
                     {"image_id":"hero-alpha","width":1920,"height":1080,"alpha_channel":true},
                     {"image_id":"hero-art","width":2400,"height":1350,"alpha_channel":false}
                   ],
                   "screenshots":[{"image_id":"shot","width":1920,"height":1080}]}
                ]
                """#)
            default:
                XCTFail("Unexpected artwork endpoint")
                return (404, "[]")
            }
        }
        let result = await api().lookup(title: "Portal 2", credentials: credentials)
        XCTAssertEqual(paths, ["/oauth2/token", "/v4/games"])
        XCTAssertEqual(result.matchedTitle, "Portal 2")
        XCTAssertEqual(result.assets.count, 2)
        XCTAssertEqual(result.assets.first?.url.absoluteString, "https://images.igdb.com/igdb/image/upload/t_cover_big_2x/cover-portal-2.jpg")
        let hero = try XCTUnwrap(result.assets.first { $0.kind == .hero })
        XCTAssertEqual(hero.url.absoluteString, "https://images.igdb.com/igdb/image/upload/t_1080p/hero-art.jpg")
        XCTAssertEqual(hero.sourceURL?.absoluteString, "https://www.igdb.com/games/portal-2")
        XCTAssertEqual(hero.provider, "IGDB")
    }

    func testTokenIsReusedAcrossLookups() async {
        var tokenRequests = 0, searchRequests = 0
        ArtworkFixtureProtocol.handler = { request in
            if request.url!.path == "/oauth2/token" {
                tokenRequests += 1
                return (200, #"{"access_token":"fixture-token","expires_in":3600,"token_type":"bearer"}"#)
            }
            searchRequests += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            return (200, #"[{"id":2,"name":"Portal 2","slug":"portal-2","cover":{"image_id":"cover"}}]"#)
        }
        let service = api()
        _ = await service.lookup(title: "Portal 2", credentials: credentials)
        _ = await service.lookup(title: "Portal 2", credentials: credentials)
        XCTAssertEqual(tokenRequests, 1)
        XCTAssertEqual(searchRequests, 2)
    }

    func testUnauthorizedSearchRefreshesTokenOnce() async {
        var tokenRequests = 0, searchRequests = 0
        ArtworkFixtureProtocol.handler = { request in
            if request.url!.path == "/oauth2/token" {
                tokenRequests += 1
                return (200, #"{"access_token":"token-\#(tokenRequests)","expires_in":3600,"token_type":"bearer"}"#)
            }
            searchRequests += 1
            if searchRequests == 1 { return (401, "{}") }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-2")
            return (200, #"[{"id":2,"name":"Portal 2","slug":"portal-2","cover":{"image_id":"cover"}}]"#)
        }
        let result = await api().lookup(title: "Portal 2", credentials: credentials)
        XCTAssertEqual(result.assets.count, 1)
        XCTAssertEqual(tokenRequests, 2)
        XCTAssertEqual(searchRequests, 2)
    }

    func testRateLimitIsReportedWithoutRetryStormOrCredentialLeak() async {
        var tokenRequests = 0, searchRequests = 0
        ArtworkFixtureProtocol.handler = { request in
            if request.url!.path == "/oauth2/token" {
                tokenRequests += 1
                return (200, #"{"access_token":"fixture-token","expires_in":3600,"token_type":"bearer"}"#)
            }
            searchRequests += 1
            return (429, #"{"message":"fixture-secret"}"#)
        }
        let service = api()
        let result = await service.lookup(title: "Portal 2", credentials: credentials)
        _ = await service.lookup(title: "Another game", credentials: credentials)
        XCTAssertEqual(tokenRequests, 1)
        XCTAssertEqual(searchRequests, 1)
        XCTAssertTrue(result.messages.joined().contains("Rate limit"))
        XCTAssertFalse(result.messages.joined().contains("fixture-secret"))
    }

    func testUntrustedImageIdentifiersAreIgnored() async {
        ArtworkFixtureProtocol.handler = { request in
            if request.url!.path == "/oauth2/token" {
                return (200, #"{"access_token":"fixture-token","expires_in":3600,"token_type":"bearer"}"#)
            }
            return (200, #"""
            [{"id":2,"name":"Portal 2","slug":"portal-2",
              "cover":{"image_id":"https://steamgriddb.com.evil.example/art.png"},
              "artworks":[{"image_id":"../art","width":1920,"height":1080}],
              "screenshots":[{"image_id":"file:///tmp/art.png","width":1920,"height":1080}]}]
            """#)
        }
        let result = await api().lookup(title: "Portal 2", credentials: credentials)
        XCTAssertTrue(result.assets.isEmpty)
        XCTAssertTrue(result.messages.joined().contains("No supported artwork"))
    }

    func testCredentialsRejectedByTokenEndpointIsReportedWithoutLeakingSecret() async {
        ArtworkFixtureProtocol.handler = { _ in (400, #"{"message":"fixture-secret"}"#) }
        let result = await api().lookup(title: "Portal 2", credentials: credentials)
        XCTAssertTrue(result.messages.joined().contains("credentials were rejected"))
        XCTAssertFalse(result.messages.joined().contains("fixture-secret"))
    }
}

private final class ArtworkFixtureProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }; data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
