import Foundation
import Network

public enum LocalHTTPServerError: Error {
    case startTimeout
}

/// 127.0.0.1에만 열리는 작은 HTTP 서버. 연결마다 요청 하나를 받고 닫는다.
/// 바깥에서 오는 요청은 tailscale funnel 같은 중계가 이 주소로 넘겨준다.
public final class LocalHTTPServer {
    public typealias Handler = (HTTPRequest) -> HTTPResponse
    /// 헤더만 받은 시점에 부른다. 응답을 돌려주면 본문을 기다리지 않고 그 응답으로 끝낸다.
    public typealias HeadCheck = (HTTPRequest) -> HTTPResponse?

    private final class Slot {
        let connection: NWConnection
        let startedAt = Date()
        var headComplete = false

        init(_ connection: NWConnection) {
            self.connection = connection
        }
    }

    private let requestedPort: UInt16
    private let maxConnections: Int
    private let timeout: TimeInterval
    private let headCheck: HeadCheck?
    private let handler: Handler
    private let queue = DispatchQueue(label: "mac-guard.http")
    private var listener: NWListener?
    /// 서버 큐에서만 바뀐다.
    private var slots: [ObjectIdentifier: Slot] = [:]
    public private(set) var port: UInt16 = 0

    /// 연결은 timeout 초가 지나면 닫는다. 자리가 다 차면 헤더를 아직 다 못 보낸 가장 오래된 연결을 닫고 새 연결을 받는다
    /// (느린 연결로 자리를 막는 공격 대비). 헤더를 다 보낸 연결뿐이면 새 연결을 닫는다.
    public init(port: UInt16, maxConnections: Int = 32, timeout: TimeInterval = 3,
                headCheck: HeadCheck? = nil, handler: @escaping Handler) {
        requestedPort = port
        self.maxConnections = maxConnections
        self.timeout = timeout
        self.headCheck = headCheck
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
            guard let self else {
                connection.cancel()
                return
            }
            if self.slots.count >= self.maxConnections {
                let waiting = self.slots.values.filter { !$0.headComplete }
                guard let oldest = waiting.min(by: { $0.startedAt < $1.startedAt }) else {
                    connection.cancel()
                    return
                }
                self.close(oldest)
            }
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
        let slot = Slot(connection)
        let key = ObjectIdentifier(connection)
        slots[key] = slot
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.slots[key] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.close(slot) }
        receive(slot, buffer: Data())
    }

    private func close(_ slot: Slot) {
        slots[ObjectIdentifier(slot.connection)] = nil
        slot.connection.cancel()
    }

    private func receive(_ slot: Slot, buffer: Data) {
        slot.connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                slot.connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if !slot.headComplete {
                switch HTTPParser.parseHead(buffer) {
                case .incomplete:
                    break
                case .invalid(let reason):
                    self.respond(slot, .error(400, reason))
                    return
                case .head(let head, _, _):
                    slot.headComplete = true
                    if let early = self.headCheck?(head) {
                        self.respond(slot, early)
                        return
                    }
                }
            }
            switch HTTPParser.parse(buffer) {
            case .complete(let request):
                self.respond(slot, self.handler(request))
            case .invalid(let reason):
                self.respond(slot, .error(400, reason))
            case .incomplete:
                if isComplete || error != nil {
                    self.close(slot)
                } else {
                    self.receive(slot, buffer: buffer)
                }
            }
        }
    }

    private func respond(_ slot: Slot, _ response: HTTPResponse) {
        slot.connection.send(content: response.serialized(), completion: .contentProcessed { [weak self] _ in
            if let self { self.close(slot) } else { slot.connection.cancel() }
        })
    }
}
