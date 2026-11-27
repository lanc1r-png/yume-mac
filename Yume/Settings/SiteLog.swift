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

// MARK: - Журнал запросов сайта (чтобы найти, как сайт хранит прогресс)
@MainActor
final class SiteLog: ObservableObject {
    @Published var lines: [String] = []

    private var seen = Set<String>()

    func add(_ s: String) {
        if lines.count > 1500 { lines.removeFirst(300) }
        lines.append(s)
    }

    /// Ресурсы страницы (скрипты, плееры, видео) — каждый адрес один раз
    func addOnce(_ key: String, _ s: String) {
        guard seen.insert(key).inserted else { return }
        add(s)
    }

    func clear() { lines = []; seen = [] }
}

/// Управление встроенным браузером журнала: адрес, назад/вперёд
@MainActor
final class WebBox: ObservableObject {
    weak var view: WKWebView?
    @Published var url = ""
    @Published var canBack = false
    @Published var canForward = false
}

struct SiteWebView: UIViewRepresentable {
    let url: URL
    let log: SiteLog
    /// Любой сайт: пишем все запросы, iframe-ы, видео и переходы, а не только API Lib-сайтов
    var everything = false
    var box: WebBox? = nil

    static func script(everything: Bool) -> String { """
    (function(){
      if (window.__heheLog) return; window.__heheLog = true;
      var EVERY = \(everything ? "true" : "false");
      function want(m, u){
        if (EVERY) return true;
        if (m !== 'GET') return true;
        return /cdnlibs\\.org|\\/api\\//i.test(String(u));
      }
      function host(){ try { return location.host; } catch (e) { return ''; } }
      function send(m, u, b, s, r){
        try {
          window.webkit.messageHandlers.hlog.postMessage(JSON.stringify({
            m: m, u: String(u), b: b ? String(b).slice(0, 400) : '', s: s || 0, f: host(), r: r || ''
          }));
        } catch (e) {}
      }
      // ответы пишем только для «любого сайта», без рекламы, картинок и кусков видео
      var noBody = /alloviewroll|prestreamnos|s2517\\.com|google|yandex|gnezdo|sape\\.ru|hybrid\\.ai|kimberlite|skcrtxr|kdmttk|cdn-cgi|\\.(m4s|ts|mp4|aac|jpe?g|png|webp|gif|woff2?)(\\?|#|$)/i;
      function wantBody(u){ return EVERY && !noBody.test(String(u)); }
      function cut(t){ t = String(t || ''); return t.length > 6000 ? t.slice(0, 6000) + ' …[обрезано, всего ' + t.length + ']' : t; }
      if (EVERY) {
        // HTML страницы и встроенных окон (в плеере обычно лежит список серий и озвучек)
        // страница без стилей, svg и больших скриптов — чтобы содержимое (карточки, подборки) влезло целиком;
        // маленькие встроенные скрипты оставляем: в них часто лежат данные (как fileList у плеера)
        function cleanHTML(){
          var d = document.documentElement.cloneNode(true);
          d.querySelectorAll('style, svg, noscript, link[rel="stylesheet"]').forEach(function(n){ n.remove(); });
          d.querySelectorAll('script').forEach(function(n){
            if (n.src || (n.textContent || '').length > 20000) n.remove();
          });
          d.querySelectorAll('[style]').forEach(function(n){ n.removeAttribute('style'); });
          return d.outerHTML.replace(/\\s{2,}/g, ' ');
        }
        function dumpHTML(tag){
          try {
            var top = (window === window.top);
            var h = cleanHTML();
            var lim = 200000;
            send((top ? 'HTML' : 'FRAME-HTML') + (tag || ''), location.href, '', 0, h.length > lim ? h.slice(0, lim) + ' …[обрезано, всего ' + h.length + ']' : h);
          } catch (e) {}
        }
        document.addEventListener('DOMContentLoaded', function(){ dumpHTML(''); });
        // и ещё раз после догрузки (подборки, ленивые карточки)
        window.addEventListener('load', function(){ setTimeout(function(){ dumpHTML('-LOADED'); }, 2500); });
      }
      if (EVERY) {
        var skip = /\\.(png|jpe?g|webp|gif|svg|ico|avif|woff2?|ttf|otf|css|ts|m4s|aac)(\\?|#|$)/i;
        try {
          new PerformanceObserver(function(l){
            l.getEntries().forEach(function(e){
              if (e.initiatorType === 'fetch' || e.initiatorType === 'xmlhttprequest') return;
              if (skip.test(e.name)) return;
              send('RES:' + e.initiatorType, e.name, '', 0);
            });
          }).observe({ type: 'resource', buffered: true });
        } catch (e) {}
        function frames(root){
          try { root.querySelectorAll('iframe').forEach(function(f){
            send('IFRAME', f.src || f.getAttribute('data-src') || f.getAttribute('data-lazy-src') || '(пусто)', '', 0);
          }); } catch (e) {}
        }
        document.addEventListener('DOMContentLoaded', function(){ frames(document); });
        try {
          new MutationObserver(function(ms){ ms.forEach(function(m){ m.addedNodes.forEach(function(n){
            if (n.tagName === 'IFRAME') send('IFRAME', n.src || n.getAttribute('data-src') || '(пусто)', '', 0);
            else if (n.querySelectorAll) frames(n);
          }); }); }).observe(document.documentElement, { childList: true, subtree: true });
        } catch (e) {}
        document.addEventListener('play', function(ev){
          var v = ev.target; if (v && (v.currentSrc || v.src)) send('VIDEO', v.currentSrc || v.src, '', 0);
        }, true);
      }
    """ + scriptTail }

