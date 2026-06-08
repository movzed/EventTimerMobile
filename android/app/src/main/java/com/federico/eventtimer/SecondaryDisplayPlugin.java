package com.federico.eventtimer;

import android.app.Presentation;
import android.content.Context;
import android.hardware.display.DisplayManager;
import android.os.Bundle;
import android.view.Display;
import android.view.ViewGroup;
import android.view.ViewParent;
import android.view.WindowManager;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import java.util.ArrayList;

/**
 * SecondaryDisplay — muestra display.html a pantalla completa en una pantalla
 * externa (proyector / monitor HDMI/USB-C) usando la Android Presentation API,
 * mientras el dispositivo sigue mostrando el controlador (control.html).
 *
 * El estado del timer se empuja desde control.html via push(msg) y se inyecta
 * en el WebView de la Presentation llamando a window.__et_apply(msg).
 */
@CapacitorPlugin(name = "SecondaryDisplay")
public class SecondaryDisplayPlugin extends Plugin {

    private ClockPresentation presentation;
    private String lastJson = null;

    private DisplayManager dm() {
        return (DisplayManager) getContext().getSystemService(Context.DISPLAY_SERVICE);
    }

    @PluginMethod
    public void getDisplays(PluginCall call) {
        Display[] displays = dm().getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION);
        JSArray arr = new JSArray();
        for (Display d : displays) {
            JSObject o = new JSObject();
            o.put("id", d.getDisplayId());
            o.put("name", d.getName());
            android.graphics.Point size = new android.graphics.Point();
            d.getRealSize(size);
            o.put("width", size.x);
            o.put("height", size.y);
            arr.put(o);
        }
        JSObject ret = new JSObject();
        ret.put("displays", arr);
        call.resolve(ret);
    }

    @PluginMethod
    public void show(PluginCall call) {
        Display[] displays = dm().getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION);
        if (displays.length == 0) {
            JSObject ret = new JSObject();
            ret.put("shown", false);
            ret.put("reason", "no-external-display");
            call.resolve(ret);
            return;
        }
        final Display target = displays[0];
        getActivity().runOnUiThread(() -> {
            try {
                dismissPresentation();
                presentation = new ClockPresentation(getActivity(), target);
                // Si el sistema cierra la Presentation (p.ej. al desconectar la
                // pantalla externa), libera el WebView para no fugar.
                presentation.setOnDismissListener(d -> {
                    if (presentation != null) {
                        ClockPresentation p = presentation;
                        presentation = null;
                        p.destroyWebView();
                    }
                });
                presentation.show();
                if (lastJson != null) presentation.apply(lastJson);
                JSObject ret = new JSObject();
                ret.put("shown", true);
                ret.put("displayId", target.getDisplayId());
                ret.put("displayName", target.getName());
                call.resolve(ret);
            } catch (Exception e) {
                call.reject("show-failed: " + e.getMessage());
            }
        });
    }

    @PluginMethod
    public void hide(PluginCall call) {
        getActivity().runOnUiThread(() -> {
            dismissPresentation();
            call.resolve();
        });
    }

    @PluginMethod
    public void push(PluginCall call) {
        lastJson = call.getData().toString();
        final String json = lastJson;
        getActivity().runOnUiThread(() -> {
            if (presentation != null) presentation.apply(json);
        });
        call.resolve();
    }

    /** Cierra y libera la Presentation actual (idempotente). Debe ir en UI thread. */
    private void dismissPresentation() {
        if (presentation != null) {
            ClockPresentation p = presentation;
            presentation = null;          // null antes de dismiss -> el listener no re-entra
            p.dismiss();
            p.destroyWebView();
        }
    }

    /** Diálogo atado a un Display concreto que hospeda un WebView con display.html. */
    static class ClockPresentation extends Presentation {
        private WebView webView;
        private boolean loaded = false;
        private final ArrayList<String> pending = new ArrayList<>();

        ClockPresentation(Context outerContext, Display display) {
            super(outerContext, display);
        }

        @Override
        protected void onCreate(Bundle savedInstanceState) {
            super.onCreate(savedInstanceState);
            getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

            webView = new WebView(getContext());
            WebSettings ws = webView.getSettings();
            ws.setJavaScriptEnabled(true);
            ws.setDomStorageEnabled(true);
            ws.setAllowFileAccess(true);
            ws.setMediaPlaybackRequiresUserGesture(false);
            webView.setBackgroundColor(0xFF000000);
            webView.setWebViewClient(new WebViewClient() {
                @Override
                public void onPageFinished(WebView v, String url) {
                    loaded = true;
                    for (String p : pending) inject(p);   // entrega TODO lo encolado (state + logo) en orden
                    pending.clear();
                }
            });
            setContentView(webView, new ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT));
            webView.loadUrl("file:///android_asset/public/display.html");
        }

        void apply(String json) {
            if (webView == null) return;
            if (!loaded) { pending.add(json); return; }   // cola, no un solo slot
            inject(json);
        }

        private void inject(String json) {
            // Escapa U+2028/U+2029 (terminadores de línea válidos en JSON pero que
            // rompen un literal JS pre-ES2019) por si el operador los teclea/pega.
            // Nota: no se puede escribir " " en el fuente Java (el compilador lo
            // trata como salto de línea), por eso usamos (char) 0x2028.
            final String safe = json
                    .replace(String.valueOf((char) 0x2028), "\\u2028")
                    .replace(String.valueOf((char) 0x2029), "\\u2029");
            webView.post(() -> {
                if (webView != null) {
                    webView.evaluateJavascript("window.__et_apply && window.__et_apply(" + safe + ")", null);
                }
            });
        }

        /** Libera el WebView (evita fugas en cada ciclo show/hide). Idempotente. */
        void destroyWebView() {
            if (webView != null) {
                WebView w = webView;
                webView = null;
                try {
                    w.loadUrl("about:blank");
                    ViewParent parent = w.getParent();
                    if (parent instanceof ViewGroup) ((ViewGroup) parent).removeView(w);
                    w.destroy();
                } catch (Exception ignored) {}
            }
        }
    }
}
