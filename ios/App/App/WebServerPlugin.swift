import Foundation
import Network
import CryptoKit
import Capacitor

/// WebServer — sirve el reloj (display.html + assets del bundle) por HTTP y
/// empuja el estado por WebSocket a cualquier dispositivo de la LAN (navegador,
/// smart TV, OBS/vMix browser source). El WKWebView no puede abrir un socket de
/// escucha; por eso el servidor vive aquí (Network framework). HTTP y WebSocket
/// comparten puerto: se hace el handshake WS a mano (SHA1+base64) y el framing.
@objc(WebServerPlugin)
public class WebServerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "WebServerPlugin"
    public let jsName = "WebServer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "isRunning", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "broadcast", returnType: CAPPluginReturnPromise)
    ]

    private var listener: NWListener?
    private var wsClients: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.federico.eventtimer.webserver")
    private var boundPort: Int = 0

    @objc func start(_ call: CAPPluginCall) {
        let portInt = call.getInt("port") ?? 9000
        guard portInt >= 1, portInt <= 65535, let port = NWEndpoint.Port(rawValue: UInt16(portInt)) else {
            call.reject("invalid-port"); return
        }
        queue.async {
            self.stopInternal()
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                let l = try NWListener(using: params, on: port)
                var settled = false
                l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
                l.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        if settled { return }; settled = true
                        self?.boundPort = portInt
                        let ip = self?.localIp() ?? "127.0.0.1"
                        call.resolve(["running": true, "port": portInt, "ip": ip,
                                      "url": "http://\(ip):\(portInt)/"])
                    case .failed(let e):
                        self?.stopInternal()
                        if settled { return }; settled = true
                        call.reject("start-failed: \(e)")
                    default: break
                    }
                }
                self.listener = l
                l.start(queue: self.queue)
            } catch {
                self.stopInternal(); call.reject("start-failed: \(error.localizedDescription)")
            }
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        queue.async { self.stopInternal(); call.resolve(["running": false]) }
    }

    @objc func isRunning(_ call: CAPPluginCall) {
        queue.async {
            let run = self.listener != nil
            var ret: [String: Any] = ["running": run, "clients": self.wsClients.count]
            if run { ret["url"] = "http://\(self.localIp()):\(self.boundPort)/" }
            call.resolve(ret)
        }
    }

    @objc func broadcast(_ call: CAPPluginCall) {
        let json = call.getString("json") ?? ""
        queue.async {
            let frame = WebServerPlugin.wsFrame(json)
            for (_, c) in self.wsClients {
                c.send(content: frame, completion: .contentProcessed { _ in })
            }
            call.resolve()
        }
    }

    private func stopInternal() {
        for (_, c) in wsClients { c.cancel() }
        wsClients.removeAll()
        listener?.cancel(); listener = nil; boundPort = 0
    }

    // MARK: - Conexiones

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveHeaders(conn, buffer: Data())
    }

    private func receiveHeaders(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buf = buffer
            if let d = data { buf.append(d) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(data: buf.subdata(in: buf.startIndex..<r.lowerBound), encoding: .utf8) ?? ""
                self.handleRequest(conn, header: header)
            } else if error == nil, !isComplete, buf.count < 65536 {
                self.receiveHeaders(conn, buffer: buf)
            } else {
                conn.cancel()
            }
        }
    }

    private func handleRequest(_ conn: NWConnection, header: String) {
        let lines = header.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").components(separatedBy: " ")
        let path = parts.count >= 2 ? parts[1] : "/"
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            if let i = l.firstIndex(of: ":") {
                let k = l[l.startIndex..<i].trimmingCharacters(in: .whitespaces).lowercased()
                let v = String(l[l.index(after: i)...]).trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }
        if headers["upgrade"]?.lowercased().contains("websocket") == true,
           let key = headers["sec-websocket-key"] {
            doWsHandshake(conn, key: key)
        } else {
            serveFile(conn, path: path)
        }
    }

    private func doWsHandshake(_ conn: NWConnection, key: String) {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept = Data(Insecure.SHA1.hash(data: Data((key + magic).utf8))).base64EncodedString()
        let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" +
                   "Connection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        conn.send(content: Data(resp.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self = self else { return }
            self.queue.async {
                self.wsClients[ObjectIdentifier(conn)] = conn
                self.drainWs(conn)
            }
        })
    }

    /// Sigue leyendo del cliente WS solo para detectar el cierre; ignora el contenido.
    private func drainWs(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, isComplete, error in
            guard let self = self else { return }
            if error != nil || isComplete {
                self.queue.async { self.wsClients[ObjectIdentifier(conn)] = nil; conn.cancel() }
            } else {
                self.drainWs(conn)
            }
        }
    }

    private func serveFile(_ conn: NWConnection, path: String) {
        var p = path
        if let q = p.firstIndex(of: "?") { p = String(p[p.startIndex..<q]) }
        if p == "/" || p.isEmpty { p = "/display.html" }
        if p.contains("..") { sendHttp(conn, status: "403 Forbidden", type: "text/plain", body: Data("403".utf8)); return }
        let base = Bundle.main.resourceURL?.appendingPathComponent("public")
        if let u = base?.appendingPathComponent(p), let data = try? Data(contentsOf: u) {
            sendHttp(conn, status: "200 OK", type: mime(p), body: data)
        } else {
            sendHttp(conn, status: "404 Not Found", type: "text/plain", body: Data("404 Not Found".utf8))
        }
    }

    private func sendHttp(_ conn: NWConnection, status: String, type: String, body: Data) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Helpers

    /// Trama WebSocket de texto, sin máscara (servidor→cliente). FIN + opcode 0x1.
    private static func wsFrame(_ text: String) -> Data {
        let payload = Array(text.utf8)
        var f: [UInt8] = [0x81]
        let n = payload.count
        if n < 126 { f.append(UInt8(n)) }
        else if n < 65536 { f.append(126); f.append(UInt8((n >> 8) & 0xFF)); f.append(UInt8(n & 0xFF)) }
        else { f.append(127); for i in stride(from: 56, through: 0, by: -8) { f.append(UInt8((n >> i) & 0xFF)) } }
        f.append(contentsOf: payload)
        return Data(f)
    }

    private func mime(_ p: String) -> String {
        let s = p.lowercased()
        if s.hasSuffix(".html") { return "text/html" }
        if s.hasSuffix(".js")   { return "application/javascript" }
        if s.hasSuffix(".css")  { return "text/css" }
        if s.hasSuffix(".png")  { return "image/png" }
        if s.hasSuffix(".svg")  { return "image/svg+xml" }
        if s.hasSuffix(".gif")  { return "image/gif" }
        if s.hasSuffix(".webp") { return "image/webp" }
        if s.hasSuffix(".json") || s.hasSuffix(".webmanifest") { return "application/json" }
        if s.hasSuffix(".ico")  { return "image/x-icon" }
        return "application/octet-stream"
    }

    /// IPv4 de la WiFi (en0) si existe; si no, primera en* no-loopback; si no, loopback.
    private func localIp() -> String {
        var addr = "127.0.0.1"
        var found = false
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return addr }
        var ptr = ifaddr
        while ptr != nil {
            let i = ptr!.pointee
            if let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: i.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: host)
                        if !ip.isEmpty && ip != "127.0.0.1" {
                            addr = ip
                            if name == "en0" { found = true }   // WiFi: preferida
                        }
                    }
                }
            }
            if found { break }
            ptr = i.ifa_next
        }
        freeifaddrs(ifaddr)
        return addr
    }
}
