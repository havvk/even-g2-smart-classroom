import SwiftUI
import AVFoundation


// MARK: - 隔空手势翻页独立测试主视图 (支持单摄与前后双摄同开 PiP)
struct GestureTestView: View {
    @StateObject private var gestureService = AirWaveGestureService.shared
    @Environment(\.presentationMode) var presentationMode
    
    // 双摄画中画主副视窗对调状态：默认后置全景、前置小窗手势识别
    @State private var isFrontInPiP: Bool = true
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    
                    // 0. 单摄 vs 前后双摄模式快速切换开关
                    cameraModeSelectorBar
                    
                    // 1. 实时取景器与手势交互视口 (支持 PiP 画中画，100% 纯净无遮挡)
                    cameraViewportContainer
                    
                    // 1.5 动态手势交互与防误触提示横幅 (置于画面外侧，彻底杜绝遮挡手势信息)
                    gestureActionFeedbackBanner
                    
                    // 2. 当前手势识别遥测与实时指示器
                    gestureTelemetryCard
                    
                    // 3. 翻页统计与联动控制
                    controlAndStatsSection
                    
                    // 4. 手势算法灵敏度微调
                    sensitivitySettingsSection
                    
                    // 5. 开发者手动模拟测试区
                    manualSimulationSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle(gestureService.isDualCameraActive ? "前后双摄 · 手势测试" : "隔空手势翻页测试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !gestureService.isDualCameraActive {
                        Button(action: {
                            gestureService.toggleCameraPosition()
                        }) {
                            Label("翻转镜头", systemImage: "camera.rotate.fill")
                                .font(.caption)
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .onAppear {
                gestureService.start()
            }
            .onDisappear {
                gestureService.stop()
            }
        }
    }
    
