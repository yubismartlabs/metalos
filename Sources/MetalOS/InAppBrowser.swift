import AppKit
import SwiftUI
import WebKit

@MainActor
final class InAppBrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView = WKWebView()
    @Published var address = "https://www.google.com"
    @Published var pageTitle = "New Tab"
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var authorizationCode = ""
    @Published var downloadStatus = ""
    @Published var pageInputText = ""
    @Published var pageInputIsSecure = false

    override init() {
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: URL(string: address)!))
    }

    func loadAddress(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if value.split(whereSeparator: \.isWhitespace).count > 1 || (!value.contains(".") && !value.contains("://")) {
            var search = URLComponents(string: "https://www.google.com/search")!
            search.queryItems = [URLQueryItem(name: "q", value: value)]
            guard let url = search.url else { return }
            address = url.absoluteString
            webView.load(URLRequest(url: url))
            return
        }
        let candidate = value.contains("://") ? value : "https://\(value)"
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
        address = url.absoluteString
        webView.load(URLRequest(url: url))
    }
    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }
    func reload() { if isLoading { webView.stopLoading() } else { webView.reload() } }
    func movePageFocus(_ direction: String) {
        let step = direction == "up" || direction == "left" ? -1 : 1
        webView.evaluateJavaScript("""
        (() => {
          const els = [...document.querySelectorAll('a[href],button,input,textarea,select,[role="button"],[tabindex]:not([tabindex="-1"])')]
            .filter(e => { const r=e.getBoundingClientRect(),s=getComputedStyle(e); return r.width>0 && r.height>0 && s.visibility!=='hidden' && s.display!=='none' && !e.disabled; });
          if (!els.length) return false;
          let i = els.indexOf(document.activeElement);
          i = (i + \(step) + els.length) % els.length;
          window.__metalOSFocusIndex = i;
          els.forEach(e => { e.style.outline=''; e.style.outlineOffset=''; });
          const el=els[i]; el.focus({preventScroll:true}); el.style.outline='3px solid #1680ff'; el.style.outlineOffset='3px';
          el.scrollIntoView({block:'center', inline:'nearest', behavior:'smooth'});
          return true;
        })()
        """)
    }
    func activatePageFocus(_ completion: @escaping (Bool) -> Void) {
        webView.evaluateJavaScript("""
        (() => { const e=document.activeElement; if (!e) return {text:false};
          const tag=e.tagName?.toLowerCase(), type=e.type?.toLowerCase();
          const text=['input','textarea'].includes(tag) || e.isContentEditable;
          if (!text) { e.click?.(); if (tag==='a' || tag==='button' || e.getAttribute('role')==='button') e.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true})); }
          return {text, type:type||'', value:e.isContentEditable?(e.innerText||''):(e.value||'')}; })()
        """) { result, _ in
            let detail = result as? [String: Any] ?? [:]
            let needsText = detail["text"] as? Bool == true
            if needsText {
                self.pageInputText = detail["value"] as? String ?? ""
                self.pageInputIsSecure = (detail["type"] as? String) == "password"
            }
            completion(needsText)
        }
    }
    func submitText(_ value: String) {
        let quoted = (try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        let text = String(quoted.dropFirst().dropLast())
        webView.evaluateJavaScript("""
        (() => { const e=document.activeElement, v=\(text); if (!e) return;
          if (e.isContentEditable) e.innerText=v;
          else { const p=Object.getPrototypeOf(e), d=Object.getOwnPropertyDescriptor(p,'value'); if(d?.set)d.set.call(e,v); else e.value=v; }
          e.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:v}));
          e.dispatchEvent(new Event('change',{bubbles:true})); })()
        """)
    }
    func scrollPage(_ direction: String) {
        let y = direction == "up" ? -420 : 420
        webView.evaluateJavaScript("window.scrollBy({top:\(y),behavior:'smooth'})")
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { sync(webView); isLoading = true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        sync(webView); isLoading = false
        webView.evaluateJavaScript("""
        (() => { const t=document.body?.innerText||''; const m=t.match(/(?:authorizationCode|\"code\")\\s*:\\s*\"([^\"]+)\"/); return m?.[1]||''; })()
        """) { [weak self] value, _ in
            if let code = value as? String, !code.isEmpty { self?.authorizationCode = code }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { sync(webView); isLoading = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { sync(webView); isLoading = false }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let url = navigationResponse.response.url,
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let code = components.queryItems?.first(where: { $0.name == "code" || $0.name == "authorizationCode" })?.value,
           !code.isEmpty { authorizationCode = code }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { completionHandler(nil); return }
            Task { @MainActor in self?.downloadStatus = "Saving \(url.lastPathComponent)…" }
            completionHandler(url)
        }
    }
    func downloadDidFinish(_ download: WKDownload) { downloadStatus = "Download complete" }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadStatus = "Download failed: \(error.localizedDescription)"
    }
    private func sync(_ webView: WKWebView) {
        address = webView.url?.absoluteString ?? address
        pageTitle = webView.title ?? "Browser"
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
}

struct InAppBrowserView: View {
    @ObservedObject var session: InAppBrowserSession
    var authorizationCompletion: ((String) -> Void)? = nil
    var close: (() -> Void)? = nil
    var closeTitle = "Games"
    @State private var addressDraft = ""
    @State private var toolbarFocus = 0
    @State private var keyboardOpen = false
    @State private var keyboardText = ""
    @State private var keyboardIsSecure = false
    @State private var keyboardTargetIsAddress = false
    @State private var keyboardTargetIsAuthCode = false
    private var closeOffset: Int { close == nil ? 0 : 1 }
    private var backIndex: Int { closeOffset }
    private var forwardIndex: Int { closeOffset + 1 }
    private var reloadIndex: Int { closeOffset + 2 }
    private var addressIndex: Int { closeOffset + 3 }
    private var goIndex: Int { closeOffset + 4 }
    private var pageIndex: Int { closeOffset + 5 }
    private var authCodeIndex: Int { closeOffset + 6 }
    private var connectIndex: Int { closeOffset + 7 }

    var body: some View {
        VStack(spacing: 0) {
            if let close {
                HStack(spacing: 12) {
                    Button { close() } label: { Label(closeTitle, systemImage: closeTitle == "Games" ? "gamecontroller.fill" : "xmark") }
                        .buttonStyle(ConsoleButtonStyle()).consoleFocus(toolbarFocus == 0, cornerRadius: 8)
                    Text("INTERNET BROWSER").font(.system(size: 10, weight: .bold)).tracking(1.7).foregroundStyle(.white.opacity(0.58))
                    Spacer()
                    Text(session.pageTitle).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.52)).lineLimit(1)
                }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 3)
            }
            HStack(spacing: 9) {
                Button { toolbarFocus = backIndex; session.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!session.canGoBack).consoleFocus(toolbarFocus == backIndex, cornerRadius: 8)
                Button { toolbarFocus = forwardIndex; session.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!session.canGoForward).consoleFocus(toolbarFocus == forwardIndex, cornerRadius: 8)
                Button { toolbarFocus = reloadIndex; session.reload() } label: { Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise") }
                    .consoleFocus(toolbarFocus == reloadIndex, cornerRadius: 8)
                TextField("Search or enter address", text: $addressDraft)
                    .textFieldStyle(.roundedBorder).onSubmit { session.loadAddress(addressDraft) }
                    .onTapGesture { toolbarFocus = addressIndex }
                    .consoleFocus(toolbarFocus == addressIndex, cornerRadius: 7)
                Button("Go") { toolbarFocus = goIndex; session.loadAddress(addressDraft) }
                    .consoleFocus(toolbarFocus == goIndex, cornerRadius: 8)
            }.buttonStyle(ConsoleButtonStyle()).padding(11)
            BrowserWebView(session: session).frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    Text(session.pageTitle).font(.system(size: 10, weight: .medium)).lineLimit(1)
                        .foregroundStyle(.white.opacity(0.01)).padding(2)
                }
            if let authorizationCompletion {
                HStack(spacing: 8) {
                    TextField("Authorization code", text: $session.authorizationCode).textFieldStyle(.roundedBorder)
                        .onTapGesture { toolbarFocus = authCodeIndex }
                        .consoleFocus(toolbarFocus == authCodeIndex, cornerRadius: 7)
                    Button("Connect") { toolbarFocus = connectIndex; authorizationCompletion(session.authorizationCode) }
                        .buttonStyle(.borderedProminent).tint(studioAccent)
                        .consoleFocus(toolbarFocus == connectIndex, cornerRadius: 8)
                        .disabled(session.authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(10)
            } else if !session.downloadStatus.isEmpty {
                Text(session.downloadStatus).font(.system(size: 11)).foregroundStyle(.white.opacity(0.58))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 13).padding(.vertical, 7)
            }
            if close != nil {
                HStack(spacing: 18) {
                    Text("D-pad  Move focus / scroll")
                    Text("A  Select")
                    Text("B  Back")
                    Text("LB / RB  Page history")
                    Spacer()
                    if session.isLoading { ProgressView().controlSize(.mini) }
                }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.48)).padding(.horizontal, 14).padding(.vertical, 9)
                    .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
            }
        }
        .onAppear { addressDraft = session.address }
        .onChange(of: session.address) { _, value in addressDraft = value }
        .onChange(of: session.authorizationCode) { _, code in if !code.isEmpty { authorizationCompletion?(code) } }
        .consoleInput(onCommand: navigate)
        .consoleSheet(isPresented: $keyboardOpen) {
            SearchKeyboardView(query: $keyboardText, title: keyboardTargetIsAddress ? "Enter address" : keyboardTargetIsAuthCode ? "Authorization code" : "Enter text",
                               subtitle: keyboardTargetIsAddress ? "Search the web or enter a website address." : keyboardTargetIsAuthCode ? "Enter the code returned by the store." : "Type into the selected web form field.",
                               doneTitle: keyboardTargetIsAddress ? "Go" : keyboardTargetIsAuthCode ? "Save code" : "Enter", secure: keyboardIsSecure,
                               onCancel: { keyboardOpen = false }) {
                if keyboardTargetIsAddress {
                    addressDraft = keyboardText
                    session.loadAddress(keyboardText)
                    toolbarFocus = goIndex
                } else if keyboardTargetIsAuthCode { session.authorizationCode = keyboardText }
                else { session.submitText(keyboardText) }
                keyboardOpen = false
            }
        }
    }

    private func navigate(_ command: String) {
        if toolbarFocus == pageIndex {
            switch command {
            case "up": toolbarFocus = addressIndex
            case "down" where authorizationCompletion != nil: toolbarFocus = authCodeIndex
            case "down": session.movePageFocus(command)
            case "left", "right": session.movePageFocus(command)
            case "confirm": session.activatePageFocus { needsText in
                if needsText { keyboardTargetIsAddress = false; keyboardTargetIsAuthCode = false; keyboardText = session.pageInputText; keyboardIsSecure = session.pageInputIsSecure; keyboardOpen = true }
            }
            case "back": if session.canGoBack { session.goBack() } else { close?() }
            case "previous": session.movePageFocus("left")
            case "next": session.movePageFocus("right")
            default: break
            }
            return
        }
        let first = close == nil ? backIndex : 0
        let last = authorizationCompletion == nil ? pageIndex : connectIndex
        switch command {
        case "left": toolbarFocus = max(first, toolbarFocus - 1)
        case "right": toolbarFocus = min(last, toolbarFocus + 1)
        case "up": toolbarFocus = pageIndex
        case "down": toolbarFocus = addressIndex
        case "confirm":
            if toolbarFocus == 0, close != nil { close?() }
            else if toolbarFocus == backIndex { session.goBack() }
            else if toolbarFocus == forwardIndex { session.goForward() }
            else if toolbarFocus == reloadIndex { session.reload() }
            else if toolbarFocus == addressIndex { keyboardTargetIsAddress = true; keyboardTargetIsAuthCode = false; keyboardText = addressDraft; keyboardIsSecure = false; keyboardOpen = true }
            else if toolbarFocus == goIndex { session.loadAddress(addressDraft); toolbarFocus = pageIndex }
            else if toolbarFocus == authCodeIndex { keyboardTargetIsAddress = false; keyboardTargetIsAuthCode = true; keyboardText = session.authorizationCode; keyboardIsSecure = false; keyboardOpen = true }
            else if toolbarFocus == connectIndex { authorizationCompletion?(session.authorizationCode) }
        case "back":
            if session.canGoBack { session.goBack() } else { close?() }
        case "previous": session.goBack()
        case "next": session.goForward()
        default: break
        }
    }
}

private struct BrowserWebView: NSViewRepresentable {
    @ObservedObject var session: InAppBrowserSession
    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
