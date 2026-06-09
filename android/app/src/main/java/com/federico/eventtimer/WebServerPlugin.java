package com.federico.eventtimer;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import java.io.IOException;
import java.io.InputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.Enumeration;
import java.util.concurrent.CopyOnWriteArrayList;

import fi.iki.elonen.NanoHTTPD;
import fi.iki.elonen.NanoWSD;

/**
 * WebServer — sirve el reloj (display.html + assets) por HTTP y empuja el estado
 * por WebSocket a cualquier dispositivo de la LAN (navegador, smart TV, OBS/vMix
 * browser source). El WebView no puede abrir un socket de escucha; por eso el
 * servidor vive aquí, en código nativo. HTTP y WebSocket comparten puerto (NanoWSD).
 */
@CapacitorPlugin(name = "WebServer")
public class WebServerPlugin extends Plugin {

    private EtServer server;
    private final CopyOnWriteArrayList<EtSocket> sockets = new CopyOnWriteArrayList<>();
    private int boundPort = -1;

    @PluginMethod
    public void start(PluginCall call) {
        int port = call.getInt("port", 9000);
        try {
            stopInternal();
            server = new EtServer(port);
            server.start(NanoHTTPD.SOCKET_READ_TIMEOUT, false);
            boundPort = port;
            String ip = getLocalIp();
            JSObject ret = new JSObject();
            ret.put("running", true);
            ret.put("port", port);
            ret.put("ip", ip);
            ret.put("url", "http://" + ip + ":" + port + "/");
            call.resolve(ret);
        } catch (Exception e) {
            stopInternal();
            call.reject("start-failed: " + e.getMessage());
        }
    }

    @PluginMethod
    public void stop(PluginCall call) {
        stopInternal();
        JSObject ret = new JSObject();
        ret.put("running", false);
        call.resolve(ret);
    }

    @PluginMethod
    public void isRunning(PluginCall call) {
        boolean run = server != null && server.isAlive();
        JSObject ret = new JSObject();
        ret.put("running", run);
        ret.put("clients", sockets.size());
        if (run) ret.put("url", "http://" + getLocalIp() + ":" + boundPort + "/");
        call.resolve(ret);
    }

    @PluginMethod
    public void broadcast(PluginCall call) {
        String json = call.getString("json");
        if (json != null) {
            for (EtSocket s : sockets) {
                try { s.send(json); } catch (Exception e) { sockets.remove(s); }
            }
        }
        call.resolve();
    }

    private void stopInternal() {
        if (server != null) {
            try { server.stop(); } catch (Exception ignored) {}
            server = null;
        }
        sockets.clear();
        boundPort = -1;
    }

    @Override
    protected void handleOnDestroy() {
        stopInternal();
        super.handleOnDestroy();
    }

    /** IPv4 no-loopback de la primera interfaz activa (WiFi/Ethernet/USB). */
    private String getLocalIp() {
        try {
            for (Enumeration<NetworkInterface> en = NetworkInterface.getNetworkInterfaces(); en.hasMoreElements();) {
                NetworkInterface intf = en.nextElement();
                if (intf.isLoopback() || !intf.isUp()) continue;
                for (Enumeration<InetAddress> ips = intf.getInetAddresses(); ips.hasMoreElements();) {
                    InetAddress addr = ips.nextElement();
                    if (!addr.isLoopbackAddress() && addr instanceof Inet4Address) return addr.getHostAddress();
                }
            }
        } catch (Exception ignored) {}
        return "127.0.0.1";
    }

    private static String mimeOf(String path) {
        String p = path.toLowerCase();
        if (p.endsWith(".html")) return "text/html";
        if (p.endsWith(".js"))   return "application/javascript";
        if (p.endsWith(".css"))  return "text/css";
        if (p.endsWith(".png"))  return "image/png";
        if (p.endsWith(".svg"))  return "image/svg+xml";
        if (p.endsWith(".gif"))  return "image/gif";
        if (p.endsWith(".webp")) return "image/webp";
        if (p.endsWith(".json") || p.endsWith(".webmanifest")) return "application/json";
        if (p.endsWith(".ico"))  return "image/x-icon";
        return "application/octet-stream";
    }

    // ── Servidor HTTP + WebSocket en el mismo puerto ─────────────────────────
    private class EtServer extends NanoWSD {
        EtServer(int port) { super(port); }

        @Override
        protected WebSocket openWebSocket(IHTTPSession handshake) {
            return new EtSocket(handshake);
        }

        @Override
        protected Response serveHttp(IHTTPSession session) {
            String uri = session.getUri();
            if (uri == null || uri.equals("/") || uri.isEmpty()) uri = "/display.html";
            String asset = "public" + uri;   // los assets web se bundlean en assets/public/
            try {
                InputStream is = getContext().getAssets().open(asset);
                Response r = newChunkedResponse(Response.Status.OK, mimeOf(uri), is);
                r.addHeader("Access-Control-Allow-Origin", "*");
                r.addHeader("Cache-Control", "no-store");
                return r;
            } catch (IOException e) {
                return newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain", "404 Not Found");
            }
        }
    }

    private class EtSocket extends NanoWSD.WebSocket {
        EtSocket(NanoHTTPD.IHTTPSession handshakeRequest) { super(handshakeRequest); }
        @Override protected void onOpen() { sockets.addIfAbsent(this); }
        @Override protected void onClose(NanoWSD.WebSocketFrame.CloseCode code, String reason, boolean remote) { sockets.remove(this); }
        @Override protected void onMessage(NanoWSD.WebSocketFrame message) { /* el viewer no envía */ }
        @Override protected void onPong(NanoWSD.WebSocketFrame pong) {}
        @Override protected void onException(IOException exception) { sockets.remove(this); }
    }
}
