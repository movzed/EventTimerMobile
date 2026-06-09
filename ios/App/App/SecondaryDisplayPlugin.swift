import Foundation
import UIKit
import WebKit
import Capacitor

/// SecondaryDisplay — muestra display.html a pantalla completa en una pantalla
/// externa (proyector / monitor por USB-C/HDMI o AirPlay) usando una UIWindow
/// sobre la UIScreen externa, mientras el dispositivo sigue mostrando el
/// controlador. Equivale al plugin Android basado en Presentation API.
///
/// El estado se empuja desde control.html con push(msg) y se inyecta en el
/// WebView de la pantalla externa llamando a window.__et_apply(msg).
@objc(SecondaryDisplayPlugin)
public class SecondaryDisplayPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "SecondaryDisplayPlugin"
    public let jsName = "SecondaryDisplay"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "getDisplays", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "show", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "hide", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "push", returnType: CAPPluginReturnPromise)
    ]

    private var extWindow: UIWindow?
    private var extWebView: WKWebView?
    private var navDelegate: NavDelegate?
    private var loaded = false
    private var pending: [String] = []
    private var lastJson: String?

    @objc func getDisplays(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            var arr: [[String: Any]] = []
            for (idx, s) in UIScreen.screens.enumerated() where idx > 0 {
                arr.append([
                    "id": idx,
                    "name": "External \(idx)",
                    "width": Int(s.bounds.width * s.scale),
                    "height": Int(s.bounds.height * s.scale)
                ])
            }
            call.resolve(["displays": arr])
        }
    }

    @objc func show(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let screens = UIScreen.screens
            guard screens.count > 1 else {
                call.resolve(["shown": false, "reason": "no-external-display"]); return
            }
            let screen = screens[1]
            self.teardown()

            let config = WKWebViewConfiguration()
            config.allowsInlineMediaPlayback = true
            let webView = WKWebView(frame: screen.bounds, configuration: config)
            webView.isOpaque = true
            webView.backgroundColor = .black
            webView.scrollView.isScrollEnabled = false
            webView.scrollView.bounces = false
            let nav = NavDelegate(plugin: self)
            webView.navigationDelegate = nav
            self.navDelegate = nav

            let vc = UIViewController()
            vc.view = webView

            let window = UIWindow(frame: screen.bounds)
            window.screen = screen
            window.rootViewController = vc
            window.isHidden = false

            self.extWindow = window
            self.extWebView = webView
            self.loaded = false
            self.pending.removeAll()

            guard let url = Bundle.main.url(forResource: "display", withExtension: "html", subdirectory: "public") else {
                self.teardown()
                call.reject("display.html-not-found")
                return
            }
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            if let last = self.lastJson { self.apply(last) }

            NotificationCenter.default.addObserver(
                self, selector: #selector(self.screenDidDisconnect(_:)),
                name: UIScreen.didDisconnectNotification, object: nil)

            call.resolve([
                "shown": true,
                "displayId": 1,
                "displayName": "External 1",
                "width": Int(screen.bounds.width * screen.scale),
                "height": Int(screen.bounds.height * screen.scale)
            ])
        }
    }

    @objc func hide(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.teardown()
            call.resolve()
        }
    }

    @objc func push(_ call: CAPPluginCall) {
        var opts = (call.options as? [String: Any]) ?? [:]
        opts.removeValue(forKey: "callbackId")   // clave interna del bridge, por si aparece
        guard JSONSerialization.isValidJSONObject(opts),
              let d = try? JSONSerialization.data(withJSONObject: opts),
              let json = String(data: d, encoding: .utf8) else {
            call.resolve(); return
        }
        lastJson = json
        DispatchQueue.main.async { self.apply(json) }
        call.resolve()
    }

    // MARK: - Inyección

    private func apply(_ json: String) {
        guard let webView = extWebView else { return }
        if !loaded { pending.append(json); return }   // cola hasta que cargue display.html
        inject(json, into: webView)
    }

    private func inject(_ json: String, into webView: WKWebView) {
        let safe = json
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        let js = "window.__et_apply && window.__et_apply(\(safe))"
        DispatchQueue.main.async { webView.evaluateJavaScript(js, completionHandler: nil) }
    }

    fileprivate func onLoaded(_ webView: WKWebView) {
        loaded = true
        for p in pending { inject(p, into: webView) }
        pending.removeAll()
    }

    private func teardown() {
        NotificationCenter.default.removeObserver(self, name: UIScreen.didDisconnectNotification, object: nil)
        extWebView?.navigationDelegate = nil
        extWebView?.stopLoading()
        extWebView = nil
        navDelegate = nil
        extWindow?.isHidden = true
        extWindow = nil
        loaded = false
        pending.removeAll()
    }

    @objc private func screenDidDisconnect(_ note: Notification) {
        DispatchQueue.main.async { self.teardown() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Delegate de navegación: vacía la cola pendiente cuando display.html acaba de cargar.
    private class NavDelegate: NSObject, WKNavigationDelegate {
        weak var plugin: SecondaryDisplayPlugin?
        init(plugin: SecondaryDisplayPlugin) { self.plugin = plugin }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            plugin?.onLoaded(webView)
        }
    }
}
