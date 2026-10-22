import Foundation
import Network

public enum LocalHTTPServerError: Error {
    case startTimeout
}

/// 127.0.0.1에만 열리는 작은 HTTP 서버. 연결마다 요청 하나를 받고 닫는다.
/// 바깥에서 오는 요청은 tailscale funnel 같은 중계가 이 주소로 넘겨준다.
public final class LocalHTTPServer {
    public typealias Handler = (HTTPRequest) -> HTTPResponse

    private let requestedPort: UInt16
    private let maxConnections: Int
    private let handler: Handler
    private let queue = DispatchQueue(label: "mac-guard.http")
    private var listener: NWListener?
    /// 서버 큐에서만 바뀐다.
    private var openConnections = 0
    public private(set) var port: UInt16 = 0

    /// 동시에 열린 연결이 maxConnections를 넘으면 새 연결은 바로 닫는다.
    public init(port: UInt16, maxConnections: Int = 16, handler: @escaping Handler) {
        requestedPort = port
        self.maxConnections = maxConnections
        self.handler = handler
    }

    public func start(timeout: TimeInterval = 3) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let port: NWEndpoint.Port = requestedPort == 0 ? .any : NWEndpoint.Port(rawValue: requestedPort) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                failure = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.openConnections < self.maxConnections else {
                connection.cancel()
                return
            }
            self.openConnections += 1
            self.serve(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + timeout) == .success else {
            listener.cancel()
            throw LocalHTTPServerError.startTimeout
        }
        if let failure {
            listener.cancel()
            throw failure
        }
        self.port = listener.port?.rawValue ?? requestedPort
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        var finished = false
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                if !finished {
                    finished = true
                    self?.openConnections -= 1
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        // 느리게 보내거나 멈춘 연결은 5초 뒤 닫는다.
        queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPParser.parse(buffer) {
            case .complete(let request):
                self.respond(connection, self.handler(request))
            case .invalid(let reason):
                self.respond(connection, .error(400, reason))
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, _ response: HTTPResponse) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }
}
