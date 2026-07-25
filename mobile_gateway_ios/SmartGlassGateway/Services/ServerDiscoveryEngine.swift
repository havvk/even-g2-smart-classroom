import Foundation
import Network
import Combine

class ServerDiscoveryEngine: ObservableObject {
    static let shared = ServerDiscoveryEngine()
    
    @Published var discoveredServerURL: String?
    @Published var isSearching = false
    
    private var listener: NWListener?
    
    func startDiscovery(onDiscovered: @escaping (String) -> Void) {
        guard !isSearching else { return }
        isSearching = true
        
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: 8001)
            
            listener?.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                connection.receiveMessage { data, context, isComplete, error in
                    if let data = data, let messageStr = String(data: data, encoding: .utf8) {
                        if messageStr.contains("SMART_CLASSROOM_SERVER") {
                            var wsURL = ""
                            
                            // 优先解析广播包中包含的标准 ws_url
                            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let urlFromBeacon = json["ws_url"] as? String, !urlFromBeacon.isEmpty {
                                wsURL = urlFromBeacon
                            } else {
                                var ip = ""
                                if case .hostPort(let host, _) = connection.endpoint {
                                    switch host {
                                    case .ipv4(let ipv4):
                                        ip = "\(ipv4)"
                                    case .ipv6(let ipv6):
                                        ip = "\(ipv6)"
                                    case .name(let name, _):
                                        ip = name
                                    @unknown default:
                                        ip = ""
                                    }
                                }
                                ip = ip.components(separatedBy: "%").first ?? ip
                                wsURL = "ws://\(ip):8000/ws/session/sess_demo"
                            }
                            
                            DispatchQueue.main.async {
                                self?.discoveredServerURL = wsURL
                                self?.isSearching = false
                                self?.stopDiscovery()
                                onDiscovered(wsURL)
                            }
                        }
                    }
                }
            }
            
            listener?.start(queue: .main)
        } catch {
            print("UDP Discovery listener failed: \(error)")
            isSearching = false
        }
    }
    
    func stopDiscovery() {
        listener?.cancel()
        listener = nil
        isSearching = false
    }
}
