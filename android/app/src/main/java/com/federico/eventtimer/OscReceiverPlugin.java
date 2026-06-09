package com.federico.eventtimer;

import android.content.Context;
import android.net.wifi.WifiManager;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import org.json.JSONArray;
import org.json.JSONObject;

import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetSocketAddress;
import java.util.Arrays;

/**
 * OscReceiver — recibe control remoto OSC por UDP (igual que el OSCReceiver del
 * Event Timer de escritorio) y reenvía cada mensaje al WebView del controlador
 * llamando a window.__et_osc(addr, args). El navegador web NO puede hacer bind
 * de UDP; por eso esto vive en el plugin nativo (solo build Android).
 *
 * Direcciones soportadas (las despacha control.html): /play /pause /stop /reset
 * /thunder /adjust /plus /minus /preset/N, con prefijos opcionales
 * /eventtimer/* o /timer/*.
 */
@CapacitorPlugin(name = "OscReceiver")
public class OscReceiverPlugin extends Plugin {

    private volatile DatagramSocket socket;
    private Thread thread;
    private WifiManager.MulticastLock multicastLock;
    private volatile int boundPort = -1;

    @PluginMethod
    public void start(PluginCall call) {
        int port = call.getInt("port", 7700);
        if (port < 1 || port > 65535) { call.reject("invalid-port"); return; }
        try {
            stopInternal();                       // idempotente: cierra cualquier socket previo
            DatagramSocket s = new DatagramSocket(null);
            s.setReuseAddress(true);
            s.bind(new InetSocketAddress(port));
            socket = s;
            boundPort = port;
            acquireMulticastLock();
            Thread t = new Thread(this::loop, "osc-rx");
            t.setDaemon(true);
            thread = t;
            t.start();
            JSObject ret = new JSObject();
            ret.put("running", true);
            ret.put("port", port);
            call.resolve(ret);
        } catch (Exception e) {
            stopInternal();
            call.reject("bind-failed: " + e.getMessage());
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
        DatagramSocket s = socket;
        JSObject ret = new JSObject();
        ret.put("running", s != null && !s.isClosed());
        ret.put("port", boundPort);
        call.resolve(ret);
    }

    // ─── Bucle de recepción (hilo en segundo plano) ──────────────────────────
    private void loop() {
        byte[] buf = new byte[4096];
        DatagramSocket s = socket;
        while (s != null && !s.isClosed()) {
            try {
                DatagramPacket pkt = new DatagramPacket(buf, buf.length);
                s.receive(pkt);
                parsePacket(buf, pkt.getLength());
            } catch (Exception e) {
                break;                            // socket cerrado o error → termina el hilo
            }
        }
    }

    private void stopInternal() {
        DatagramSocket s = socket;
        socket = null;
        if (s != null) s.close();                 // desbloquea receive()
        Thread t = thread;
        thread = null;
        if (t != null) t.interrupt();
        releaseMulticastLock();
        boundPort = -1;
    }

    @Override
    protected void handleOnDestroy() {
        stopInternal();
        super.handleOnDestroy();
    }

    // ─── Parser OSC (mismo subconjunto que el OSCReceiver de escritorio) ──────
    private void parsePacket(byte[] data, int len) {
        if (len <= 0) return;

        // OSC Bundle
        if (len >= 8 && startsWith(data, len, "#bundle")) {
            int pos = 16;                         // "#bundle\0" (8) + timetag (8)
            while (pos + 4 <= len) {
                int msgLen = readInt32(data, pos);
                pos += 4;
                if (msgLen > 0 && msgLen <= 65536 && pos + msgLen <= len) {
                    parsePacket(Arrays.copyOfRange(data, pos, pos + msgLen), msgLen);
                    pos += msgLen;
                } else break;
            }
            return;
        }

        // OSC Message
        int[] pos = { 0 };
        String addr = readString(data, len, pos);
        if (addr == null || addr.isEmpty()) return;

        JSONArray args = new JSONArray();
        if (pos[0] < len && data[pos[0]] == ',') {
            String typeTags = readString(data, len, pos);
            for (int i = 1; i < typeTags.length(); i++) {
                char t = typeTags.charAt(i);
                if (t == 'i') {
                    if (pos[0] + 4 > len) break;
                    args.put(readInt32(data, pos[0]));
                    pos[0] += 4;
                } else if (t == 'f') {
                    if (pos[0] + 4 > len) break;
                    float f = Float.intBitsToFloat(readInt32(data, pos[0]));
                    boolean finite = !Float.isNaN(f) && !Float.isInfinite(f);
                    // put(Object) no declara JSONException (a diferencia de put(double));
                    // la guarda evita NaN/Inf que romperían el JSON serializado.
                    args.put((Object) Double.valueOf(finite ? (double) f : 0.0));
                    pos[0] += 4;
                } else if (t == 's') {
                    args.put(readString(data, len, pos));
                } else if (t == 'T') {
                    args.put(true);
                } else if (t == 'F') {
                    args.put(false);
                }
                // tipos desconocidos: se ignoran
            }
        }
        forward(addr, args);
    }

    private void forward(final String addr, final JSONArray args) {
        final String js = "window.__et_osc && window.__et_osc("
                + JSONObject.quote(addr) + "," + args.toString() + ")";
        getActivity().runOnUiThread(() -> {
            try {
                if (getBridge() != null && getBridge().getWebView() != null) {
                    getBridge().getWebView().evaluateJavascript(js, null);
                }
            } catch (Exception ignored) {}
        });
    }

    // ─── Helpers de bytes ────────────────────────────────────────────────────
    private static boolean startsWith(byte[] data, int len, String prefix) {
        if (len < prefix.length()) return false;
        for (int i = 0; i < prefix.length(); i++) {
            if (data[i] != (byte) prefix.charAt(i)) return false;
        }
        return true;
    }

    /** Lee una cadena OSC null-terminada y avanza pos al múltiplo de 4 siguiente. */
    private static String readString(byte[] data, int len, int[] pos) {
        int start = pos[0];
        while (pos[0] < len && data[pos[0]] != 0) pos[0]++;
        String s = new String(data, start, pos[0] - start, java.nio.charset.StandardCharsets.UTF_8);
        pos[0]++;                                 // salta el null
        pos[0] = (pos[0] + 3) & ~3;               // alinea a 4 bytes
        return s;
    }

    /** Lee un int32 big-endian; 0 si se sale del buffer. */
    private static int readInt32(byte[] data, int pos) {
        if (pos + 4 > data.length) return 0;
        return ((data[pos] & 0xFF) << 24)
             | ((data[pos + 1] & 0xFF) << 16)
             | ((data[pos + 2] & 0xFF) << 8)
             |  (data[pos + 3] & 0xFF);
    }

    // ─── Multicast lock (para recibir OSC enviado por broadcast en la LAN) ────
    private void acquireMulticastLock() {
        try {
            WifiManager wifi = (WifiManager) getContext().getApplicationContext()
                    .getSystemService(Context.WIFI_SERVICE);
            if (wifi != null) {
                multicastLock = wifi.createMulticastLock("et-osc");
                multicastLock.setReferenceCounted(false);
                multicastLock.acquire();
            }
        } catch (Exception ignored) {}
    }

    private void releaseMulticastLock() {
        try {
            if (multicastLock != null && multicastLock.isHeld()) multicastLock.release();
        } catch (Exception ignored) {}
        multicastLock = null;
    }
}
