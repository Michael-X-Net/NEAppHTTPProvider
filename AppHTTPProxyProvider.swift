
import NetworkExtension
import CocoaAsyncSocket

struct HTTPProxySet {
    var host: String
    var port: UInt16
}

var proxy = HTTPProxySet(host: "127.0.0.1", port: 1080)


class AppProxyProvider: NEAppProxyProvider {

    override func startProxy(options: [String : Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        // Add code here to start the process of connecting the tunnel.
        print("start")
        completionHandler(nil)
    }
    
    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        // Add code here to start the process of stopping the tunnel.
        print("stop")
        completionHandler()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Add code here to handle the message.
        print("")
        if let handler = completionHandler {
            handler(messageData)
        }
    }
    
    override func sleep(completionHandler: @escaping() -> Void) {
        // Add code here to get ready to sleep.
        completionHandler()
    }
    
    override func wake() {
        // Add code here to wake up.
    }
    
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        // Add code here to handle the incoming flow.
        
        if let TCPFlow = flow as? NEAppProxyTCPFlow {
            let conn = ClientAppHTTPProxyConnection(flow: TCPFlow)
            conn.open()
        }
        
        return false
    }
}


/// An object representing the client side of a logical flow of network data in the SimpleTunnel tunneling protocol.
class ClientAppHTTPProxyConnection : NSObject, GCDAsyncSocketDelegate {
    
    // MARK: Constants
    let bufferSize: UInt = 4096
    let timeout    = 30.0
    let pattern    = "\n\n".data(using: .utf8)
    
    // MARK: Properties
    
    /// The NEAppProxyFlow object corresponding to this connection.
    let TCPFlow: NEAppProxyTCPFlow
    
    // MARK: Initializers
    var sock: GCDAsyncSocket!
    
    init(flow: NEAppProxyTCPFlow) {
        TCPFlow = flow
    }
    
    func open() {
        sock = GCDAsyncSocket(delegate: self, delegateQueue: DispatchQueue.main)
        do {
            try sock.connect(toHost: proxy.host, onPort: proxy.port, withTimeout: 3.0)
        } catch {
            TCPFlow.closeReadWithError(
                NSError(domain: NEAppProxyErrorDomain,
                        code: NEAppProxyFlowError.notConnected.rawValue,
                        userInfo: nil
                       )
            )
            return
        }
    }
    
    func socket(_ sock: GCDAsyncSocket, didConnectToHost host:String, port p:UInt16) {
        
        print("Connected to \(host) on port \(p).")
        
        let remoteHost = (TCPFlow.remoteEndpoint as! NWHostEndpoint).hostname
        let remotePort = (TCPFlow.remoteEndpoint as! NWHostEndpoint).port
        
        // 1. send CONNECT
        // CONNECT www.google.com:80 HTTP/1.1
        sock.write(
            "CONNECT \(remoteHost):\(remotePort) HTTP/1.1\n\n".data(using: .utf8),
            withTimeout: timeout,
            tag: 1)
        
    }
    
    func didReadFlow(data: Data?, error: Error?) -> Void {
        // 7. did read from flow
        // 8. write flow data to proxy
        sock.write(data, withTimeout: timeout, tag: 0)
        
        // 9. keep reading from flow
        TCPFlow.readData(completionHandler: self.didReadFlow)
    }
    
    func socket(_ sock: GCDAsyncSocket, didWriteDataWithTag tag: Int) {
        if tag == 1 {
            // 2. CONNECT header sent
            // 3. begin to read from proxy server
            sock.readData(toLength: bufferSize, withTimeout: timeout, tag: 1)
        }
    }
    
    func socket(_ sock: GCDAsyncSocket, didRead data: Data, withTag tag: Int) {
        if tag == 1 {
            // 4. read 1st proxy server response of CONNECT
            let range = data.range(of:pattern!,
                                   options: NSData.SearchOptions(rawValue: 0),
                                   in: 0..<data.count)
            
            if range != nil {
                let ret = data.range(of: "\r\n\r\n".data(using: .utf8)!,
                                     options: NSData.SearchOptions(rawValue: 0),
                                     in: 0..<range!.lowerBound)
                if ret != nil {
                    let loc = range?.upperBound
                    if data.count > loc! {
                        // 5. write to flow if there is data already
                        let left_data = data[loc! ..< data.count]
                        TCPFlow.write(left_data, withCompletionHandler: { error in })
                    }
                    
                    // 6. begin to read from Flow
                    TCPFlow.readData(completionHandler: self.didReadFlow)
                    
                    // 6.5 keep reading from proxy server
                    sock.readData(toLength: bufferSize, withTimeout: timeout, tag: 0)
                    return
                }
                
            }
            
            // Error: CONNECT failed
            TCPFlow.closeReadWithError(NSError(domain: NEAppProxyErrorDomain, code: NEAppProxyFlowError.notConnected.rawValue, userInfo: nil))
            sock.disconnect()
            return
        }
        
        // 10. writing any data followed to flow
        TCPFlow.write(data, withCompletionHandler: { error in })
        
        // 11. keep reading from proxy server
        sock.readData(toLength: bufferSize, withTimeout: timeout, tag: 0)
    }
}
