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

public enum HTTPHeadResult: Equatable, Sendable {
    case incomplete
    case invalid(String)
    /// 본문 없이 요청 줄과 헤더만 담은 요청. 본문은 bodyStart부터 contentLength 바이트.
    case head(HTTPRequest, bodyStart: Int, contentLength: Int)
}

/// 이 앱이 받는 작은 요청만 다루는 HTTP/1.1 파서. chunked 전송은 받지 않는다.
/// 줄 구분은 CRLF만 인정하고, 요청 줄·헤더에 제어 문자가 있으면 거절한다(기록 위조·프록시 해석 차이 방지).
public enum HTTPParser {
    public static let maxHeaderBytes = 8 * 1024
    public static let maxBodyBytes = 8 * 1024
    private static let separator = Data("\r\n\r\n".utf8)
    /// 두 번 오면 해석이 갈릴 수 있어 거절하는 헤더.
    private static let singleHeaders: Set<String> = ["content-length", "authorization", "transfer-encoding"]
    private static let tokenSymbols = Set("!#$%&'*+-.^_`|~".unicodeScalars)

    public static func parseHead(_ input: Data) -> HTTPHeadResult {
        let data = Data(input)
        guard let end = data.range(of: separator) else {
            return data.count > maxHeaderBytes ? .invalid("header too large") : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes,
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else {
            return .invalid("bad header")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard !requestLine.unicodeScalars.contains(where: isControl),
              parts.count == 3,
              !parts[0].isEmpty, parts[0].unicodeScalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }),
              parts[1].hasPrefix("/"),
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
            return .invalid("bad request line")
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid("bad header line") }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard !name.isEmpty, name.unicodeScalars.allSatisfy(isTokenCharacter),
                  !value.unicodeScalars.contains(where: { isControl($0) && $0.value != 0x09 }) else {
                return .invalid("bad header line")
            }
            if headers[name] != nil, singleHeaders.contains(name) { return .invalid("duplicate \(name)") }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { return .invalid("transfer-encoding not supported") }
        let lengthText = headers["content-length"] ?? "0"
        guard (1...5).contains(lengthText.count), lengthText.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let length = Int(lengthText), length <= maxBodyBytes else {
            return .invalid("bad content-length")
        }
        var target = String(parts[1])
        if let query = target.firstIndex(of: "?") { target = String(target[..<query]) }
        return .head(HTTPRequest(method: String(parts[0]), path: target, headers: headers),
                     bodyStart: end.upperBound, contentLength: length)
    }

    public static func parse(_ input: Data) -> HTTPParseResult {
        switch parseHead(input) {
        case .incomplete:
            return .incomplete
        case .invalid(let reason):
            return .invalid(reason)
        case .head(let head, let bodyStart, let length):
            let data = Data(input)
            guard data.count - bodyStart >= length else { return .incomplete }
            return .complete(HTTPRequest(method: head.method, path: head.path, headers: head.headers,
                                         body: data.subdata(in: bodyStart..<(bodyStart + length))))
        }
    }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }

    private static func isTokenCharacter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 122)
            || (scalar.value >= 65 && scalar.value <= 90) || tokenSymbols.contains(scalar)
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
        case 500: return "Internal Server Error"
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
