//
//  Created by Guy Kahlon.
//

import Foundation
import RxSwift
import RxCocoa
import Starscream

public enum WebSocketEvent: Equatable {
    public static func == (lhs: WebSocketEvent, rhs: WebSocketEvent) -> Bool {
        switch (lhs, rhs) {
        case (.connected, .connected):
            return true
        case  let (.disconnected(lError), .disconnected(rError)):
            guard let leftError = lError, let rightError = rError else {
                return lError == nil && rError == nil
            }

            if let  wsLeftError = leftError as? WSError, let wsRightError = rightError as? WSError {
                return wsLeftError.code == wsRightError.code && wsLeftError.type == wsRightError.type
            }
            
            return (leftError as NSError) == (rightError as NSError)
        case let (.message(lmessage), .message(rmessage)):
            return lmessage == rmessage
        case let (.data(ldata), .data(rdata)):
            return ldata == rdata
        case (.pong, .pong):
            return true
        default:
            return false
        }
    }
    
    case connected
    case disconnected(Error?)
    case message(String)
    case data(Data)
    case pong
}

public class RxWebSocketDelegateProxy<Client: WebSocketClient>: DelegateProxy<Client, NSObjectProtocol>, DelegateProxyType, WebSocketDelegate, WebSocketPongDelegate {

    private weak var forwardDelegate: WebSocketDelegate?
    private weak var forwardPongDelegate: WebSocketPongDelegate?

    fileprivate let subject = PublishSubject<WebSocketEvent>()

    required public init(websocket: Client) {
        super.init(parentObject: websocket, delegateProxy: RxWebSocketDelegateProxy.self)
    }

    public static func currentDelegate(for object: Client) -> NSObjectProtocol? {
        return object.delegate as? NSObjectProtocol
    }

    public static func setCurrentDelegate(_ delegate: NSObjectProtocol?, to object: Client) {
        object.delegate = delegate as? WebSocketDelegate
        object.pongDelegate = delegate as? WebSocketPongDelegate
    }

    public static func registerKnownImplementations() {
        self.register { RxWebSocketDelegateProxy(websocket: $0) }
    }

    public func websocketDidConnect(socket: WebSocketClient) {
        subject.onNext(WebSocketEvent.connected)
        forwardDelegate?.websocketDidConnect(socket: socket)
    }

    public func websocketDidDisconnect(socket: WebSocketClient, error: Error?) {
        if let err = error {
            subject.onError(err)
        } else {
            subject.onNext(WebSocketEvent.disconnected(error))
            subject.onCompleted()
        }
        forwardDelegate?.websocketDidDisconnect(socket: socket, error: error)
    }

    public func websocketDidReceiveMessage(socket: WebSocketClient, text: String) {
        subject.onNext(WebSocketEvent.message(text))
        forwardDelegate?.websocketDidReceiveMessage(socket: socket, text: text)
    }

    public func websocketDidReceiveData(socket: WebSocketClient, data: Data) {
        subject.onNext(WebSocketEvent.data(data))
        forwardDelegate?.websocketDidReceiveData(socket: socket, data: data)
    }

    public func websocketDidReceivePong(socket: WebSocketClient, data: Data?) {
        subject.onNext(WebSocketEvent.pong)
        forwardPongDelegate?.websocketDidReceivePong(socket: socket, data: data)
    }

    deinit {
        subject.onCompleted()
    }
}

public class WebSocketConnection<Client: WebSocketClient> {
    var client: Client
    var response: Observable<WebSocketEvent>
    

    
    init(client: Client, response: Observable<WebSocketEvent>) {
        self.client = client
        self.response = response
    }

    public var text: Observable<String> {
        return response
            .filter {
                switch $0 {
                case .message:
                    return true
                default:
                    return false
                }
            }
            .map {
                switch $0 {
                case .message(let message):
                    return message
                case .disconnected(let error):
                    if let err = error {
                        throw err
                    }
                    throw RxError.unknown
                default:
                    return String()
                }
            }
    }
    
    public func write(data: Data) -> Single<Void> {
        
        return Single.create { sub in
            self.client.write(data: data) {
                sub(.success(()))
            }
            
            return Disposables.create()
        }
    }
    
    public func write(ping: Data) -> Single<Void> {
        return Single.create { sub in
            self.client.write(ping: ping) {
                sub(.success(()))
            }
            
            return Disposables.create()
        }
    }
    
    public func write(string: String) -> Single<Void> {
        return Single.create { sub in
            self.client.write(string: string) {
                sub(.success(()))
            }
            
            return Disposables.create()
        }
    }
    
    
    public func disconnect() -> Single<Void> {
        if !client.isConnected {
            return .just(())
        }
        
        return Single.create { sub in
            defer { self.client.disconnect() }
            
            return self.response
                .filter {
                    switch $0 {
                    case .disconnected(_):
                        return true
                    default:
                        return false
                    }
                }
                .take(1)
                .map { _ in () }
                .asSingle()
                .subscribe(sub)
        }
    }
    
}

extension Reactive where Base: WebSocketClient {
    
    public var response: Observable<WebSocketEvent> {
        return RxWebSocketDelegateProxy.proxy(for: base).subject
    }
    
    public func connect() -> Single<WebSocketConnection<Base>> {
        return Single.create { sub in
            
            defer { self.base.connect() }
            
            return self.response
                .filter {
                    switch $0 {
                    case .connected, .disconnected(_):
                        return true
                    default:
                        return false
                    }
                }
                .take(1)
                .map {
                    switch $0 {
                    case .connected:
                        return WebSocketConnection(client: self.base, response: self.response)
                    case .disconnected(let error):
                        if let err = error {
                            throw err
                        }
                        throw RxError.unknown
                    default:
                        throw RxError.unknown
                    }
                }
                .asSingle()
                .subscribe(sub)
        }
    }
}
