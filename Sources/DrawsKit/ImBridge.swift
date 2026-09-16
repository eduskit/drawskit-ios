import Foundation

public protocol DrawsKitImTransport {
    func send(_ payload: Any)
    func onMessage(_ handler: @escaping (Any) -> Void)
    func onSendAck(_ handler: @escaping (String) -> Void)
    func destroy()
}

public extension DrawsKitImTransport {
    func onSendAck(_ handler: @escaping (String) -> Void) {}
    func destroy() {}
}

internal final class ImBridge {
    private let transport: DrawsKitImTransport
    private let coordinator: SyncCoordinator
    private var mediaInbound: ((Any) -> Bool)?

    init(transport: DrawsKitImTransport, coordinator: SyncCoordinator) {
        self.transport = transport
        self.coordinator = coordinator
    }

    func setMediaInbound(_ handler: ((Any) -> Bool)?) {
        mediaInbound = handler
    }

    func attach() {
        transport.onMessage { [weak self, weak coordinator] payload in
            if self?.mediaInbound?(payload) == true { return }
            coordinator?.handleInboundMessage(payload)
        }
        transport.onSendAck { [weak coordinator] opId in
            coordinator?.ackByOpId(opId)
        }
    }

    func destroy() {
        transport.destroy()
    }
}
