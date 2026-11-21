import Foundation
import Testing

@testable import catLight

/// Serves canned responses and records requests; handlers are keyed by request path.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset(_ h: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        lock.withLock {
            handler = h
            requests = []
        }
    }
    static var recorded: [URLRequest] { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.requests.append(request) }
        let (status, data) = Self.handler?(request) ?? (500, Data())
        client?.urlProtocol(
            self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func json(_ s: String) -> Data { Data(s.utf8) }

@Suite("Tuya cloud signing")
struct CloudSigningTests {
    @Test func tokenRequestSignatureMatchesReference() {
        let sig = TuyaCloudClient.signature(
            secret: "secretsecretsecretsecretsecret12", clientID: "clientid123456789012", token: nil, timestamp: 1_700_000_000_000,
            method: "GET", body: Data(), pathAndQuery: "/v1.0/token?grant_type=1")
        #expect(sig == CloudVectors.tokenSign)
    }

    @Test func businessRequestSignatureIncludesTheToken() {
        let sig = TuyaCloudClient.signature(
            secret: "secretsecretsecretsecretsecret12", clientID: "clientid123456789012", token: "tok_abcdef0123456789",
            timestamp: 1_700_000_000_123, method: "GET", body: Data(),
            pathAndQuery: "/v1.0/iot-01/associated-users/devices?last_row_key=&size=100")
        #expect(sig == CloudVectors.bizSign)
        #expect(sig != CloudVectors.tokenSign)
    }

    @Test func regionsMapToDataCenterHosts() {
        #expect(TuyaCloudRegion.westernAmerica.host == "openapi.tuyaus.com")
        #expect(TuyaCloudRegion.centralEurope.host == "openapi.tuyaeu.com")
        #expect(TuyaCloudRegion.allCases.count == 6)
    }
}

@Suite("Tuya cloud client", .serialized)
struct CloudClientTests {
    let creds = CloudCredentials(
        accessID: "clientid123456789012", accessSecret: "secretsecretsecretsecretsecret12", region: .westernAmerica)

    @Test func importsLightsWithLocalKeysAndSignsEveryRequest() async throws {
        MockURLProtocol.reset { req in
            if req.url!.path == "/v1.0/token" {
                return (200, json(#"{"success":true,"result":{"access_token":"tok123","expire_time":7200}}"#))
            }
            return (
                200,
                json(
                    #"""
                    {"success":true,"result":{"has_more":false,"devices":[
                      {"id":"bf01","name":"Fita LED Mesa","local_key":"0123456789abcdef","product_id":"p1","category":"dj","ip":"1.2.3.4","online":true},
                      {"id":"bf02","name":"Tomada","local_key":"fedcba9876543210","category":"cz","online":false}]}}
                    """#)
            )
        }
        let client = TuyaCloudClient(credentials: creds, session: mockSession(), now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let devices = try await client.fetchDevices()
        #expect(devices.map(\.id) == ["bf01", "bf02"])
        #expect(devices[0].localKey == "0123456789abcdef" && devices[0].isLight && devices[0].productID == "p1")
        #expect(!devices[1].isLight)

        let reqs = MockURLProtocol.recorded
        #expect(reqs.count == 2)
        #expect(reqs[0].url?.host == "openapi.tuyaus.com")
        #expect(reqs[0].value(forHTTPHeaderField: "client_id") == "clientid123456789012")
        #expect(reqs[0].value(forHTTPHeaderField: "sign_method") == "HMAC-SHA256")
        #expect(reqs[0].value(forHTTPHeaderField: "access_token") == nil)
        #expect(
            reqs[0].value(forHTTPHeaderField: "sign")
                == TuyaCloudClient.signature(
                    secret: creds.accessSecret, clientID: creds.accessID, token: nil, timestamp: 1_700_000_000_000, method: "GET",
                    body: Data(),
                    pathAndQuery: "/v1.0/token?grant_type=1"))
        #expect(reqs[1].value(forHTTPHeaderField: "access_token") == "tok123")
        #expect(reqs[1].url?.query == "last_row_key=&size=100")  // keys sorted alphabetically
    }

    @Test func invalidCredentialsSurfaceTheErrorFromTuya() async throws {
        MockURLProtocol.reset { _ in (200, json(#"{"success":false,"code":1004,"msg":"sign invalid","t":1700000000000}"#)) }
        let client = TuyaCloudClient(credentials: creds, session: mockSession())
        await #expect(throws: TuyaCloudError.api(code: 1004, message: "sign invalid")) { _ = try await client.fetchDevices() }
        #expect(MockURLProtocol.recorded.count == 1)  // no device request was attempted
        #expect(TuyaCloudError.api(code: 1004, message: "sign invalid").errorDescription == "Tuya: sign invalid (1004)")
    }

    @Test func tokenIsReusedAcrossRequests() async throws {
        MockURLProtocol.reset { req in
            req.url!.path == "/v1.0/token"
                ? (200, json(#"{"success":true,"result":{"access_token":"tok","expire_time":7200}}"#))
                : (200, json(#"{"success":true,"result":{"devices":[{"id":"bf01","name":"L","local_key":"0123456789abcdef"}]}}"#))
        }
        let client = TuyaCloudClient(credentials: creds, session: mockSession())
        _ = try await client.fetchDevices()
        _ = try await client.fetchDevices()
        #expect(MockURLProtocol.recorded.filter { $0.url!.path == "/v1.0/token" }.count == 1)
    }

    @Test func pagingFollowsLastRowKey() async throws {
        MockURLProtocol.reset { req in
            if req.url!.path == "/v1.0/token" { return (200, json(#"{"success":true,"result":{"access_token":"t","expire_time":7200}}"#)) }
            if req.url!.query?.contains("last_row_key=next") == true {
                return (200, json(#"{"success":true,"result":{"has_more":false,"devices":[{"id":"b","name":"B","local_key":"k"}]}}"#))
            }
            return (
                200,
                json(
                    #"{"success":true,"result":{"has_more":true,"last_row_key":"next","devices":[{"id":"a","name":"A","local_key":"k"}]}}"#)
            )
        }
        let devices = try await TuyaCloudClient(credentials: creds, session: mockSession()).fetchDevices()
        #expect(devices.map(\.id) == ["a", "b"])
    }

    @Test func refreshKeysReturnsOnlyRegisteredLightsWithKeys() async throws {
        MockURLProtocol.reset { req in
            req.url!.path == "/v1.0/token"
                ? (200, json(#"{"success":true,"result":{"access_token":"t","expire_time":7200}}"#))
                : (
                    200,
                    json(
                        #"{"success":true,"result":{"devices":[{"id":"a","name":"A","local_key":"NEWKEY0123456789"},{"id":"z","name":"Z","local_key":"other"}]}}"#
                    )
                )
        }
        let keys = try await TuyaCloudClient(credentials: creds, session: mockSession()).refreshKeys(for: ["a", "missing"])
        #expect(keys == ["a": "NEWKEY0123456789"])
    }

    @Test func networkFailureIsReportedAsSuch() async throws {
        MockURLProtocol.reset { _ in (200, Data("<html>".utf8)) }
        await #expect(throws: TuyaCloudError.badResponse) {
            _ = try await TuyaCloudClient(credentials: creds, session: mockSession()).fetchDevices()
        }
    }

    @Test func specificationsDetermineTheProfile() async throws {
        MockURLProtocol.reset { req in
            req.url!.path == "/v1.0/token"
                ? (200, json(#"{"success":true,"result":{"access_token":"t","expire_time":7200}}"#))
                : (
                    200,
                    json(
                        #"{"success":true,"result":{"functions":[{"code":"switch_led","type":"Boolean"},{"code":"colour_data_v2","type":"Json"}],"status":[{"code":"bright_value_v2","type":"Integer"}]}}"#
                    )
                )
        }
        let specs = try await TuyaCloudClient(credentials: creds, session: mockSession()).specifications(deviceID: "bf01")
        #expect(specs.map(\.code) == ["switch_led", "colour_data_v2", "bright_value_v2"])
        #expect(TuyaCloudClient.profile(from: specs) == .v2)
        #expect(TuyaCloudClient.profile(from: [CloudDPSpec(code: "colour_data", type: nil)]) == .legacy)
        #expect(TuyaCloudClient.profile(from: []) == nil)
    }
}
