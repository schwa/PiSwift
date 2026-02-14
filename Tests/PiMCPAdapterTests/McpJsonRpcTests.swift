import Testing
import Foundation
import PiSwiftAI
@testable import PiMCPAdapter

@Suite("JSON-RPC 2.0")
struct JsonRpcTests {
    @Test("Encode request")
    func encodeRequest() throws {
        let req = JsonRpcRequest(id: 1, method: "initialize", params: AnyCodable(["key": "value"]))
        let data = try JsonRpc.encode(req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["jsonrpc"] as? String == "2.0")
        #expect(json?["id"] as? Int == 1)
        #expect(json?["method"] as? String == "initialize")
        let params = json?["params"] as? [String: String]
        #expect(params?["key"] == "value")
    }

    @Test("Encode notification (no id)")
    func encodeNotification() throws {
        let notif = JsonRpcNotification(method: "notifications/initialized")
        let data = try JsonRpc.encodeNotification(notif)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["jsonrpc"] as? String == "2.0")
        #expect(json?["method"] as? String == "notifications/initialized")
        #expect(json?["id"] == nil)
    }

    @Test("Decode success response")
    func decodeSuccess() throws {
        let json = """
        {"jsonrpc":"2.0","id":1,"result":{"tools":[]}}
        """.data(using: .utf8)!
        let response = try JsonRpc.decodeResponse(json)
        #expect(response.id == 1)
        #expect(response.error == nil)
        #expect(response.result != nil)
        let resultDict = response.result?.value as? [String: Any]
        #expect(resultDict?["tools"] is [Any])
    }

    @Test("Decode error response")
    func decodeError() throws {
        let json = """
        {"jsonrpc":"2.0","id":2,"error":{"code":-32600,"message":"Invalid Request"}}
        """.data(using: .utf8)!
        let response = try JsonRpc.decodeResponse(json)
        #expect(response.id == 2)
        #expect(response.result == nil)
        #expect(response.error?.code == -32600)
        #expect(response.error?.message == "Invalid Request")
    }

    @Test("Encode to line appends newline")
    func encodeToLine() throws {
        let req = JsonRpcRequest(id: 1, method: "test")
        let data = try JsonRpc.encodeToLine(req)
        let str = String(data: data, encoding: .utf8)!
        #expect(str.hasSuffix("\n"))
        // Should be valid JSON without the newline
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = try JSONSerialization.jsonObject(with: trimmed.data(using: .utf8)!) as? [String: Any]
        #expect(json?["method"] as? String == "test")
    }

    @Test("Request without params")
    func requestNoParams() throws {
        let req = JsonRpcRequest(id: 5, method: "tools/list")
        let data = try JsonRpc.encode(req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["method"] as? String == "tools/list")
        // params can be null or absent
    }
}