    // MARK: - 0. 模式选择分段条
    private var cameraModeSelectorBar: some View {
        HStack(spacing: 8) {
            // 单摄按钮
            Button(action: {
                if gestureService.isDualCameraActive {
                    gestureService.toggleDualCameraMode()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "camera.fill")
                    Text("单镜头模式")
                }
                .font(.subheadline)
                .fontWeight(.bold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(!gestureService.isDualCameraActive ? Color.teal : Color(UIColor.tertiarySystemFill))
                .foregroundColor(!gestureService.isDualCameraActive ? .white : .primary)
                .cornerRadius(10)
            }
            
            // 前后双摄同开按钮
            Button(action: {
                if !gestureService.isDualCameraActive {
                    gestureService.toggleDualCameraMode()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "square.2.layers.3d")
                    Text("前后双摄同开 (PiP)")
                }
                .font(.subheadline)
                .fontWeight(.bold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(gestureService.isDualCameraActive ? Color.purple : Color(UIColor.tertiarySystemFill))
                .foregroundColor(gestureService.isDualCameraActive ? .white : (gestureService.isMultiCamSupported ? .primary : .gray))
                .cornerRadius(10)
            }
        }
        .padding(4)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - 1. 相机视口容器 (单摄全屏 / 双摄画中画)
    private var cameraViewportContainer: some View {
        ZStack {
            if gestureService.isRunning {
                if gestureService.isDualCameraActive {
                    dualCameraLayout
                } else {
                    singleCameraLayout
                }
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(UIColor.secondarySystemBackground))
                    .frame(height: 340)
                    .overlay(
                        VStack(spacing: 8) {
                            ProgressView()
                            Text(gestureService.isAuthorized ? "摄像头会话启动中..." : "等待相机授权...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    )
            }
        }
        .frame(height: 350)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
    
    // MARK: - 1.5 即时动作与冷却反馈横幅 (外置于取景器下方，100% 零遮挡画面识别)
    @ViewBuilder
    private var gestureActionFeedbackBanner: some View {
        let isRecentlyFlipped = (gestureService.lastTriggeredDirection != nil && Date().timeIntervalSince(gestureService.lastGestureTimestamp) < 1.0)
        let isRecentlyBlocked = (gestureService.cooldownBlockedNotice != nil && Date().timeIntervalSince(gestureService.cooldownBlockedTimestamp) < 1.2)
        
        if isRecentlyFlipped, let direction = gestureService.lastTriggeredDirection {
            // 优先级 1：翻页成功通知 (单槽位展示，独占 1.0s，绝不与保护提示并排堆叠)
            HStack(spacing: 10) {
                Image(systemName: direction == .nextPage ? "arrow.left.circle.fill" : "arrow.right.circle.fill")
                    .font(.title3)
                Text(direction.title + " · 翻页指令已下发")
                    .font(.subheadline)
                    .fontWeight(.bold)
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.subheadline)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(direction == .nextPage ? Color.green.opacity(0.18) : Color.blue.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(direction == .nextPage ? Color.green : Color.blue, lineWidth: 1.5)
                    )
            )
            .foregroundColor(direction == .nextPage ? .green : .blue)
            .transition(.scale.combined(with: .opacity))
        } else if isRecentlyBlocked, let notice = gestureService.cooldownBlockedNotice {
            // 优先级 2：反向保护/冷却拦截通知 (在无翻页横幅时才单槽位展示)
            HStack(spacing: 10) {
                Image(systemName: "shield.righthalf.filled")
                    .font(.title3)
                    .foregroundColor(.orange)
                Text(notice)
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundColor(.orange)
                Spacer()
                Text("反向保护")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2))
                    .foregroundColor(.orange)
                    .cornerRadius(4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.orange.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.orange, lineWidth: 1.5)
                    )
            )
            .transition(.scale.combined(with: .opacity))
        }
    }
    
    // MARK: - 单摄布局
    private var singleCameraLayout: some View {
        ZStack {
            let activeLayer = (gestureService.cameraPosition == .front) ? gestureService.frontPreviewLayer : gestureService.backPreviewLayer
            VideoPreviewLayerRepresentable(previewLayer: activeLayer)
            
            if gestureService.cameraPosition == .front {
                handTrajectoryOverlay
            }
            
            // 顶部信息条
            VStack {
                HStack {
                    Label(gestureService.cameraPosition == .front ? "前置镜头 (镜像)" : "后置镜头", systemImage: gestureService.cameraPosition == .front ? "person.crop.circle" : "camera.fill")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.65))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    
                    Spacer()
                    
                    handTrackingStatusCapsule
                }
                .padding(10)
                Spacer()
            }
        }
    }
    
    // MARK: - 双摄并发画中画 (PiP) 布局
    private var dualCameraLayout: some View {
        ZStack {
            // 1. 底层大视窗 (默认后置环境)
            let mainLayer = isFrontInPiP ? gestureService.backPreviewLayer : gestureService.frontPreviewLayer
            VideoPreviewLayerRepresentable(previewLayer: mainLayer)
            
            if !isFrontInPiP {
                handTrajectoryOverlay
            }
            
            // 2. 主视窗左上角标签
            VStack {
                HStack {
                    Label(isFrontInPiP ? "后置主摄 · 讲台/课件环境" : "前置主摄 · 人脸与手势", systemImage: isFrontInPiP ? "camera.fill" : "person.crop.circle")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.7))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    
                    Spacer()
                    
                    HStack(spacing: 4) {
                        Circle().fill(Color.purple).frame(width: 6, height: 6)
                        Text("前后双摄并发")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.purple)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(8)
                }
                .padding(10)
                Spacer()
            }
            
