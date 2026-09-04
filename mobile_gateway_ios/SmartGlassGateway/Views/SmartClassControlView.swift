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
    
    @State private var serverUrlInput: String = "https://syb.ncu.edu.cn"
    @State private var sessionIdInput: String = "c81431e6"
    
    // 登录模式：默认优先 0: 粘贴/剪贴板 Token 导入（最稳定），1: 统一身份认证 WebView 弹窗
    @State private var showCASSheet: Bool = false
    @State private var manualTokenInput: String = ""
    @State private var bleStatusToast: String? = nil
    
    // 页内微步滚动
    @State private var scrollLineIndex: Double = 0
    @State private var showConnectionSettings: Bool = false
    
    var body: some View {
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
        .navigationTitle("智慧课堂 HUD 辅驾")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            serverUrlInput = lectureManager.baseURL
            sessionIdInput = lectureManager.sessionId
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
                
                // 状态指示灯
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(webSocketClient.isConnected ? Color.green : Color.red)
                            .frame(width: 7, height: 7)
                        Text(webSocketClient.isConnected ? "大屏在线" : "大屏未连")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 4) {
                        Circle()
                            .fill(bleManager.isReadyForTeleprompter ? Color.green : (bleManager.isConnected ? Color.yellow : Color.orange))
                            .frame(width: 7, height: 7)
                        Text(bleManager.isReadyForTeleprompter ? "G2就绪" : (bleManager.isConnected ? "通道配置中" : "眼镜未连"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
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
            HStack {
                Label("随身提词监看 HUD", systemImage: "eyeglasses")
                    .font(.headline)
                    .foregroundColor(.purple)
                Spacer()
                
                // 🌟 物理硬件屏显确认与推屏状态指示（可点击一键重推复位）
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
                    HStack(spacing: 4) {
                        Circle()
                            .fill(bleManager.isHardwareRenderConfirmed ? Color.green : (bleManager.isPushingText ? Color.yellow : Color.red))
                            .frame(width: 7, height: 7)
                        Text(bleManager.teleprompterPushStatusMessage)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(bleManager.isHardwareRenderConfirmed ? .green : (bleManager.isPushingText ? .orange : .red))
                        if !bleManager.isHardwareRenderConfirmed && !bleManager.isPushingText {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.red)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(bleManager.isHardwareRenderConfirmed ? Color(UIColor.tertiarySystemBackground) : Color.red.opacity(0.12))
                    .cornerRadius(6)
                }
                .buttonStyle(PlainButtonStyle())
                
                // 大字号页码指示器 (对齐 0-based 转换为 1-based 讲台显示)
                Text("P \(String(format: "%02d", lectureManager.currentSlideIndex + 1)) / \(String(format: "%02d", lectureManager.totalSlides))")
                    .font(.system(.title3, design: .monospaced))
                    .fontWeight(.heavy)
                    .foregroundColor(.purple)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.purple.opacity(0.12))
                    .cornerRadius(8)
            }
            
            // 幻灯片标题
            Text(lectureManager.currentSlideTitle)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)
            
            // 纯净口述稿视口内容 (固定高度 160pt，内嵌独立垂直滚动条，确保全屏控件均在可视画面内)
            ScrollView(.vertical, showsIndicators: true) {
                Text(lectureManager.currentScriptText)
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .lineSpacing(5)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 160) // 🌟 固定高度 160pt，提词视口恒定，内部显示垂直滚动条
            .background(Color(UIColor.tertiarySystemBackground))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.purple.opacity(0.15), lineWidth: 1)
            )
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }
    
    // MARK: - 卡片 4: 激光笔平级双向控屏手柄
    private var controlActionsCard: some View {
        VStack(spacing: 10) {
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