    private static let scriptTail = """
      var of = window.fetch;
      if (of) window.fetch = function(a, o){
        var u = typeof a === 'string' ? a : (a && a.url);
        var m = ((o && o.method) || (a && a.method) || 'GET').toUpperCase();
        var b = o && o.body;
        var p = of.apply(this, arguments);
        p.then(function(r){
          if (!want(m, u)) return;
          if (wantBody(u)) {
            try { r.clone().text().then(function(t){ send(m, u, b, r.status, cut(t)); }).catch(function(){ send(m, u, b, r.status); }); }
            catch (e) { send(m, u, b, r.status); }
          } else { send(m, u, b, r.status); }
        }).catch(function(){});
        return p;
      };
      var oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(m, u){ this.__m = String(m).toUpperCase(); this.__u = u; return oo.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function(b){
        var x = this;
        this.addEventListener('loadend', function(){
          if (!want(x.__m, x.__u)) return;
          var t = '';
          try { if (wantBody(x.__u) && (x.responseType === '' || x.responseType === 'text')) t = cut(x.responseText); } catch (e) {}
          send(x.__m, x.__u, b, x.status, t);
        });
        return os.apply(this, arguments);
      };
    })();
    """

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let log: SiteLog
        let everything: Bool
        let box: WebBox?
        init(_ l: SiteLog, everything: Bool, box: WebBox?) { log = l; self.everything = everything; self.box = box }

        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard let t = m.body as? String,
                  let d = t.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            let method = o["m"] as? String ?? "?"
            let u = o["u"] as? String ?? ""
            let frame = (o["f"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let status = o["s"] as? Int ?? 0
            let line = "\(method) \(u)" + (status != 0 || !method.hasPrefix("RES") && method != "IFRAME" && method != "VIDEO" ? " [\(status)]" : "")
                + (everything ? (frame.map { "  ← \($0)" } ?? "") : "")
                + ((o["b"] as? String).flatMap { $0.isEmpty ? nil : "\n    тело: " + SiteWebView.mask($0) } ?? "")
            let resp = (o["r"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let full = line + (resp.map { "\n    ответ: " + SiteWebView.mask($0) } ?? "")
            let once = method.hasPrefix("RES") || method == "IFRAME" || method == "VIDEO" || method.hasSuffix("HTML")
            Task { @MainActor in
                if once { self.log.addOnce(method + u, full) } else { self.log.add(full) }
            }
        }

        // переходы страницы и встроенных окон (iframe)
        func webView(_ v: WKWebView, decidePolicyFor a: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if everything, let u = a.request.url?.absoluteString, u != "about:blank" {
                let main = a.targetFrame?.isMainFrame ?? true
                Task { @MainActor in self.log.addOnce((main ? "PAGE" : "FRAME") + u, (main ? "PAGE " : "FRAME ") + u) }
            }
            decisionHandler(.allow)
        }

        func webView(_ v: WKWebView, didFinish n: WKNavigation!) {
            Task { @MainActor in
                self.box?.url = v.url?.absoluteString ?? ""
                self.box?.canBack = v.canGoBack
                self.box?.canForward = v.canGoForward
            }
        }

        // всплывающие окна (часто реклама) не открываем, только записываем
        func webView(_ v: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let u = a.request.url?.absoluteString {
                Task { @MainActor in self.log.add("POPUP " + u + " (не открыто)") }
            }
            return nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(log, everything: everything, box: box) }

    /// Прячет секреты входа в теле запроса, чтобы журнал можно было спокойно пересылать.
    nonisolated static func mask(_ s: String) -> String {
        let pattern = #"("(?:code|code_verifier|access_token|refresh_token|token|password)"\s*:\s*")[^"]*"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1•••")
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.userContentController.add(context.coordinator, name: "hlog")
        cfg.userContentController.addUserScript(
            WKUserScript(source: Self.script(everything: everything), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.customUserAgent = Kodik.ua
        v.navigationDelegate = context.coordinator
        v.uiDelegate = context.coordinator
        v.allowsBackForwardNavigationGestures = true
        box?.view = v
        v.load(URLRequest(url: url))
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {}

    static func dismantleNSView(_ v: WKWebView, coordinator: Coordinator) {
        v.configuration.userContentController.removeScriptMessageHandler(forName: "hlog")
        v.stopLoading()
        v.loadHTMLString("", baseURL: nil)
    }
}

struct SiteLogView: View {
    var path: String = ""
    @StateObject private var log = SiteLog()
    @State private var showLog = false

    private var start: URL {
        let base: String
        switch LibSite.current.key {
        case "ranobe": base = "https://ranobelib.me/ru/"
        case "manga": base = "https://mangalib.me/ru/"
        case "hentai": base = "https://kz.hentailib.me/ru/"
        default: base = "https://animelib.org/ru/"
        }
        return URL(string: base + path) ?? URL(string: base)!
    }

    var body: some View {
        VStack(spacing: 0) {
            SiteWebView(url: start, log: log)
            Button { showLog = true } label: {
                Label("Журнал запросов: \(log.lines.count)", systemImage: "list.bullet.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
                    .padding(12)
            }
        }
        .navigationTitle("Сайт")
        .navigationBarTitleDisplayMode(.inline)
        .macSheet(isPresented: $showLog) {
            NavigationStack {
                ScrollView {
                    Text(log.lines.isEmpty ? "Пока пусто. Открой на сайте главу или серию, отметь прочитанное и вернись сюда." : log.lines.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .navigationTitle("Журнал")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { showLog = false } }
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack {
                            Button("Очистить") { log.clear() }
                            Button("Копировать") { UIPasteboard.general.string = log.lines.joined(separator: "\n") }
                        }
                    }
                }
            }
        }
    }
}

/// Журнал запросов для любого сайта: адресная строка, назад/вперёд, все запросы, iframe-ы плееров и видео
struct AnySiteLogView: View {
    @AppStorage("sitelog.lastURL") private var lastURL = "https://kinomig.tv/"
    @StateObject private var log = SiteLog()
    @StateObject private var box = WebBox()
    @State private var address = ""
    @State private var showLog = false
    @State private var started: URL?
    @FocusState private var editing: Bool

    private func normalized(_ t: String) -> URL? {
        var s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        return URL(string: s)
    }

    private func go() {
        guard let u = normalized(address) else { return }
        lastURL = u.absoluteString
        editing = false
        if let v = box.view { v.load(URLRequest(url: u)) } else { started = u }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { box.view?.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!box.canBack)
                Button { box.view?.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!box.canForward)
                TextField("Адрес сайта", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($editing)
                    .onSubmit { go() }
                    .font(.subheadline)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.chip, in: Capsule())
                Button { box.view?.reload() } label: { Image(systemName: "arrow.clockwise") }
            }
            .font(.headline)
            .padding(.horizontal, 12).padding(.vertical, 8)
            if let u = started {
                SiteWebView(url: u, log: log, everything: true, box: box)
            } else {
                Spacer()
            }
            Button { showLog = true } label: {
                Label("Журнал запросов: \(log.lines.count)", systemImage: "list.bullet.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
                    .padding(12)
            }
        }
        .navigationTitle("Любой сайт")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if started == nil {
                address = lastURL
                started = normalized(lastURL)
            }
        }
        .onChange(of: box.url) { _, u in if !editing, !u.isEmpty { address = u; lastURL = u } }
        .macSheet(isPresented: $showLog) {
            NavigationStack {
                ScrollView {
                    Text(log.lines.isEmpty
                         ? "Пока пусто. Открой страницу, запусти видео, покликай по сайту и вернись сюда."
                         : log.lines.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .navigationTitle("Журнал")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { showLog = false } }
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack {
                            Button("Очистить") { log.clear() }
                            Button("Копировать") { UIPasteboard.general.string = log.lines.joined(separator: "\n") }
                        }
                    }
                }
            }
        }
    }
}