            // 3. 右下角悬浮画中画小窗 (默认前置手势)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    
                    ZStack {
                        let pipLayer = isFrontInPiP ? gestureService.frontPreviewLayer : gestureService.backPreviewLayer
                        VideoPreviewLayerRepresentable(previewLayer: pipLayer)
                        
                        // 若小窗是前置手势流，在小窗内精准叠加手势轨迹与准星
                        if isFrontInPiP {
                            handTrajectoryOverlay
                        }
                        
                        // 小窗指示标签
                        VStack {
                            HStack {
                                Text(isFrontInPiP ? "前置手势流" : "后置环境")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Color.black.opacity(0.75))
                                    .foregroundColor(.white)
                                    .cornerRadius(4)
                                Spacer()
                                Image(systemName: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left")
                                    .font(.system(size: 9))
                                    .foregroundColor(.white)
                            }
                            .padding(4)
                            Spacer()
                        }
                    }
                    .frame(width: 110, height: 145)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white, lineWidth: 2)
                            .shadow(color: .black.opacity(0.4), radius: 4)
                    )
                    .onTapGesture {
                        withAnimation(.spring()) {
                            isFrontInPiP.toggle()
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .padding(12)
                }
            }
        }
    }
    
    // MARK: - 手部关键点准星与轨迹叠加层
    private var handTrajectoryOverlay: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            
            if gestureService.recentTrajectory.count > 1 {
                Path { path in
                    for (idx, item) in gestureService.recentTrajectory.enumerated() {
                        let pt = CGPoint(x: item.point.x * w, y: item.point.y * h)
                        if idx == 0 {
                            path.move(to: pt)
                        } else {
                            path.addLine(to: pt)
                        }
                    }
                }
                .stroke(
                    LinearGradient(
                        colors: [Color.teal.opacity(0.2), Color.teal.opacity(0.8), Color.green],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: max(2, w * 0.015), lineCap: .round, lineJoin: .round)
                )
                
                ForEach(Array(gestureService.recentTrajectory.enumerated()), id: \.element.id) { index, item in
                    Circle()
                        .fill(Color.teal.opacity(Double(index + 1) / Double(gestureService.recentTrajectory.count)))
                        .frame(width: max(4, w * 0.03), height: max(4, w * 0.03))
                        .position(x: item.point.x * w, y: item.point.y * h)
                }
            }
            
            if let handPoint = gestureService.currentHandPoint, gestureService.isHandDetected {
                let posX = handPoint.x * w
                let posY = handPoint.y * h
                let reticleSize = max(24, w * 0.15)
                
                ZStack {
                    Circle()
                        .stroke(Color.green.opacity(0.7), lineWidth: 2)
                        .frame(width: reticleSize, height: reticleSize)
                    Circle()
                        .fill(Color.green)
                        .frame(width: reticleSize * 0.25, height: reticleSize * 0.25)
                    Rectangle()
                        .fill(Color.green.opacity(0.8))
                        .frame(width: reticleSize * 0.5, height: 1.5)
                    Rectangle()
                        .fill(Color.green.opacity(0.8))
                        .frame(width: 1.5, height: reticleSize * 0.5)
                }
                .position(x: posX, y: posY)
                .animation(.easeOut(duration: 0.08), value: handPoint)
            }
        }
        .allowsHitTesting(false)
    }
    
    // MARK: - 手部锁定状态胶囊
    private var handTrackingStatusCapsule: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(gestureService.isHandDetected ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(gestureService.isHandDetected ? String(format: "已锁定手部 (%.0f%%)", gestureService.handConfidence * 100) : "未检测到手")
                .font(.caption2)
                .fontWeight(.bold)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.65))
        .foregroundColor(gestureService.isHandDetected ? .green : .white)
        .cornerRadius(8)
    }
    
    // MARK: - 2. 手势遥测结果与抗干扰卡片
    private var gestureTelemetryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // A. 双摄优先级仲裁条 (讲台模式 vs 巡堂模式)
            HStack(spacing: 8) {
                let isLectern = (gestureService.activeCameraRole == .frontLectern)
                Circle()
                    .fill(isLectern ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                
                Text(gestureService.activeCameraRole.rawValue)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(isLectern ? .green : .orange)
                
                Spacer()
                
                if gestureService.isDualCameraActive {
                    Text(isLectern ? "后摄静音保护中" : "后摄姿态过滤中")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((isLectern ? Color.green : Color.orange).opacity(0.15))
                        .foregroundColor(isLectern ? .green : .orange)
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(UIColor.tertiarySystemFill))
            .cornerRadius(8)
            
            // B. 姿态与过滤遥测指标网格
            HStack(spacing: 8) {
                // 站立讲师
                VStack(spacing: 2) {
                    Text("站姿(讲师)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("\(gestureService.standingPersonCount)")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.green)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
                
                // 坐姿学生
                VStack(spacing: 2) {
                    Text("坐姿(学生)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("\(gestureService.seatedPersonCount)")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
                
                // 已拦截坐姿手势
                VStack(spacing: 2) {
                    Text("拦截干扰")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("\(gestureService.ignoredSeatedGestureCount)")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.orange)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }
            
            // C. 讲师锚定状态与一键重置
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.caption)
                    .foregroundColor(.teal)
                Text(gestureService.teacherAnchorStatus)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                Spacer()
                
                Button(action: {
                    gestureService.resetTeacherAnchor()
                }) {
                    Text("重置锚定")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.teal.opacity(0.15))
                        .foregroundColor(.teal)
                        .cornerRadius(4)
                }
            }
            
            Divider()
            
            // D. 坐姿学生手势过滤开关
            Toggle(isOn: $gestureService.isPoseFilterEnabled) {
                HStack(spacing: 6) {
                    Image(systemName: "figure.walk")
                        .foregroundColor(.indigo)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("坐姿学生手势智能过滤")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("仅响应站立讲师的挥手指令，屏蔽所有坐姿动作")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Divider()
            
            // E. 最近手势动作
            HStack {
                Label(gestureService.isDualCameraActive ? "双摄并发 · 实时手势遥测" : "实时手势遥测", systemImage: "hand.wave.fill")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundColor(gestureService.isDualCameraActive ? .purple : .teal)
                
                Spacer()
                
                if gestureService.isRunning {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text(gestureService.isDualCameraActive ? "前置25FPS / 后置30FPS 并发" : "25 FPS 实时采集中")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // E1. 业务翻页指令通道 (纯净记录真正触发的翻页动作，永久不受冷却干扰)
            HStack(spacing: 12) {
                Image(systemName: gestureService.lastTriggeredDirection == .nextPage ? "arrow.left.circle.fill" : (gestureService.lastTriggeredDirection == .previousPage ? "arrow.right.circle.fill" : "hand.wave.fill"))
                    .font(.title3)
                    .foregroundColor(gestureService.lastTriggeredDirection == .nextPage ? .green : (gestureService.lastTriggeredDirection == .previousPage ? .blue : .secondary))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("最近翻页指令")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(gestureService.lastGestureTitle)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(gestureService.lastTriggeredDirection != nil ? .primary : .secondary)
                }
                
                Spacer()
                
                if gestureService.lastGestureTimestamp != Date.distantPast {
                    Text(gestureService.lastGestureTimestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.tertiarySystemFill))
            .cornerRadius(10)
            
            // E2. 安全防护与防误触通道 (独立显示反向收手阻尼与拦截状态，与手势结果物理分离)
            let isCooldownActive = (gestureService.cooldownBlockedNotice != nil && Date().timeIntervalSince(gestureService.cooldownBlockedTimestamp) < 3.0)
            HStack(spacing: 12) {
                Image(systemName: isCooldownActive ? "shield.righthalf.filled" : "checkmark.shield.fill")
                    .font(.title3)
                    .foregroundColor(isCooldownActive ? .orange : .green)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("防误触保护状态")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    if isCooldownActive, let notice = gestureService.cooldownBlockedNotice {
                        Text(notice)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.orange)
                    } else {
                        Text(String(format: "防护引擎就绪 (反向保护 %.1fs)", gestureService.reverseCooldownInterval))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Text(isCooldownActive ? "拦截中" : "就绪")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((isCooldownActive ? Color.orange : Color.green).opacity(0.18))
                    .foregroundColor(isCooldownActive ? .orange : .green)
                    .cornerRadius(4)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isCooldownActive ? Color.orange.opacity(0.08) : Color(UIColor.tertiarySystemFill).opacity(0.7))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isCooldownActive ? Color.orange.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .padding(14)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(14)
    }
    
    // MARK: - 3. 统计与联动开关
    private var controlAndStatsSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(spacing: 4) {
                    Text("下一页 (向左挥)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(gestureService.nextPageCount)")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.green)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.green.opacity(0.1))
                .cornerRadius(12)
                
                VStack(spacing: 4) {
                    Text("上一页 (向右挥)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(gestureService.prevPageCount)")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.blue)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(12)
            }
            
            Toggle(isOn: $gestureService.isLinkToSmartClassEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "tv.and.mediabox")
                            .foregroundColor(.purple)
                        Text("联动智慧课堂大屏 / 提词器翻页")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    Text("开启后，挥手动作将直接驱动大屏幻灯片与智能眼镜同步切页")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
            
            HStack(spacing: 12) {
                Button(action: {
                    if gestureService.isRunning {
                        gestureService.stop()
                    } else {
                        gestureService.start()
                    }
                }) {
                    HStack {
                        Image(systemName: gestureService.isRunning ? "stop.circle.fill" : "play.circle.fill")
                        Text(gestureService.isRunning ? "暂停摄像头检测" : "开启摄像头检测")
                    }
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(gestureService.isRunning ? Color.orange.opacity(0.15) : Color.teal)
                    .foregroundColor(gestureService.isRunning ? .orange : .white)
                    .cornerRadius(10)
                }
                
                Button(action: {
                    gestureService.resetStats()
                }) {
                    Text("重置计数")
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(UIColor.tertiarySystemFill))
                        .foregroundColor(.primary)
                        .cornerRadius(10)
                }
            }
        }
        .padding(14)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(14)
    }
    
    // MARK: - 4. 算法灵敏度微调
    private var sensitivitySettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("手势算法阈值调优", systemImage: "slider.horizontal.3")
                .font(.subheadline)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("横向触发位移比例")
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.0f%% 屏幕宽", gestureService.minHorizontalDistance * 100))
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.teal)
                }
                Slider(value: $gestureService.minHorizontalDistance, in: 0.12...0.35, step: 0.02)
                    .accentColor(.teal)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("同向连续翻页冷却")
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.2f 秒", gestureService.cooldownInterval))
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.teal)
                }
                Slider(value: $gestureService.cooldownInterval, in: 0.4...1.5, step: 0.05)
                    .accentColor(.teal)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("反向回程防误触冷却")
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.2f 秒", gestureService.reverseCooldownInterval))
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.orange)
                }
                Slider(value: $gestureService.reverseCooldownInterval, in: 1.5...6.0, step: 0.25)
                    .accentColor(.orange)
                Text("挥手后手臂收回（反向位移）期间强力阻尼抑制，杜绝回程动作误翻页")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(14)
    }
    
    // MARK: - 5. 模拟测试专区
    private var manualSimulationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("开发者手动模拟", systemImage: "wrench.and.screwdriver.fill")
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
            
            Text("点击下方按钮可无需在镜头前挥手，直接模拟手势触发以验证与大屏/眼镜协议链路是否畅通。")
                .font(.caption2)
                .foregroundColor(.secondary)
            
            HStack(spacing: 12) {
                Button(action: {
                    gestureService.simulateGesture(direction: .nextPage)
                }) {
                    Label("模拟向左挥 (下一页)", systemImage: "arrow.left")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.green.opacity(0.15))
                        .foregroundColor(.green)
                        .cornerRadius(8)
                }
                
                Button(action: {
                    gestureService.simulateGesture(direction: .previousPage)
                }) {
                    Label("模拟向右挥 (上一页)", systemImage: "arrow.right")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(.blue)
                        .cornerRadius(8)
                }
            }
        }
        .padding(14)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(14)
    }
}
