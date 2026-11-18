import AppKit
import SwiftUI
import WebKit

@MainActor
final class InAppBrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: WKWebView
    @Published var address = "https://www.google.com"
    @Published var pageTitle = "New Tab"
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var authorizationCode = ""
    @Published var downloadStatus = ""
    @Published var pageInputText = ""
    @Published var pageInputIsSecure = false
    @Published var externalAuthenticationMessage = ""
    var onAuthorizationCodeDetected: ((String) -> Void)?
    private var lastReportedAuthorizationCode: String?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
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
    func movePagePointer(to point: CGPoint) {
        let x = Int(point.x.rounded()), y = Int(point.y.rounded())
        webView.evaluateJavaScript("""
        (() => {
          const x=\(x), y=\(y), target=document.elementFromPoint(x,y);
          window.dispatchEvent(new MouseEvent('mousemove',{bubbles:true,clientX:x,clientY:y,view:window}));
          if (target) target.dispatchEvent(new MouseEvent('mousemove',{bubbles:true,clientX:x,clientY:y,view:window}));
        })()
        """)
    }
    func activatePagePointer(at point: CGPoint, completion: @escaping (Bool) -> Void) {
        let x = Int(point.x.rounded()), y = Int(point.y.rounded())
        webView.evaluateJavaScript("""
        (() => {
          const hit=document.elementFromPoint(\(x),\(y));
          if (!hit) return {text:false};
          const e=hit.closest('a[href],button,input,textarea,select,[role="button"],[contenteditable="true"]')||hit;
          e.focus?.({preventScroll:true});
          const tag=e.tagName?.toLowerCase(), type=e.type?.toLowerCase();
          const text=['input','textarea'].includes(tag)||e.isContentEditable;
          if (!text) e.click?.();
          return {text,type:type||'',value:e.isContentEditable?(e.innerText||''):(e.value||'')};
        })()
        """) { [weak self] result, _ in
            let detail = result as? [String: Any] ?? [:]
            let needsText = detail["text"] as? Bool == true
            if needsText {
                self?.pageInputText = detail["value"] as? String ?? ""
                self?.pageInputIsSecure = (detail["type"] as? String) == "password"
            }
            completion(needsText)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { sync(webView); isLoading = true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        sync(webView); isLoading = false
        webView.evaluateJavaScript("""
        (() => { const t=document.body?.innerText||''; const m=t.match(/(?:authorizationCode|\"code\")\\s*:\\s*\"([^\"]+)\"/); return m?.[1]||''; })()
        """) { [weak self] value, _ in
            if let code = value as? String, !code.isEmpty { self?.reportAuthorizationCode(code) }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { sync(webView); isLoading = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { sync(webView); isLoading = false }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, Self.isThirdPartyAuthenticationURL(url),
              navigationAction.targetFrame?.isMainFrame == true else {
            decisionHandler(.allow)
            return
        }
        openExternalAuthentication(url)
        decisionHandler(.cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            if Self.isThirdPartyAuthenticationURL(url) { openExternalAuthentication(url) }
            else { webView.load(URLRequest(url: url)) }
        }
        return nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let url = navigationResponse.response.url,
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let code = components.queryItems?.first(where: { $0.name == "code" || $0.name == "authorizationCode" })?.value,
           !code.isEmpty { reportAuthorizationCode(code) }
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
    func openExternalAuthentication(_ url: URL) {
        let host = url.host ?? "the sign-in provider"
        if NSWorkspace.shared.open(url) {
            externalAuthenticationMessage = "\(host) sign-in opened in your default browser. Finish the sign-in there."
        } else {
            externalAuthenticationMessage = "Could not open \(host) in your default browser."
        }
    }
    private func reportAuthorizationCode(_ code: String) {
        authorizationCode = code
        guard !code.isEmpty, lastReportedAuthorizationCode != code else { return }
        lastReportedAuthorizationCode = code
        onAuthorizationCodeDetected?(code)
    }
    private static func isThirdPartyAuthenticationURL(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()
        if host == "accounts.google.com" || host == "oauth2.googleapis.com" { return true }
        if host == "google.com" || host.hasSuffix(".google.com") {
            return path.contains("/o/oauth") || path.contains("/signin") || path.contains("/servicelogin")
        }
        if host == "steamcommunity.com" || host.hasSuffix(".steamcommunity.com") {
            return path.contains("openid") || path.contains("login") || path.contains("signin")
        }
        if host == "store.steampowered.com" || host == "help.steampowered.com" {
            return path.contains("login") || path.contains("signin")
        }
        return false
    }
}

struct InAppBrowserView: View {
    @ObservedObject var session: InAppBrowserSession
    @ObservedObject private var controller = ControllerManager.shared
    var authorizationCompletion: ((String) -> Void)? = nil
    var close: (() -> Void)? = nil
    var closeTitle = "Games"
    var storeBrand: String? = nil
    var storeAccountActionTitle: String? = nil
    var storeAccountAction: (() -> Void)? = nil
    var showAddressBar = true
    @State private var addressDraft = ""
    @State private var toolbarFocus = 0
    @State private var keyboardOpen = false
    @State private var keyboardText = ""
    @State private var keyboardIsSecure = false
    @State private var keyboardTargetIsAddress = false
    @State private var keyboardTargetIsAuthCode = false
    @State private var virtualMouseEnabled = false
    @State private var virtualMousePosition = CGPoint.zero
    @State private var webContentSize = CGSize.zero
    @State private var lastPointerUpdate = Date()
    private var closeOffset: Int { (close == nil ? 0 : 1) + (storeAccountAction == nil ? 0 : 1) }
    private var backIndex: Int { closeOffset }
    private var forwardIndex: Int { closeOffset + 1 }
    private var reloadIndex: Int { closeOffset + 2 }
    private var addressIndex: Int { closeOffset + 3 }
    private var goIndex: Int { closeOffset + 4 }
    private var pageIndex: Int { closeOffset + (showAddressBar ? 5 : 3) }
    private var authCodeIndex: Int { closeOffset + 6 }
    private var pasteCodeIndex: Int { closeOffset + 7 }
    private var connectIndex: Int { closeOffset + 8 }

    var body: some View {
        VStack(spacing: 0) {
            if let close {
                HStack(spacing: 12) {
                    Button { close() } label: { Label(closeTitle, systemImage: closeTitle == "Games" ? "gamecontroller.fill" : "xmark") }
                        .buttonStyle(ConsoleButtonStyle()).consoleFocus(toolbarFocus == 0, cornerRadius: 8)
                    if let storeAccountActionTitle, let storeAccountAction {
                        Button(storeAccountActionTitle, action: storeAccountAction).buttonStyle(ConsoleButtonStyle())
                            .consoleFocus(toolbarFocus == 1, cornerRadius: 8)
                    }
                    Text(storeBrand ?? "INTERNET BROWSER").font(.system(size: 10, weight: .bold)).tracking(1.7).foregroundStyle(.white.opacity(0.58))
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
                if showAddressBar {
                    TextField("Search or enter address", text: $addressDraft)
                        .textFieldStyle(.roundedBorder).onSubmit { session.loadAddress(addressDraft) }
                        .onTapGesture { toolbarFocus = addressIndex }
                        .consoleFocus(toolbarFocus == addressIndex, cornerRadius: 7)
                    Button("Go") { toolbarFocus = goIndex; session.loadAddress(addressDraft) }
                        .consoleFocus(toolbarFocus == goIndex, cornerRadius: 8)
                }
            }.buttonStyle(ConsoleButtonStyle()).padding(11)
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    BrowserWebView(session: session)
                        .overlay(alignment: .topLeading) {
                            Text(session.pageTitle).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                .foregroundStyle(.white.opacity(0.01)).padding(2)
                        }
                    if virtualMouseEnabled {
                        ZStack {
                            Circle().fill(studioAccent).frame(width: 14, height: 14)
                            Circle().strokeBorder(.white, lineWidth: 2).frame(width: 24, height: 24)
                        }
                        .shadow(color: .black.opacity(0.65), radius: 3, y: 1)
                        .position(virtualMousePosition)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .onAppear {
                    webContentSize = geometry.size
                    if virtualMousePosition == .zero { virtualMousePosition = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2) }
                }
                .onChange(of: geometry.size) { _, size in
                    webContentSize = size
                    virtualMousePosition = clampedPointer(virtualMousePosition, size: size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !session.externalAuthenticationMessage.isEmpty {
                Text(authorizationCompletion == nil
                     ? session.externalAuthenticationMessage
                     : session.externalAuthenticationMessage + " Copy the final code or redirect URL, return here, paste it below, then choose Connect.")
                    .font(.system(size: 10)).foregroundStyle(.orange.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 13).padding(.vertical, 6)
            }
            if let authorizationCompletion {
                HStack(spacing: 8) {
                    TextField("Authorization code", text: $session.authorizationCode).textFieldStyle(.roundedBorder)
                        .onTapGesture { toolbarFocus = authCodeIndex }
                        .consoleFocus(toolbarFocus == authCodeIndex, cornerRadius: 7)
                    Button("Paste") { pasteAuthorizationCode() }
                        .buttonStyle(ConsoleButtonStyle()).consoleFocus(toolbarFocus == pasteCodeIndex, cornerRadius: 8)
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
                    Text(virtualMouseEnabled ? "Left stick  Move pointer" : "D-pad  Move focus / scroll")
                    Text(virtualMouseEnabled ? "A  Click" : "A  Select")
                    if controller.name != nil { Text("X  \(virtualMouseEnabled ? "Hide" : "Virtual mouse")") }
                    Text("B  Back")
                    Text("LB / RB  Page history")
                    Spacer()
                    if session.isLoading { ProgressView().controlSize(.mini) }
                }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.48)).padding(.horizontal, 14).padding(.vertical, 9)
                    .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
            }
        }
        .onAppear {
            addressDraft = session.address
            let enabled = $virtualMouseEnabled
            let keyboard = $keyboardOpen
            let pointer = $virtualMousePosition
            let size = $webContentSize
            let lastUpdate = $lastPointerUpdate
            controller.leftStickPointerAction = { x, y in
                guard controller.name != nil, enabled.wrappedValue, !keyboard.wrappedValue,
                      size.wrappedValue.width > 0, size.wrappedValue.height > 0 else { return false }
                let now = Date()
                let elapsed = min(max(now.timeIntervalSince(lastUpdate.wrappedValue), 0.008), 0.05)
                lastUpdate.wrappedValue = now
                func scaled(_ value: Float) -> Double {
                    let magnitude = Double(abs(value))
                    let deadZone = 0.14
                    return magnitude <= deadZone ? 0 : (magnitude - deadZone) / (1 - deadZone) * (value < 0 ? -1 : 1)
                }
                let speed = 680.0 * elapsed
                let next = CGPoint(x: pointer.wrappedValue.x + CGFloat(scaled(x) * speed),
                                   y: pointer.wrappedValue.y - CGFloat(scaled(y) * speed))
                pointer.wrappedValue = clampedPointer(next, size: size.wrappedValue)
                return true
            }
        }
        .onChange(of: session.address) { _, value in addressDraft = value }
        .onChange(of: controller.name) { _, name in if name == nil { virtualMouseEnabled = false } }
        .onChange(of: virtualMousePosition) { _, point in
            if virtualMouseEnabled { session.movePagePointer(to: point) }
        }
        .consoleInput(onCommand: navigate)
        .onDisappear { controller.leftStickPointerAction = nil }
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

    private func clampedPointer(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x, 12), max(size.width - 12, 12)),
                y: min(max(point.y, 12), max(size.height - 12, 12)))
    }

    private func toggleVirtualMouse() {
        virtualMouseEnabled.toggle()
        controller.cancelDirectionalRepeat()
        if virtualMouseEnabled {
            toolbarFocus = pageIndex
            virtualMousePosition = CGPoint(x: webContentSize.width / 2, y: webContentSize.height / 2)
            session.movePagePointer(to: virtualMousePosition)
        }
    }

    private func activateVirtualMouse() {
        session.activatePagePointer(at: virtualMousePosition) { needsText in
            if needsText {
                keyboardTargetIsAddress = false
                keyboardTargetIsAuthCode = false
                keyboardText = session.pageInputText
                keyboardIsSecure = session.pageInputIsSecure
                keyboardOpen = true
            }
        }
    }

    private func pasteAuthorizationCode() {
        guard let value = NSPasteboard.general.string(forType: .string), !value.isEmpty else {
            session.externalAuthenticationMessage = "The clipboard is empty. Copy the authorization code or redirect URL in your browser first."
            return
        }
        session.authorizationCode = value
        toolbarFocus = connectIndex
    }

    private func navigate(_ command: String) {
        if command == "details" {
            guard controller.name != nil else { return }
            toggleVirtualMouse()
            return
        }
        if toolbarFocus == pageIndex {
            switch command {
            case "up": toolbarFocus = addressIndex
            case "down" where authorizationCompletion != nil: toolbarFocus = authCodeIndex
            case "down": session.movePageFocus(command)
            case "left", "right": session.movePageFocus(command)
            case "confirm":
                if virtualMouseEnabled { activateVirtualMouse() }
                else {
                    session.activatePageFocus { needsText in
                        if needsText { keyboardTargetIsAddress = false; keyboardTargetIsAuthCode = false; keyboardText = session.pageInputText; keyboardIsSecure = session.pageInputIsSecure; keyboardOpen = true }
                    }
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
        case "down": toolbarFocus = showAddressBar ? addressIndex : pageIndex
        case "confirm":
            if toolbarFocus == 0, close != nil { close?() }
            else if toolbarFocus == 1, let storeAccountAction { storeAccountAction() }
            else if toolbarFocus == backIndex { session.goBack() }
            else if toolbarFocus == forwardIndex { session.goForward() }
            else if toolbarFocus == reloadIndex { session.reload() }
            else if toolbarFocus == addressIndex { keyboardTargetIsAddress = true; keyboardTargetIsAuthCode = false; keyboardText = addressDraft; keyboardIsSecure = false; keyboardOpen = true }
            else if toolbarFocus == goIndex { session.loadAddress(addressDraft); toolbarFocus = pageIndex }
            else if toolbarFocus == authCodeIndex { keyboardTargetIsAddress = false; keyboardTargetIsAuthCode = true; keyboardText = session.authorizationCode; keyboardIsSecure = false; keyboardOpen = true }
            else if toolbarFocus == pasteCodeIndex { pasteAuthorizationCode() }
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
