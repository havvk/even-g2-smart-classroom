import Foundation
import Combine
import UIKit

/// 智慧课堂课时与智能眼镜提词总调度器 (Single Source of Truth 状态机)
class LectureSessionManager: ObservableObject {
    static let shared = LectureSessionManager()
    
    // MARK: - Published 状态
    @Published var baseURL: String = "https://syb.ncu.edu.cn"
    @Published var sessionId: String = "c81431e6"
    @Published var sessionInfo: SmartClassSessionInfo?
    @Published var currentSlideIndex: Int = 0 // 0-based
    @Published var totalSlides: Int = 1
    @Published var slideScriptDict: [Int: String] = [:] // [slide_index: 口述稿]
    @Published var slideTitleDict: [Int: String] = [:]  // [slide_index: 标题]
    @Published var availableSessions: [SmartClassCourseSession] = []
    @Published var activeSessionId: String? = nil
    @Published var currentLineIndex: Int = 0
    @Published var isLoading: Bool = false
    @Published var lastSyncError: String?
    
    // 当前页口述稿展示
    var currentScriptText: String {
        return slideScriptDict[currentSlideIndex] ?? "本页暂无口述提词"
    }
    
    var currentSlideTitle: String {
        return slideTitleDict[currentSlideIndex] ?? "幻灯片 \(currentSlideIndex + 1)"
    }
    
    // 依赖注入
    var webSocketClient: WebSocketClient?
    var bleManager: BLEManager?
    
    private var cancellables = Set<AnyCancellable>()
    private var lastSlideSwitchTime = Date.distantPast
    private var lastLocalPageRequestTime = Date.distantPast
    private var lastSessionSwitchTime = Date.distantPast
    private var glassesPushThrottleWorkItem: DispatchWorkItem?
    private var pageNavPersistWorkItem: DispatchWorkItem?
    
    init() {}
    
