import Foundation

public struct HTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    /// 키는 모두 소문자.
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }
}

public enum HTTPParseResult: Equatable, Sendable {
    case incomplete
    case complete(HTTPRequest)
    case invalid(String)
}

/// 이 앱이 받는 작은 요청만 다루는 HTTP/1.1 파서. chunked 전송은 받지 않는다.
public enum HTTPParser {
    public static let maxHeaderBytes = 8 * 1024
    public static let maxBodyBytes = 8 * 1024
    private static let separator = Data("\r\n\r\n".utf8)

    public static func parse(_ input: Data) -> HTTPParseResult {
        let data = Data(input)
        guard let end = data.range(of: separator) else {
            return data.count > maxHeaderBytes ? .invalid("header too large") : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes,
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else {
            return .invalid("bad header")
        }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .invalid("bad request line") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid("bad header line") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .invalid("transfer-encoding not supported") }
        guard let length = Int(headers["content-length"] ?? "0"), (0...maxBodyBytes).contains(length) else {
            return .invalid("bad content-length")
        }
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return .incomplete }
        var target = String(parts[1])
        if let query = target.firstIndex(of: "?") { target = String(target[..<query]) }
        return .complete(HTTPRequest(
            method: String(parts[0]),
            path: target,
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + length))
        ))
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    public static func json<T: Encodable>(_ status: Int, _ value: T) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONEncoder.guardAPI.encode(value)) ?? Data("{}".utf8))
    }

    public static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(status, ["error": message])
    }

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }
}

extension JSONEncoder {
    public static var guardAPI: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    public static var guardAPI: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
