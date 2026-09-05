import SwiftUI
import WebKit

// MARK: - 南昌大学统一身份认证 (CAS) 纯净嵌入式 WebView
struct NCUCASWebView: UIViewRepresentable {
    let url: URL
    let onTokenCaptured: (String) -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onTokenCaptured: onTokenCaptured)
    }
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        
        let webView = WKWebView(frame: UIScreen.main.bounds, configuration: config)
        // 关键：模拟标准 Safari 浏览器 User-Agent，确保 CAS 平台的 Vue/Element UI 脚本正常挂载
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        webView.navigationDelegate = context.coordinator
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.allowsBackForwardNavigationGestures = true
        
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(request)
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WKWebView, context: Context) -> CGSize? {
        return CGSize(
            width: proposal.width ?? UIScreen.main.bounds.width,
            height: proposal.height ?? UIScreen.main.bounds.height
        )
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        let onTokenCaptured: (String) -> Void
        private var hasCaptured = false
        
        init(onTokenCaptured: @escaping (String) -> Void) {
            self.onTokenCaptured = onTokenCaptured
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let targetURL = navigationAction.request.url {
                if checkURLForToken(targetURL) {
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let targetURL = navigationResponse.response.url {
                if checkURLForToken(targetURL) {
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url, checkURLForToken(url) {
                return
            }
            // 兜底提取 localStorage
            let js = "(function(){ try { return localStorage.getItem('sc_token') || localStorage.getItem('token') || ''; } catch(e) { return ''; } })();"
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                if let t = result as? String, t.count > 20 {
                    self?.captureToken(t)
                }
            }
        }
        
        // 信任校园网自建证书与 8443 端口
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let serverTrust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
        
        @discardableResult
        private func checkURLForToken(_ url: URL) -> Bool {
            let str = url.absoluteString
            if let match = str.range(of: "token=") {
                let after = str[match.upperBound...]
                let tokenPart = after.components(separatedBy: "&").first ?? ""
                let decoded = tokenPart.removingPercentEncoding ?? tokenPart
                if decoded.count > 20 {
                    captureToken(decoded)
                    return true
                }
            }
            return false
        }
        
        private func captureToken(_ token: String) {
            guard !hasCaptured else { return }
            hasCaptured = true
            DispatchQueue.main.async {
                self.onTokenCaptured(token)
            }
        }
    }
}

/// 智慧课堂智能眼镜授课总控台 (Smart Class Control View)
struct SmartClassControlView: View {
    @ObservedObject var authService = AuthService.shared
    @ObservedObject var lectureManager = LectureSessionManager.shared
    @EnvironmentObject var webSocketClient: WebSocketClient
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject var watchManager = WatchSessionManager.shared
    @StateObject private var motionRemote = PhoneMotionRemoteService.shared
    
    // 手机体感手势 HUD 动效浮层
    @State private var showGestureToast: Bool = false
    @State private var motionToastText: String? = nil
    @State private var toastDismissWorkItem: DispatchWorkItem?
    
    private func triggerGestureToast(_ text: String) {
        toastDismissWorkItem?.cancel()
        motionToastText = text
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            showGestureToast = true
        }
        let item = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.3)) {
                self.showGestureToast = false
            }
        }
        toastDismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: item)
    }
    
    @State private var serverUrlInput: String = "https://syb.ncu.edu.cn"
    @State private var sessionIdInput: String = "c81431e6"
    
    // 登录模式：默认优先 0: 粘贴/剪贴板 Token 导入（最稳定），1: 统一身份认证 WebView 弹窗
    @State private var showCASSheet: Bool = false
    @State private var manualTokenInput: String = ""
    @State private var bleStatusToast: String? = nil
    
    // 页内微步滚动与手势同步状态
    @State private var activeLineIndex: Int = 0
    @State private var isProgrammaticScrolling: Bool = false
    @State private var dragSettleWorkItem: DispatchWorkItem?
    @State private var scrollLineIndex: Double = 0
    @State private var showConnectionSettings: Bool = false
    @State private var showFullScreenTeleprompter: Bool = false
    
    /// Even G2 智能眼镜物理视口固定显示 9 行文本 (与独立提词器 TeleprompterPreviewView 保持 100% 一致)
    static let physicalViewportLines: Int = 9
    
    // 提词折行分行计算（与 Even G2 眼镜 28 字符/14汉字排版 100% 对齐）
    private var wrappedScriptLines: [String] {
        let text = lectureManager.currentScriptText
        let maxLineWidth = 28 * 2
        let (pages, _) = G2ProtocolEncoder.formatTextToPagesOnDemand(text, maxLineWidth: maxLineWidth, linesPerPage: 10)
        let lines = pages.flatMap { $0.components(separatedBy: "\n") }
        return lines.isEmpty ? ["暂无口述提词"] : lines
    }
    
    // 当前眼镜物理视口与外部区域边界模型 (vStart~vEnd: 眼镜显示区, 其它: 外部区域)
    private var viewportBounds: ViewportBounds {
        let total = wrappedScriptLines.count
        let vp = SmartClassControlView.physicalViewportLines
        let maxTop = max(total - vp, 0)
        let vStart = max(0, min(activeLineIndex, maxTop))
        let vEnd = min(vStart + vp - 1, max(total - 1, 0))
        let wStart = max(0, vStart - 4)
        let wEnd = min(vEnd + 4, max(total - 1, 0))
        return ViewportBounds(vStart: vStart, vEnd: vEnd, wStart: wStart, wEnd: wEnd)
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 16) {
                    // MARK: - 1. 教师身份鉴权卡片
                    authCard
                    
                    // MARK: - 2. 课时连接与状态面板
                    connectionCard
                    
                    // MARK: - 3. 讲台实时 HUD 提词监看大屏
                    lectureHUDCard
                    
                    // MARK: - 4. 激光笔平级双向控屏手柄
                    controlActionsCard
                }
                .padding()
            }
            
            // 🪄 手机体感手势触发 HUD 动效浮层
            if showGestureToast, let toast = motionToastText {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.purple)
                    Text(toast)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .shadow(color: Color.purple.opacity(0.25), radius: 8, x: 0, y: 3)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: showGestureToast)
            }
        }
        .navigationTitle("智慧课堂 HUD 辅驾")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            serverUrlInput = lectureManager.baseURL
            sessionIdInput = lectureManager.sessionId
            // 同步当前眼镜实际行号位置
            self.activeLineIndex = bleManager.currentFocusPageLine
            // 自动检测一次剪贴板是否有 Token
            autoCheckClipboardToken()
            
            // 🌟 若已鉴权，进入页面立即自动加载课时与大屏联动，无需手动点击同步！
            if authService.isAuthenticated {
                lectureManager.loadLectureSession(baseURL: serverUrlInput, sessionId: sessionIdInput)
            }
            // 🌟 若蓝牙未连接且未在扫描，自动开启扫描以快速寻机连接 Even G2
            if !bleManager.isConnected && !bleManager.isScanning {
                bleManager.startScanning()
            }
            
            // 🌟 绑定手机陀螺仪体感遥控手势回调
            motionRemote.onPageNavTriggered = { isNext in
                if isNext {
                    lectureManager.gotoNextSlide()
                    triggerGestureToast("向左挥动 ➡️ 下一页 (P\(lectureManager.currentSlideIndex + 1))")
                } else {
                    lectureManager.gotoPrevSlide()
                    triggerGestureToast("向右挥动 ⬅️ 上一页 (P\(lectureManager.currentSlideIndex + 1))")
                }
            }
            motionRemote.onScrollDeltaTriggered = { delta in
                lectureManager.scrollByLineDelta(delta)
                let label = delta > 0 ? "向前甩动 ⬇️ 视口下滚 \(delta) 行" : "向上挑动 ⬆️ 视口上滚 \(-delta) 行"
                triggerGestureToast(label)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            autoCheckClipboardToken()
            if authService.isAuthenticated && lectureManager.sessionInfo == nil {
                lectureManager.loadLectureSession(baseURL: serverUrlInput, sessionId: sessionIdInput)
            }
        }
        .onReceive(lectureManager.$sessionId) { newSid in
            if !newSid.isEmpty && sessionIdInput != newSid {
                sessionIdInput = newSid
            }
        }
        .sheet(isPresented: $showCASSheet) {
            NavigationView {
                NCUCASWebView(url: getDirectCASURL()) { token in
                    DispatchQueue.main.async {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        self.showCASSheet = false // 立即关闭登录窗！
                        self.authService.importToken(token, baseURL: self.serverUrlInput)
                        // 登录成功瞬间立即自动拉取课时
                        self.lectureManager.loadLectureSession(baseURL: self.serverUrlInput, sessionId: self.sessionIdInput)
                    }
                }
                .navigationTitle("南昌大学统一身份认证")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") {
                            showCASSheet = false
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showFullScreenTeleprompter) {
            NavigationView {
                TeleprompterPreviewView(script: ScriptItem(
                    title: "第 \(lectureManager.currentSlideIndex + 1) 页: \(lectureManager.currentSlideTitle)",
                    content: lectureManager.currentScriptText,
                    scrollMode: .manual,
                    targetWidthChars: 28
                ))
            }
        }
    }
    
    // MARK: - 卡片 1: 身份鉴权
    private var authCard: some View {
        Group {
            if authService.isAuthenticated {
                HStack(spacing: 8) {
                    Image(systemName: "person.badge.shield.checkmark.fill")
                        .foregroundColor(.purple)
                        .font(.subheadline)
                    Text(authService.currentUser?.fullName ?? (authService.currentUser?.username ?? "004475 讲师"))
                        .font(.subheadline)
                        .fontWeight(.bold)
                    Text("• 已就绪")
                        .font(.caption2)
                        .foregroundColor(.green)
                    Spacer()
                    Button("注销") {
                        authService.logout()
                        manualTokenInput = ""
                    }
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.1))
                    .foregroundColor(.red)
                    .cornerRadius(6)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(12)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("讲师身份鉴权", systemImage: "person.badge.shield.checkmark.fill")
                            .font(.headline)
                            .foregroundColor(.purple)
                        Spacer()
                        Text("未鉴权")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red.opacity(0.15))
                            .foregroundColor(.red)
                            .cornerRadius(8)
                    }
                VStack(alignment: .leading, spacing: 12) {
                    Text("讲师授信认证")
                        .font(.subheadline)
                        .fontWeight(.bold)
                    
                    // 🌟 选项 A: 讲师一键授权登录 (004475 专属通道，秒级直达，绕过 CAS 网络卡顿)
                    Button(action: {
                        authService.quickTeacherLogin(baseURL: serverUrlInput) { result in
                            DispatchQueue.main.async {
                                switch result {
                                case .success:
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                    lectureManager.loadLectureSession(baseURL: serverUrlInput, sessionId: sessionIdInput)
                                case .failure(let error):
                                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                                    NSLog("快捷登录失败: %@", error.localizedDescription)
                                }
                            }
                        }
                    }) {
                        HStack {
                            Image(systemName: "bolt.shield.fill")
                            Text("讲师一键授权登录 (004475)")
                        }
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(LinearGradient(gradient: Gradient(colors: [Color.purple, Color.indigo]), startPoint: .leading, endPoint: .trailing))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .shadow(color: Color.purple.opacity(0.3), radius: 4, y: 2)
                    }
                    
                    // 🌟 选项 B: 统一身份认证登录 (CAS 网页)
                    Button(action: {
                        self.showCASSheet = true
                    }) {
                        HStack {
                            Image(systemName: "building.columns.fill")
                            Text("统一身份认证登录 (CAS 网页)")
                        }
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.blue.opacity(0.12))
                        .foregroundColor(.blue)
                        .cornerRadius(10)
                    }
                    
                    Text("提示: 建议点击「讲师一键授权」，免密秒达；亦可通过 CAS 网页输入工号密码完成校园网验证。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineSpacing(2)
                }
                .padding(.top, 2)
            }
            .padding()
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(16)
        }
    }
}
    
    // MARK: - 卡片 2: 课时连接配置
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("课时连接配置", systemImage: "network")
                    .font(.subheadline)
                    .fontWeight(.bold)
                Spacer()
                
                // 状态指示灯 (大屏 + G2眼镜 + Apple Watch，尺寸固定，绝无缩放抖动)
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(webSocketClient.isConnected ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                        Text(webSocketClient.isConnected ? "大屏在线" : "大屏未连")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 4) {
                        Circle()
                            .fill(bleManager.isReadyForTeleprompter ? Color.green : (bleManager.isConnected ? Color.yellow : Color.orange))
                            .frame(width: 6, height: 6)
                        Text(bleManager.isReadyForTeleprompter ? "G2就绪" : (bleManager.isConnected ? "G2配置" : "G2未连"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 4) {
                        Circle()
                            .fill(watchManager.isWatchReachable ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(watchManager.isWatchReachable ? "手表在线" : "手表待命")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .fixedSize(horizontal: true, vertical: true)
                
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showConnectionSettings.toggle()
                    }
                }) {
                    Image(systemName: showConnectionSettings ? "chevron.up" : "gearshape")
                        .font(.caption)
                        .foregroundColor(.purple)
                        .padding(4)
                }
            }
            
            // 🌟 同课程可用课时快速选择器 (点击一键切课)
            if !lectureManager.availableSessions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(lectureManager.availableSessions) { sess in
                            let isCurrent = (sess.runtimeSessionId == lectureManager.sessionId)
                            let isActive = (sess.runtimeSessionId == lectureManager.activeSessionId)
                            Button(action: {
                                if let rid = sess.runtimeSessionId, !rid.isEmpty {
                                    sessionIdInput = rid
                                    // 🌟 点击课时即向后端大屏下发激活信令，眼镜与大屏同步协同切课！
                                    lectureManager.activateSession(rid)
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(isActive ? Color.green : (isCurrent ? Color.purple : Color.gray.opacity(0.3)))
                                        .frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 4) {
                                            Text(sess.name)
                                                .font(.caption)
                                                .fontWeight(.bold)
                                            if isActive {
                                                Text("主屏活跃")
                                                    .font(.system(size: 8, weight: .bold))
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 1)
                                                    .background(Color.green.opacity(0.2))
                                                    .foregroundColor(.green)
                                                    .cornerRadius(4)
                                            }
                                        }
                                        if let rid = sess.runtimeSessionId {
                                            Text("ID: \(rid)")
                                                .font(.system(size: 9, design: .monospaced))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(isCurrent ? Color.purple.opacity(0.12) : Color(UIColor.tertiarySystemBackground))
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(isCurrent ? Color.purple : (isActive ? Color.green.opacity(0.5) : Color.clear), lineWidth: 1.5)
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            
            // 展开折叠的连接配置卡片
            if showConnectionSettings {
                VStack(spacing: 12) {
                    HStack {
                        Text("服务地址")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .leading)
                        TextField("http://192.168.x.x:8000", text: $serverUrlInput)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .font(.system(.caption, design: .monospaced))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    
                    HStack {
                        Text("课时 ID")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .leading)
                        TextField("session_id", text: $sessionIdInput)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .font(.system(.caption, design: .monospaced))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    
                    Button(action: {
                        lectureManager.loadLectureSession(baseURL: serverUrlInput, sessionId: sessionIdInput)
                        withAnimation { showConnectionSettings = false }
                    }) {
                        HStack {
                            if lectureManager.isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text("同步课时与大屏联动")
                                .fontWeight(.semibold)
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.purple)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                }
                .padding(.top, 2)
            }
            
            if let err = lectureManager.lastSyncError {
                Text("同步失败: \(err)")
                    .font(.caption2)
                    .foregroundColor(.red)
            }
        }
        .padding(12)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(14)
    }
    
    // MARK: - 卡片 3: 讲台实时 HUD 提词监看大屏
    private var lectureHUDCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // MARK: - 顶行 1: 卡片标题 + 镜显推屏状态 + 全屏按钮 + 醒目单行页码
            HStack(alignment: .center, spacing: 8) {
                // 主标题
                HStack(spacing: 5) {
                    Image(systemName: "eyeglasses")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.purple)
                    Text("提词监看 HUD")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.purple)
                }
                .fixedSize(horizontal: true, vertical: false)
                
                Spacer(minLength: 4)
                
                // 物理硬件推屏确认状态 (去除重复双绿点，单行防挤压，点击可一键重推)
                Button(action: {
                    if !bleManager.isConnected {
                        bleStatusToast = "⚠️ Even G2 未连接"
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    } else {
                        bleManager.retryCurrentSlidePush()
                        bleStatusToast = "🔄 正在重置屏显并重新灌入讲稿..."
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        bleStatusToast = nil
                    }
                }) {
                    let cleanStatus = bleManager.teleprompterPushStatusMessage
                        .replacingOccurrences(of: "🟢 ", with: "")
                        .replacingOccurrences(of: "🟡 ", with: "")
                        .replacingOccurrences(of: "🔴 ", with: "")
                    
                    HStack(spacing: 4) {
                        Circle()
                            .fill(bleManager.isHardwareRenderConfirmed ? Color.green : (bleManager.isPushingText ? Color.orange : Color.red))
                            .frame(width: 6, height: 6)
                        Text(cleanStatus)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(bleManager.isHardwareRenderConfirmed ? .green : (bleManager.isPushingText ? .orange : .red))
                            .lineLimit(1)
                        if !bleManager.isHardwareRenderConfirmed && !bleManager.isPushingText {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.red)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(bleManager.isHardwareRenderConfirmed ? Color.green.opacity(0.1) : (bleManager.isPushingText ? Color.orange.opacity(0.1) : Color.red.opacity(0.1)))
                    .cornerRadius(6)
                }
                .buttonStyle(PlainButtonStyle())
                .fixedSize(horizontal: true, vertical: false)
                
                // 全屏大界面切换
                Button(action: {
                    self.showFullScreenTeleprompter = true
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                        Text("全屏")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.purple.opacity(0.12))
                    .foregroundColor(.purple)
                    .cornerRadius(6)
                }
                .buttonStyle(PlainButtonStyle())
                .fixedSize(horizontal: true, vertical: false)
                
                // 大字号页码胶囊 (单行紧凑布局，彻底杜绝“P 03 /”与“15”断行)
                HStack(spacing: 2) {
                    Text("P")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .foregroundColor(.purple.opacity(0.75))
                    Text(String(format: "%02d", lectureManager.currentSlideIndex + 1))
                        .font(.system(size: 15, weight: .black, design: .monospaced))
                        .foregroundColor(.purple)
                    Text("/")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.purple.opacity(0.45))
                    Text(String(format: "%02d", lectureManager.totalSlides))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.purple.opacity(0.85))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.purple.opacity(0.12))
                .cornerRadius(6)
                .fixedSize(horizontal: true, vertical: false)
            }
            
            // MARK: - 顶行 2: 课件标题 + 提词视口区间指示胶囊
            HStack(alignment: .center, spacing: 6) {
                Text(lectureManager.currentSlideTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                Spacer(minLength: 4)
                
                let bounds = viewportBounds
                // 优雅紧凑单行胶囊：彻底杜绝“视口正显:”和“1~9行”拆行
                HStack(spacing: 4) {
                    Circle().fill(Color.purple).frame(width: 5, height: 5)
                    Text("视口: \(bounds.vStart + 1)~\(bounds.vEnd + 1)行")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.purple)
                    
                    Text("•")
                        .font(.system(size: 9))
                        .foregroundColor(.purple.opacity(0.4))
                    
                    Text("共\(wrappedScriptLines.count)行")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.purple.opacity(0.08))
                .cornerRadius(6)
                .fixedSize(horizontal: true, vertical: false)
            }
            
            // 🌟 独立提词器完整复用：两区域视觉区分 + 拖拽滑动毫秒级同步移动眼镜提词位置
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 4) {
                        Spacer(minLength: 8)
                        
                        ForEach(Array(wrappedScriptLines.enumerated()), id: \.offset) { index, lineText in
                            let bounds = viewportBounds
                            let isInViewport = (index >= bounds.vStart && index <= bounds.vEnd)
                            let isViewportTop = (index == bounds.vStart)
                            
                            HStack(alignment: .center, spacing: 8) {
                                // 行号：紧凑纯粹的等宽数字，仅占 22pt，不浪费任何横向空间
                                Text(String(format: "%02d", index + 1))
                                    .font(.system(size: 11.5, weight: isViewportTop ? .black : (isInViewport ? .bold : .regular), design: .monospaced))
                                    .foregroundColor(isViewportTop ? Color.purple : (isInViewport ? Color.purple.opacity(0.8) : Color.gray.opacity(0.35)))
                                    .frame(width: 22, alignment: .trailing)
                                
                                // 文本正文：宽度 100% 释放，顶行 14.5pt 饱满清晰，杜绝文字缩水挤压
                                Text(lineText.isEmpty ? " " : lineText)
                                    .font(.system(size: isViewportTop ? 14.5 : 13.5, weight: isViewportTop ? .bold : (isInViewport ? .semibold : .regular)))
                                    .foregroundColor(isViewportTop ? Color.purple : (isInViewport ? Color.primary : Color.secondary.opacity(0.38)))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                    .allowsTightening(true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4) // 恒定上下内边距，单行稳定约 30pt
                            .background(
                                Group {
                                    if isInViewport {
                                        // 👓【眼镜显示区域】：高亮深底色与紫色描边，顶端行加深增强焦点
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(isViewportTop ? Color.purple.opacity(0.18) : Color.purple.opacity(0.06))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(isViewportTop ? Color.purple.opacity(0.5) : Color.purple.opacity(0.15), lineWidth: isViewportTop ? 1.5 : 1)
                                            )
                                    } else {
                                        // ⚪️【外部区域】：清爽无底色，弱灰阶显示供提前预览
                                        Color.clear
                                    }
                                }
                            )
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: TeleprompterLineOffsetKey.self,
                                        value: [index: geo.frame(in: .named("smart_class_hud_scroll")).minY]
                                    )
                                }
                            )
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                updateFocusLine(index: index, scrollProxy: proxy)
                            }
                        }
                        
                        // 底部保留 90pt 充裕停靠行程，确保触底时可精准将视口顶端行吸附对齐于卡片顶端
                        Spacer(minLength: 90)
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 340)
                .background(Color(UIColor.tertiarySystemBackground))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.purple.opacity(0.15), lineWidth: 1)
                )
                .coordinateSpace(name: "smart_class_hud_scroll")
                // 1. 手指触碰/拖拽手势开始：解除眼镜回波屏蔽，准备向眼镜发包
                .simultaneousGesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { _ in
                            self.isProgrammaticScrolling = false
                            self.bleManager.resetGlassesRxShield()
                        }
                )
                // 2. 核心联动：手机拖拽滑动时，实时计算顶部行号并同步移动眼镜提词视口
                .onPreferenceChange(TeleprompterLineOffsetKey.self) { offsets in
                    guard !isProgrammaticScrolling else { return }
                    let maxLine = max(wrappedScriptLines.count - SmartClassControlView.physicalViewportLines, 0)
                    
                    let candidateIndex: Int?
                    if let topCandidate = offsets.filter({ $0.value >= -35 && $0.value <= 100 }).min(by: { abs($0.value) < abs($1.value) }) {
                        candidateIndex = topCandidate.key
                    } else {
                        candidateIndex = nil
                    }
                    
                    if let rawIndex = candidateIndex {
                        let newIndex = max(0, min(rawIndex, maxLine))
                        // A. 手机本地 UI 实时跟随并向手表同步
                        if newIndex != activeLineIndex {
                            DispatchQueue.main.async {
                                self.activeLineIndex = newIndex
                                self.syncLineToGlasses(lineIndex: newIndex)
                                self.lectureManager.syncStateToWatch(lineIndex: newIndex)
                            }
                        }
                        
                        // B. 🎯 滑动停顿/松手终点闭环：200ms 防抖自动平滑磁吸对齐顶端行，并向手表/眼镜强制发送最终行
                        dragSettleWorkItem?.cancel()
                        let item = DispatchWorkItem {
                            self.bleManager.flushFinalScrollSync(lineIndex: newIndex)
                            self.lectureManager.syncStateToWatch(lineIndex: newIndex, forceImmediate: true)
                            // 🌟 智能磁吸对齐：平滑将视口顶端行对齐在卡片顶部，确保整整 9 行端正同屏，杜绝回弹与偏差
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                proxy.scrollTo(newIndex, anchor: .top)
                            }
                        }
                        self.dragSettleWorkItem = item
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: item)
                    }
                }
                // 3. 接收眼镜端/手表端回波：消除乒乓震荡，自动跟焦滚动
                .onReceive(bleManager.$currentFocusPageLine) { newGlassesLine in
                    guard !wrappedScriptLines.isEmpty else { return }
                    let maxLine = max(wrappedScriptLines.count - SmartClassControlView.physicalViewportLines, 0)
                    let clampedLine = max(0, min(maxLine, newGlassesLine))
                    
                    guard clampedLine != activeLineIndex else { return }
                    
                    // 🛡️ 手机主控防拉扯：若手机端刚主动滑动过 (500ms 内)，严禁被外部回波强行触发 proxy.scrollTo 引起回弹
                    guard !self.bleManager.isRecentPhoneScroll else { return }
                    
                    self.isProgrammaticScrolling = true
                    self.dragSettleWorkItem?.cancel()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        self.activeLineIndex = clampedLine
                        proxy.scrollTo(clampedLine, anchor: .top)
                    }
                    self.lectureManager.syncStateToWatch(lineIndex: clampedLine)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
                        self.isProgrammaticScrolling = false
                    }
                }
                // 4. 切页时视口重置回第 0 行
                .onReceive(lectureManager.$currentSlideIndex) { _ in
                    self.activeLineIndex = 0
                    self.lectureManager.syncStateToWatch(lineIndex: 0, forceImmediate: true)
                    self.isProgrammaticScrolling = true
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(0, anchor: .top)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.isProgrammaticScrolling = false
                    }
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }
    
    // MARK: - 辅助滚动同步方法 (复用独立提词器逻辑)
    private func updateFocusLine(index: Int, scrollProxy: ScrollViewProxy?) {
        let maxLine = max(wrappedScriptLines.count - SmartClassControlView.physicalViewportLines, 0)
        let clamped = max(0, min(maxLine, index))
        isProgrammaticScrolling = true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            activeLineIndex = clamped
            scrollProxy?.scrollTo(clamped, anchor: .top)
        }
        bleManager.resetGlassesRxShield()
        bleManager.flushFinalScrollSync(lineIndex: clamped)
        lectureManager.syncStateToWatch(lineIndex: clamped, forceImmediate: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.isProgrammaticScrolling = false
        }
    }
    
    private func syncLineToGlasses(lineIndex: Int) {
        guard bleManager.isConnected else { return }
        if bleManager.isTeleprompterSessionActive && !bleManager.isPushingText {
            let maxLine = max(wrappedScriptLines.count - SmartClassControlView.physicalViewportLines, 0)
            let safeLine = max(0, min(maxLine, lineIndex))
            bleManager.sendScrollSync(lineIndex: safeLine)
        }
    }
    
    // MARK: - 卡片 4: 激光笔平级双向控屏手柄
    private var controlActionsCard: some View {
        VStack(spacing: 10) {
            // 🪄 手机陀螺仪体感遥控器 (Air Remote) 快捷控制条
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Button(action: {
                        motionRemote.toggleEnabled()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: motionRemote.isEnabled ? "wand.and.stars" : "wand.and.rays")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(motionRemote.isEnabled ? .purple : .secondary)
                            Text(motionRemote.isEnabled ? "体感遥控: 运行中" : "体感遥控: 已暂停")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(motionRemote.isEnabled ? .purple : .secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(motionRemote.isEnabled ? Color.purple.opacity(0.12) : Color(UIColor.tertiarySystemBackground))
                        .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    Spacer()
                    
                    Text(motionRemote.lastGestureName)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(motionRemote.isEnabled ? .purple : .secondary)
                        .lineLimit(1)
                }
                
                if motionRemote.isEnabled {
                    HStack(spacing: 4) {
                        Text("💡 体感手势:")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.purple)
                        Text("向左/右挥动 ➡️ 翻页 | 前甩/上挑 ➡️ 滚动3行")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(8)
            .background(Color(UIColor.tertiarySystemBackground))
            .cornerRadius(10)
            
            // 切页
            HStack(spacing: 12) {
                Button(action: {
                    lectureManager.gotoPrevSlide()
                }) {
                    HStack {
                        Image(systemName: "chevron.left.circle.fill")
                        Text("上一页")
                    }
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.purple.opacity(0.15))
                    .foregroundColor(.purple)
                    .cornerRadius(10)
                }
                .disabled(lectureManager.currentSlideIndex <= 0)
                
                Button(action: {
                    lectureManager.gotoNextSlide()
                }) {
                    HStack {
                        Text("下一页")
                        Image(systemName: "chevron.right.circle.fill")
                    }
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.purple)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(lectureManager.currentSlideIndex >= lectureManager.totalSlides - 1)
            }
            
            // 视口逐行滚动与重推控制 (大屏或手机按键触发)
            HStack(spacing: 10) {
                Button(action: {
                    lectureManager.scrollByLineDelta(-1)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up")
                        Text("上滚一行")
                    }
                    .font(.caption)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.purple.opacity(0.12))
                    .foregroundColor(.purple)
                    .cornerRadius(8)
                }
                
                Button(action: {
                    lectureManager.scrollByLineDelta(1)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down")
                        Text("下滚一行")
                    }
                    .font(.caption)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.purple.opacity(0.12))
                    .foregroundColor(.purple)
                    .cornerRadius(8)
                }
                
                Button(action: {
                    if !bleManager.isConnected {
                        bleStatusToast = "⚠️ Even G2 未连接"
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    } else {
                        bleManager.retryCurrentSlidePush()
                        bleStatusToast = "🔄 正在重置并强推至眼镜..."
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        bleStatusToast = nil
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("重推眼镜")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(UIColor.tertiarySystemBackground))
                    .foregroundColor(.primary)
                    .cornerRadius(8)
                }
            }
            
            HStack {
                Text("当前视口: 第 \(lectureManager.currentLineIndex) 行")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                if let toast = bleStatusToast {
                    Text(toast)
                        .font(.caption2)
                        .foregroundColor(toast.starts(with: "⚠️") ? .orange : .green)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }
    
    // MARK: - 辅助计算
    private func getDirectCASURL() -> URL {
        var clean = serverUrlInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                  .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if clean.hasSuffix("/smart-class") {
            clean = String(clean.dropLast("/smart-class".count))
        }
        return URL(string: "\(clean)/smart-class/api/auth/login?next=/smart-class/")!
    }
    
    private func autoCheckClipboardToken() {
        if let clip = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           clip.starts(with: "eyJ") && clip.contains(".") && clip.count > 40 {
            if authService.token != clip {
                self.manualTokenInput = clip
                authService.importToken(clip, baseURL: serverUrlInput)
            }
        }
    }
}