    /// 配置依赖网关
    func setup(webSocketClient: WebSocketClient, bleManager: BLEManager) {
        self.webSocketClient = webSocketClient
        self.bleManager = bleManager
        
        // 监听 WebSocket 切页广播
        webSocketClient.onSlidePageChanged = { [weak self] pageIndex in
            self?.handleRemotePageChange(pageIndex)
        }
        
        // 监听 WebSocket 滚行广播 (TELEPROMPTER_SCROLL)
        webSocketClient.onTeleprompterScrollRequested = { [weak self] delta in
            self?.scrollByLineDelta(delta)
        }
        
        // 监听大屏/导播台活跃课时切换广播
        webSocketClient.onActiveSessionChanged = { [weak self] newActiveSid in
            guard let self = self, !newActiveSid.isEmpty else { return }
            NSLog("📢 [WebSocket] 监听到大屏活跃课时切换至: %@", newActiveSid)
            DispatchQueue.main.async {
                self.activeSessionId = newActiveSid
                let elapsed = Date().timeIntervalSince(self.lastSessionSwitchTime)
                // 🛡️ 只有当本地不在主动切课保护期 (3.0s)，且大屏活跃课时确实与当前不同时，才平滑跟随
                if elapsed > 3.0 && newActiveSid != self.sessionId {
                    NSLog("🔄 [LectureManager] 响应大屏课时变更广播，平滑跟随加载: %@", newActiveSid)
                    self.lastSessionSwitchTime = Date()
                    self.sessionId = newActiveSid
                    self.loadLectureSession(baseURL: self.baseURL, sessionId: newActiveSid)
                }
            }
        }
        
        // 监听 Even G2 眼镜端实际视口渲染行号上报（物理触底对齐）
        bleManager.onGlassesViewportLineReported = { [weak self] actualLine in
            DispatchQueue.main.async {
                if self?.currentLineIndex != actualLine {
                    self?.currentLineIndex = actualLine
                    self?.syncStateToWatch(lineIndex: actualLine)
                }
            }
        }
        
        // 监听 Even G2 蓝牙链路完全就绪（断线重连恢复后自动补推当前页）
        bleManager.onGlassesReadyToRender = { [weak self] in
            guard let self = self else { return }
            NSLog("👓 [LectureManager] 监听到 Even G2 蓝牙链路通道全量就绪，自动补推当前幻灯片提词！")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.pushCurrentSlideToGlasses(force: true)
            }
        }
    }
    
    // MARK: - 1. 加载课时全量剧本并完成本地初始化
    func loadLectureSession(baseURL: String? = nil, sessionId: String? = nil, completion: ((Bool) -> Void)? = nil) {
        if let base = baseURL, !base.isEmpty { self.baseURL = base }
        if let sid = sessionId, !sid.isEmpty { self.sessionId = sid }
        
        DispatchQueue.main.async {
            self.isLoading = true
            self.lastSyncError = nil
        }
        
        SmartClassAPIService.shared.fetchSessionInfo(baseURL: self.baseURL, sessionId: self.sessionId) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(let info):
                    self.sessionInfo = info
                    self.buildSlideDictionary(from: info)
                    self.currentSlideIndex = max(0, info.currentPageIndex ?? info.savedPageIndex ?? 0)
                    
                    // 自动异步拉取同课程下的所有可用课时列表与当前大屏活跃课时
                    if let cid = info.courseId {
                        SmartClassAPIService.shared.fetchCourseSessions(baseURL: self.baseURL, courseId: cid) { [weak self] res in
                            if case .success(let list) = res {
                                DispatchQueue.main.async {
                                    self?.availableSessions = list
                                }
                            }
                        }
                        SmartClassAPIService.shared.fetchActiveSession(baseURL: self.baseURL, courseId: cid) { [weak self] asid in
                            guard let self = self, let asid = asid, !asid.isEmpty else { return }
                            DispatchQueue.main.async {
                                self.activeSessionId = asid
                            }
                        }
                    }
                    
                    // 建立带有 Token 的 WebSocket 实时监听 (自适应 wss / ws)
                    let wsScheme = self.baseURL.lowercased().starts(with: "https") ? "wss" : "ws"
                    var cleanHost = self.baseURL.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
                    cleanHost = cleanHost.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    if cleanHost.hasSuffix("/smart-class") {
                        cleanHost = String(cleanHost.dropLast("/smart-class".count))
                    }
                    let wsURLStr = "\(wsScheme)://\(cleanHost)/smart-class/ws/session/\(self.sessionId)"
                    self.webSocketClient?.connect(urlString: wsURLStr, token: AuthService.shared.token)
                    
                    // 首帧提词推送至智能眼镜与 Apple Watch
                    self.pushCurrentSlideToGlasses(force: true)
                    self.syncStateToWatch()
                    completion?(true)
                    
                case .failure(let error):
                    self.lastSyncError = error.localizedDescription
                    completion?(false)
                }
            }
        }
    }
    
    // MARK: - 2. 构建本地幻灯片剧本字典
    private func buildSlideDictionary(from info: SmartClassSessionInfo) {
        var scripts: [Int: [String]] = [:]
        var titles: [Int: String] = [:]
        var maxSlide = 0
        
        // 1. 优先提取预解析好的纯净语音段落 (Playbook segments)
        if let segments = info.playbookData?.segments {
            for seg in segments {
                let idx = seg.slideIndex
                if scripts[idx] == nil { scripts[idx] = [] }
                if let t = seg.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    scripts[idx]?.append(t)
                }
                if idx > maxSlide { maxSlide = idx }
            }
        }
        
        // 2. 解析原始 Markdown 课件
        let rawContent = info.script ?? info.markdown ?? ""
        if !rawContent.isEmpty {
            var normalized = rawContent.replacingOccurrences(of: "\r\n", with: "\n")
                                       .replacingOccurrences(of: "\r", with: "\n")
            
            // 剥离 YAML frontmatter 避免污染第 0 页
            if normalized.hasPrefix("---\n") {
                let afterFirst = normalized.index(normalized.startIndex, offsetBy: 4)
                if let secondDelim = normalized.range(of: "\n---\n", range: afterFirst..<normalized.endIndex) {
                    normalized = String(normalized[secondDelim.upperBound...])
                }
            }
            
            // 拆分幻灯片页面
            let rawPages = normalized.components(separatedBy: "\n---\n")
            let pages = rawPages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            
            if pages.count > maxSlide + 1 {
                maxSlide = max(pages.count - 1, 0)
            }
            
            for (idx, page) in pages.enumerated() {
                var pageScriptLines: [String] = []
                var pageTitle: String? = nil
                
                // A. 提取 :::playbook ... ::: 逐字稿块 (兼容 ::: playbook 与 :::playbook)
                let normPage = page.replacingOccurrences(of: "::: playbook", with: ":::playbook")
                                   .replacingOccurrences(of: ":::Playbook", with: ":::playbook")
                if normPage.contains(":::playbook") {
                    let parts = normPage.components(separatedBy: ":::playbook")
                    for part in parts.dropFirst() {
                        if let endIdx = part.range(of: ":::")?.lowerBound {
                            var playbookText = String(part[..<endIdx])
                            if let regex = try? NSRegularExpression(pattern: "\\(Visual:[^)]*\\)", options: .caseInsensitive) {
                                playbookText = regex.stringByReplacingMatches(in: playbookText, options: [], range: NSRange(location: 0, length: playbookText.utf16.count), withTemplate: "")
                            }
                            let trimmed = playbookText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                pageScriptLines.append(trimmed)
                            }
                        }
                    }
                }
                
                // B. 提取 HTML 注释演讲备忘 <!-- ... -->
                if page.contains("<!--") {
                    if let regex = try? NSRegularExpression(pattern: "<!--([\\s\\S]*?)-->", options: []) {
                        let nsStr = page as NSString
                        let matches = regex.matches(in: page, options: [], range: NSRange(location: 0, length: page.utf16.count))
                        for match in matches {
                            if match.numberOfRanges > 1 {
                                let note = nsStr.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                                let lower = note.lowercased()
                                if !note.isEmpty &&
                                   !note.hasPrefix("_") &&
                                   !lower.contains("theme:") &&
                                   !lower.contains("marp:") &&
                                   !lower.contains("paginate:") &&
                                   !lower.contains("class:") {
                                    pageScriptLines.append(note)
                                }
                            }
                        }
                    }
                }
                
                // C. 提取标题与正文核心要点（去除 Markdown 格式符号）
                var bodyLines: [String] = []
                let lines = page.components(separatedBy: "\n")
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty || trimmed.starts(with: ":::") || trimmed.starts(with: "<!--") || trimmed.starts(with: "-->") {
                        continue
                    }
                    if trimmed.starts(with: "# ") {
                        if pageTitle == nil {
                            pageTitle = trimmed.replacingOccurrences(of: "# ", with: "").trimmingCharacters(in: .whitespaces)
                        }
                    } else if trimmed.starts(with: "## ") {
                        if pageTitle == nil {
                            pageTitle = trimmed.replacingOccurrences(of: "## ", with: "").trimmingCharacters(in: .whitespaces)
                        }
                    } else if trimmed.starts(with: "### ") {
                        bodyLines.append(trimmed.replacingOccurrences(of: "### ", with: ""))
                    } else if trimmed.starts(with: "- ") || trimmed.starts(with: "* ") {
                        let cleanBullet = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                        bodyLines.append("• " + cleanBullet)
                    } else if !trimmed.starts(with: "!") && !trimmed.starts(with: "<") {
                        bodyLines.append(trimmed)
                    }
                }
                
                if let t = pageTitle {
                    titles[idx] = t
                }
                
                // 如果本页没有已解析的 playbook，优先使用提取出的逐字稿或正文提要
                if scripts[idx] == nil || scripts[idx]?.isEmpty == true {
                    if !pageScriptLines.isEmpty {
                        scripts[idx] = pageScriptLines
                    } else if !bodyLines.isEmpty {
                        scripts[idx] = bodyLines
                    }
                }
            }
        }
        
        // 组装最终口述稿字典
        var finalDict: [Int: String] = [:]
        for idx in 0...max(maxSlide, 0) {
            let title = titles[idx] ?? "第 \(idx + 1) 页"
            if let segList = scripts[idx], !segList.isEmpty {
                let content = segList.joined(separator: "\n")
                if content.hasPrefix("【") {
                    finalDict[idx] = content
                } else {
                    finalDict[idx] = "【\(title)】\n\(content)"
                }
            } else {
                finalDict[idx] = "【\(title)】\n（本页未设提词，请结合大屏内容讲解）"
            }
        }
        
        self.slideScriptDict = finalDict
        self.slideTitleDict = titles
        self.totalSlides = max(maxSlide + 1, 1)
        NSLog("📚 [LectureManager] 课时解析完成: 共 %ld 页，已载入提词 %ld 条", self.totalSlides, finalDict.count)
    }
    
    // MARK: - 3. 响应大屏/导播台切页通知 (正向跟随)
    private func handleRemotePageChange(_ newPageIndex: Int) {
        // 🛡️ 手机本地主控期保护（600ms 内）：
        // 当用户刚在手机上连续点击了“下一页/上一页”时，严禁被过期的网络回声或旧页面反向拉回！
        let timeSinceLocalChange = Date().timeIntervalSince(lastLocalPageRequestTime)
        if timeSinceLocalChange < 0.600 {
            NSLog("🛡️ [切页主控期] 手机本地切页窗口期 (%.2fs < 0.6s)，已拦截远端页码回波: %ld (本地坚守: %ld)", timeSinceLocalChange, newPageIndex, currentSlideIndex)
            return
        }
        
        // 幂等防重与 100ms 快速滑动防抖
        guard newPageIndex != currentSlideIndex else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSlideSwitchTime) > 0.100 else { return }
        lastSlideSwitchTime = now
        
        DispatchQueue.main.async {
            self.currentSlideIndex = max(0, min(newPageIndex, self.totalSlides - 1))
            self.currentLineIndex = 0 // 换页时视口行号自动归零
            self.pushCurrentSlideToGlasses(force: true)
            self.syncStateToWatch()
        }
    }
    
    // MARK: - 4. 推送当前幻灯片提词至 Even G2 智能眼镜
    func pushCurrentSlideToGlasses(force: Bool = false) {
        guard let ble = bleManager else { return }
        guard ble.isReadyForTeleprompter else {
            NSLog("⚠️ [LectureManager] Even G2 眼镜通道未完全就绪 (isReadyForTeleprompter=false)，暂缓提词推送")
            return
        }
        guard !slideScriptDict.isEmpty else {
            NSLog("⏳ [LectureManager] 课时逐字稿尚未载入解析完成，暂缓推流至眼镜")
            return
        }
        let text = self.currentScriptText
        NSLog("👓 [LectureManager] 推送第 %ld 页提词至眼镜 (长度 %ld)", currentSlideIndex + 1, text.count)
        
        if force {
            ble.lastSentTeleprompterText = ""
        }
        
        // 归零手机端内部视口游标，并权威锚定当前幻灯片真实排版总行数
        let actualTotal = self.getWrappedScriptLines().count
        self.currentLineIndex = 0
        ble.currentFocusPageLine = 0
        ble.currentTotalLines = max(actualTotal, 1)
        
        // 切页时下发整页文本，并设置从第 0 行开始
        ble.sendTeleprompterText(text, targetWidthChars: 28, scrollModeAI: false, startLine: 0)
    }
    
    // MARK: - 5. 手势/手表反向控屏 (调用生产 POST page-nav)
    func gotoNextSlide() {
        guard currentSlideIndex < totalSlides - 1 else { return }
        let target = currentSlideIndex + 1
        requestPageChange(target: target)
    }
    
    func gotoPrevSlide() {
        guard currentSlideIndex > 0 else { return }
        let target = currentSlideIndex - 1
        requestPageChange(target: target)
    }
    
    func gotoSlide(index: Int) {
        guard index >= 0, index < totalSlides, index != currentSlideIndex else { return }
        requestPageChange(target: index)
    }
    
    private func requestPageChange(target: Int) {
        let now = Date()
        self.lastLocalPageRequestTime = now
        
        // 1. 本地状态与 UI 瞬时 60fps 乐观更新
        self.currentSlideIndex = target
        self.currentLineIndex = 0
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        self.syncStateToWatch()
        
        // 2. 优先通过 WebSocket 极速直发切页（毫秒级、物理保序、服务端自动排除自身回波）
        if let ws = webSocketClient, ws.isConnected {
            ws.sendPageNav(targetPage: target)
        } else {
            // 若 WebSocket 离线，走标准 HTTP POST page-nav 备选通道
            SmartClassAPIService.shared.notifyPageNav(baseURL: self.baseURL, sessionId: self.sessionId, targetPage: target)
        }
        
        // 3. 🛡️ 智能防抖推镜 (150ms 尾随防抖)：
        // 连续快速点击“下一页”时，绝不为中间页盲目阻塞 BLE 管道，只把最终落定的目标页推向眼镜
        glassesPushThrottleWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pushCurrentSlideToGlasses(force: true)
        }
        self.glassesPushThrottleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.150, execute: item)
        
        // 4. 🛡️ 1 秒防抖持久化落库 (PUT page-index)
        pageNavPersistWorkItem?.cancel()
        let persistItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            SmartClassAPIService.shared.persistPageIndex(baseURL: self.baseURL, sessionId: self.sessionId, pageIndex: target)
        }
        self.pageNavPersistWorkItem = persistItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: persistItem)
    }
    
    // MARK: - 6. 页内长文本 (>9行) 微步滚动控制
    func scrollGlassesToLine(_ lineIndex: Int) {
        guard let ble = bleManager, ble.isConnected else { return }
        self.currentLineIndex = lineIndex
        ble.sendScrollSync(lineIndex: lineIndex)
        self.syncStateToWatch(lineIndex: lineIndex, forceImmediate: true)
    }
    
    /// 按相对行号增量滚动（如 +1 下移一行，-1 上移一行）
    func scrollByLineDelta(_ delta: Int) {
        guard let ble = bleManager, ble.isConnected else { return }
        let maxLine = ble.maxMovableLine
        let target = min(max(self.currentLineIndex + delta, 0), maxLine)
        
        // 🛡️ 边界锁死保护：若已达物理显示边界且继续同向越界滑动，锁定当前边界并拦截无谓发包
        guard target != self.currentLineIndex else {
            self.currentLineIndex = max(0, min(maxLine, self.currentLineIndex))
            ble.currentFocusPageLine = self.currentLineIndex
            NSLog("🛑 [ScrollSync] 视口已达物理显示边界 (当前: %ld, 限制范围: 0~%ld)，锁定位置并拦截越界发包", self.currentLineIndex, maxLine)
            return
        }
        
        DispatchQueue.main.async {
            self.currentLineIndex = target
            ble.sendScrollSync(lineIndex: target, force: true)
            self.syncStateToWatch(lineIndex: target, forceImmediate: true)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            NSLog("📜 [ScrollSync] 视口平移至第 %ld 行 (delta: %ld, 物理边界: 0~%ld)", target, delta, maxLine)
        }
    }
    
    // MARK: - 7. 激活课时为主屏幕当前授课课时
    func activateSession(_ targetSessionId: String, completion: ((Bool) -> Void)? = nil) {
        self.lastSessionSwitchTime = Date()
        self.activeSessionId = targetSessionId
        self.sessionId = targetSessionId
        self.loadLectureSession(baseURL: self.baseURL, sessionId: targetSessionId)
        
        SmartClassAPIService.shared.activateSession(baseURL: self.baseURL, sessionId: targetSessionId) { [weak self] res in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch res {
                case .success(let sid):
                    self.activeSessionId = sid
                    self.sessionId = sid
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    NSLog("✅ [LectureManager] 课时 %@ 成功激活为主屏授课课时", sid)
                    completion?(true)
                case .failure(let err):
                    NSLog("⚠️ 激活课时接口未成功返回: %@", err.localizedDescription)
                    completion?(false)
                }
            }
        }
    }
    
    // MARK: - 8. 状态与当前提词视口位置实时同步至 Apple Watch
    
    /// 获取当前页按 Even G2 规格拆分的全部排版行
    func getWrappedScriptLines() -> [String] {
        let text = self.currentScriptText
        let maxLineWidth = 28 * 2
        let (pages, _) = G2ProtocolEncoder.formatTextToPagesOnDemand(text, maxLineWidth: maxLineWidth, linesPerPage: 10)
        let lines = pages.flatMap { $0.components(separatedBy: "\n") }
        return lines.isEmpty ? ["暂无口述提词"] : lines
    }
    
    /// 同步状态、页码、当前行号与视口切片至 Apple Watch
    func syncStateToWatch(lineIndex: Int? = nil, forceImmediate: Bool = false) {
        let displayPage = self.currentSlideIndex + 1
        let displayTotal = max(self.totalSlides, 1)
        let allLines = self.getWrappedScriptLines()
        let totalLines = max(allLines.count, 1)
        
        // 确定当前视口行号 (以物理视口顶端最大行号为上限，确保手表与眼镜、手机 100% 物理对齐)
        let targetLine = lineIndex ?? self.currentLineIndex
        let maxTopLine = max(totalLines - BLEManager.physicalViewportLines, 0)
        let safeLine = max(0, min(targetLine, maxTopLine))
        self.currentLineIndex = safeLine
        
        // 切割从当前行开始的提词切片 (向后取 10 行，充分利用 Apple Watch 纵向物理视野)
        let slice = allLines[safeLine..<min(safeLine + 10, allLines.count)]
        let viewportText = slice.joined(separator: "\n")
        
        let isConnected = self.webSocketClient?.isConnected ?? false
        WatchSessionManager.shared.syncStateToWatch(
            currentPage: displayPage,
            totalPages: displayTotal,
            currentLine: safeLine + 1,
            totalLines: totalLines,
            currentText: viewportText,
            fullText: self.currentScriptText,
            isServerConnected: isConnected,
            forceImmediate: forceImmediate
        )
    }
}
