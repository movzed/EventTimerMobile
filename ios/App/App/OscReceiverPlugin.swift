import Foundation
import Network
import Capacitor

/// OscReceiver — recibe control remoto OSC por UDP (igual que el OSCReceiver del
/// Event Timer de escritorio y el plugin Android) y reenvía cada mensaje al
/// WebView del controlador llamando a window.__et_osc(addr, args).
///
/// En iOS 14+ recibir UDP en la red local requiere el permiso "Local Network"
/// (NSLocalNetworkUsageDescription en Info.plist); el sistema pide permiso la
/// primera vez que se empieza a escuchar.
@objc(OscReceiverPlugin)
public class OscReceiverPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "OscReceiverPlugin"
    public let jsName = "OscReceiver"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "isRunning", returnType: CAPPluginReturnPromise)
    ]

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "com.federico.eventtimer.osc-rx")
    private var boundPort: Int = 0

    @objc func start(_ call: CAPPluginCall) {
        let portInt = call.getInt("port") ?? 7700
        guard portInt >= 1, portInt <= 65535,
              let port = NWEndpoint.Port(rawValue: UInt16(portInt)) else {
            call.reject("invalid-port"); return
        }
        queue.async {
            self.stopInternal()
            do {
                let params = NWParameters.udp
                params.allowLocalEndpointReuse = true
                let l = try NWListener(using: params, on: port)
                var settled = false
                l.newConnectionHandler = { [weak self] conn in
                    guard let self = self else { return }
                    self.connections.append(conn)
                    conn.start(queue: self.queue)
                    self.receive(on: conn)
                }
                l.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        if settled { return }; settled = true
                        self?.boundPort = portInt
                        call.resolve(["running": true, "port": portInt])
                    case .failed(let err):
                        self?.stopInternal()
                        if settled { return }; settled = true
                        call.reject("bind-failed: \(err)")
                    default:
                        break
                    }
                }
                self.listener = l
                l.start(queue: self.queue)
            } catch {
                self.stopInternal()
                call.reject("bind-failed: \(error.localizedDescription)")
            }
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        queue.async {
            self.stopInternal()
            call.resolve(["running": false])
        }
    }

    @objc func isRunning(_ call: CAPPluginCall) {
        queue.async {
            call.resolve(["running": self.listener != nil, "port": self.boundPort])
        }
    }

    private func stopInternal() {
        for c in connections { c.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        boundPort = 0
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty { self.parsePacket([UInt8](data)) }
            if error != nil {
                conn.cancel()
            } else {
                self.receive(on: conn)   // sigue recibiendo datagramas del mismo origen
            }
        }
    }

    // MARK: - Parser OSC (mismo subconjunto que Android/escritorio)

    private func parsePacket(_ data: [UInt8]) {
        let len = data.count
        if len <= 0 { return }

        // OSC Bundle
        if len >= 8, startsWith(data, "#bundle") {
            var pos = 16   // "#bundle\0" (8) + timetag (8)
            while pos + 4 <= len {
                let msgLen = Int(readInt32(data, pos)); pos += 4
                if msgLen > 0, msgLen <= 65536, pos + msgLen <= len {
                    parsePacket(Array(data[pos..<(pos + msgLen)]))
                    pos += msgLen
                } else { break }
            }
            return
        }

        // OSC Message
        var pos = 0
        guard let addr = readString(data, len, &pos), !addr.isEmpty else { return }

        var args: [Any] = []
        if pos < len, data[pos] == UInt8(ascii: ",") {
            if let tags = readString(data, len, &pos) {
                let chars = Array(tags)
                var i = 1
                while i < chars.count {
                    let t = chars[i]
                    if t == "i" {
                        if pos + 4 > len { break }
                        args.append(Int(readInt32(data, pos))); pos += 4
                    } else if t == "f" {
                        if pos + 4 > len { break }
                        let raw = UInt32(bitPattern: readInt32(data, pos))
                        let f = Float(bitPattern: raw)
                        args.append(f.isFinite ? Double(f) : 0.0); pos += 4
                    } else if t == "s" {
                        if let s = readString(data, len, &pos) { args.append(s) }
                    } else if t == "T" {
                        args.append(true)
                    } else if t == "F" {
                        args.append(false)
                    }
                    // tipos desconocidos: se ignoran
                    i += 1
                }
            }
        }
        forward(addr, args)
    }

    private func forward(_ addr: String, _ args: [Any]) {
        let payload: [Any] = [addr, args]
        guard JSONSerialization.isValidJSONObject(payload),
              let d = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: d, encoding: .utf8) else { return }
        // U+2028/U+2029 son válidos en JSON pero rompen un literal JS pre-ES2019.
        let safe = json
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        let js = "window.__et_osc && window.__et_osc.apply(null, \(safe))"
        DispatchQueue.main.async { [weak self] in
            self?.bridge?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - Helpers de bytes

    private func startsWith(_ data: [UInt8], _ s: String) -> Bool {
        let b = Array(s.utf8)
        if data.count < b.count { return false }
        for i in 0..<b.count where data[i] != b[i] { return false }
        return true
    }

    /// Cadena OSC null-terminada; avanza pos al múltiplo de 4 siguiente.
    private func readString(_ data: [UInt8], _ len: Int, _ pos: inout Int) -> String? {
        let start = pos
        while pos < len, data[pos] != 0 { pos += 1 }
        let s = String(bytes: data[start..<pos], encoding: .utf8)
        pos += 1                 // salta el null
        pos = (pos + 3) & ~3     // alinea a 4 bytes
        return s
    }

    /// int32 big-endian; 0 si se sale del buffer.
    private func readInt32(_ data: [UInt8], _ pos: Int) -> Int32 {
        if pos + 4 > data.count { return 0 }
        let b0 = Int32(data[pos]) << 24
        let b1 = Int32(data[pos + 1]) << 16
        let b2 = Int32(data[pos + 2]) << 8
        let b3 = Int32(data[pos + 3])
        return b0 | b1 | b2 | b3
    }
}
