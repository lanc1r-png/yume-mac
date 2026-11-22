import SwiftUI
import AVKit
import AVFoundation
import Foundation
import WebKit
import Security
import Network
import Combine
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import PhotosUI
#if os(macOS)
import AppKit
#endif

// MARK: - Веб-плеер (для плееров, которые не открываются в родном)

struct KinoWebTarget: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct KinoWebPlayerScreen: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                        .frame(width: 40, height: 40).background(Color.white.opacity(0.12), in: Circle())
                }
                Text(title).font(.headline).foregroundStyle(.white).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            KinoWebPlayer(url: url)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

struct KinoWebPlayer: UIViewRepresentable {
    let url: URL

    final class Coordinator: NSObject, WKUIDelegate {
        // реклама любит открывать новые окна — не пускаем
        func webView(_ v: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsPictureInPictureMediaPlayback = true
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.customUserAgent = KinoNet.ua
        v.uiDelegate = context.coordinator
        v.setOpaque(false)
        v.backgroundColor = .black
        v.scrollView.isScrollEnabled = url.host?.contains("kinomig") == true
        if url.host?.contains("kinomig") == true {
            v.load(URLRequest(url: url))
        } else {
            let html = """
            <!doctype html><html><head>
            <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
            <style>html,body{margin:0;height:100%;background:#000}
            iframe{position:absolute;top:0;left:0;width:100%;height:100%;border:0}</style>
            </head><body>
            <iframe src="\(url.absoluteString)" allow="autoplay; fullscreen; picture-in-picture; encrypted-media" allowfullscreen referrerpolicy="origin"></iframe>
            </body></html>
            """
            v.loadHTMLString(html, baseURL: URL(string: KinoNet.base + "/"))
        }
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {}
}


// MARK: - Перехват ответа плеера в невидимом браузере

@MainActor
final class KinoSniffer: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var cont: CheckedContinuation<String, Error>?
    private var web: WKWebView?
    private static var live: KinoSniffer?

    static let script = """
    (function(){
      if (window.__kinoSniff) return; window.__kinoSniff = true;
      function hit(u){ return /\\/bnsi\\/movies\\//.test(String(u)); }
      function post(t){ try { window.webkit.messageHandlers.kinosniff.postMessage(String(t)); } catch (e) {} }
      function m3(u){ u = String(u || ''); if (/\\.m3u8/.test(u)) post('M3U8 ' + new URL(u, location.href).href); }
      var of = window.fetch;
      if (of) window.fetch = function(a, o){
        var u = typeof a === 'string' ? a : (a && a.url);
        m3(u);
        var p = of.apply(this, arguments);
        if (hit(u)) p.then(function(r){ r.clone().text().then(post); }).catch(function(){});
        return p;
      };
      var oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(m, u){ this.__u = u; m3(u); return oo.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function(b){
        var x = this;
        if (hit(x.__u)) this.addEventListener('loadend', function(){ try { post(x.responseText); } catch (e) {} });
        return os.apply(this, arguments);
      };
    })();
    """

    /// Открывает страницу плеера и ждёт его ответ со ссылками (до 25 с)
    static func capture(_ url: URL) async throws -> String {
        let s = KinoSniffer()
        live = s
        defer { live = nil }
        return try await s.run(url)
    }

    private func run(_ url: URL) async throws -> String {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.userContentController.add(self, name: "kinosniff")
        cfg.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let v = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), configuration: cfg)
        v.customUserAgent = KinoNet.ua
        v.navigationDelegate = self
        v.alpha = 0.01
        v.isUserInteractionEnabled = false
        HiddenWebHost.attach(v)
        web = v
        // плеер открываем внутри страницы с адресом kinomig — как на сайте
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
        <body style="margin:0;background:#000">
        <iframe src="\(url.absoluteString)" style="border:0;width:100%;height:100%;position:absolute" allow="autoplay; fullscreen"></iframe>
        </body></html>
        """
        v.loadHTMLString(html, baseURL: URL(string: KinoNet.base + "/"))
        defer { cleanup() }
        return try await withThrowingTaskGroup(of: String.self) { g in
            g.addTask { @MainActor in
                try await withCheckedThrowingContinuation { c in self.cont = c }
            }
            g.addTask {
                try await Task.sleep(nanoseconds: 25_000_000_000)
                throw KinoError.player("плеер не ответил")
            }
            let r = try await g.next()!
            g.cancelAll()
            return r
        }
    }

    private func cleanup() {
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "kinosniff")
        web?.stopLoading()
        web?.removeFromSuperview()
        web = nil
        if let c = cont { cont = nil; c.resume(throwing: KinoError.player("плеер не ответил")) }
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        let body = m.body as? String ?? ""
        guard body.contains("hlsSource") || body.contains("m3u8"), let c = cont else { return }
        cont = nil
        c.resume(returning: body)
    }
}
