import SwiftUI
import AVFoundation

// MARK: - 通用 AVCaptureVideoPreviewLayer 容器 (CATransaction 事务安全与尺寸自适应)
struct VideoPreviewLayerRepresentable: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer?
    
    class ContainerView: UIView {
        var currentLayer: AVCaptureVideoPreviewLayer?
        
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            currentLayer?.frame = bounds
            CATransaction.commit()
        }
    }
    
    func makeUIView(context: Context) -> ContainerView {
        let view = ContainerView()
        view.backgroundColor = .black
        view.clipsToBounds = true
        if let layer = previewLayer {
            view.currentLayer = layer
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
        }
        return view
    }
    
    func updateUIView(_ uiView: ContainerView, context: Context) {
        if uiView.currentLayer != previewLayer {
            uiView.currentLayer?.removeFromSuperlayer()
            uiView.currentLayer = previewLayer
            if let layer = previewLayer {
                layer.frame = uiView.bounds
                viewAddSublayerSafe(uiView: uiView, layer: layer)
            }
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            uiView.currentLayer?.frame = uiView.bounds
            CATransaction.commit()
        }
    }
    
    private func viewAddSublayerSafe(uiView: ContainerView, layer: AVCaptureVideoPreviewLayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = uiView.bounds
        uiView.layer.addSublayer(layer)
        CATransaction.commit()
    }
}

// MARK: - 通用手势相机取景视口 (自适应全屏、分割与紧凑模式)
struct GestureCameraViewportView: View {
    @ObservedObject var gestureService = AirWaveGestureService.shared
    
    /// 是否处于紧凑分割模式 (高度约 200) 或全景模式 (高度约 340)
    var isCompact: Bool = false
    
    // 双摄画中画主副视窗对调状态：默认后置全景、前置小窗手势识别
    @State private var isFrontInPiP: Bool = true
    
    var body: some View {
        ZStack {
            if gestureService.isRunning {
                if gestureService.isDualCameraActive {
                    dualCameraLayout
                } else {
                    singleCameraLayout
                }
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(UIColor.secondarySystemBackground))
                    .frame(height: isCompact ? 190 : 320)
                    .overlay(
                        VStack(spacing: 8) {
                            ProgressView()
                            Text(gestureService.isAuthorized ? "手势识别引擎启动中..." : "等待相机授权...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    )
            }
        }
        .frame(height: isCompact ? 190 : 320)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
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
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.65))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    
                    Spacer()
                    
                    handTrackingStatusCapsule
                }
                .padding(8)
                Spacer()
            }
        }
    }
    
    // MARK: - 双摄并发画中画 (PiP) 布局
    private var dualCameraLayout: some View {
        ZStack {
            // 1. 底层大视窗
            let mainLayer = isFrontInPiP ? gestureService.backPreviewLayer : gestureService.frontPreviewLayer
            VideoPreviewLayerRepresentable(previewLayer: mainLayer)
            
            if !isFrontInPiP {
                handTrajectoryOverlay
            }
            
            // 2. 主视窗左上角标签
            VStack {
                HStack {
                    Label(isFrontInPiP ? "后置环境" : "前置手势", systemImage: isFrontInPiP ? "camera.fill" : "person.crop.circle")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.7))
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    
                    Spacer()
                    
                    HStack(spacing: 4) {
                        Circle().fill(Color.purple).frame(width: 5, height: 5)
                        Text("双摄并发")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.purple)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(6)
                }
                .padding(8)
                Spacer()
            }
            
            // 3. 悬浮画中画小窗
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    
                    ZStack {
                        let pipLayer = isFrontInPiP ? gestureService.frontPreviewLayer : gestureService.backPreviewLayer
                        VideoPreviewLayerRepresentable(previewLayer: pipLayer)
                        
                        if isFrontInPiP {
                            handTrajectoryOverlay
                        }
                        
                        // 小窗指示标签
                        VStack {
                            HStack {
                                Text(isFrontInPiP ? "前摄手势" : "后摄环境")
                                    .font(.system(size: 8, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Color.black.opacity(0.75))
                                    .foregroundColor(.white)
                                    .cornerRadius(4)
                                Spacer()
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 8))
                                    .foregroundColor(.white)
                            }
                            .padding(3)
                            Spacer()
                        }
                    }
                    .frame(width: isCompact ? 80 : 100, height: isCompact ? 105 : 130)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white, lineWidth: 1.5)
                            .shadow(color: .black.opacity(0.4), radius: 3)
                    )
                    .onTapGesture {
                        withAnimation(.spring()) {
                            isFrontInPiP.toggle()
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .padding(8)
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
            }
            
            if let handPoint = gestureService.currentHandPoint, gestureService.isHandDetected {
                let posX = handPoint.x * w
                let posY = handPoint.y * h
                let reticleSize = max(20, w * 0.14)
                
                ZStack {
                    Circle()
                        .stroke(Color.green.opacity(0.8), lineWidth: 2)
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
        HStack(spacing: 5) {
            Circle()
                .fill(gestureService.isHandDetected ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            Text(gestureService.isHandDetected ? String(format: "已锁定手部 (%.0f%%)", gestureService.handConfidence * 100) : "未检测到手")
                .font(.system(size: 9, weight: .bold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.65))
        .foregroundColor(gestureService.isHandDetected ? .green : .white)
        .cornerRadius(6)
    }
}

// MARK: - 可拖拽画中画浮窗组件 (Floating PiP for Teleprompter Mode)
struct GestureFloatingPiPView: View {
    @ObservedObject var gestureService = AirWaveGestureService.shared
    @State private var dragOffset: CGSize = .zero
    @State private var currentPosition: CGSize = CGSize(width: 16, height: -24)
    @State private var isCollapsed: Bool = false
    
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Circle()
                    .fill(gestureService.isHandDetected ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(isCollapsed ? "手势" : "手势视口")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: {
                    withAnimation(.spring()) {
                        isCollapsed.toggle()
                    }
                }) {
                    Image(systemName: isCollapsed ? "arrow.up.left.and.arrow.down.right" : "minus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.85))
            
            if !isCollapsed {
                ZStack {
                    let activeLayer = (gestureService.cameraPosition == .front) ? gestureService.frontPreviewLayer : gestureService.backPreviewLayer
                    VideoPreviewLayerRepresentable(previewLayer: activeLayer)
                    
                    if let handPoint = gestureService.currentHandPoint, gestureService.isHandDetected {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 10, height: 10)
                            .position(x: handPoint.x * 100, y: handPoint.y * 135)
                    }
                }
                .frame(width: 100, height: 135)
            }
        }
        .frame(width: isCollapsed ? 75 : 100)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.teal.opacity(0.6), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
        .offset(x: currentPosition.width + dragOffset.width, y: currentPosition.height + dragOffset.height)
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = value.translation
                }
                .onEnded { value in
                    currentPosition.width += value.translation.width
                    currentPosition.height += value.translation.height
                    dragOffset = .zero
                }
        )
    }
}

// MARK: - 通用手势遥测与状态展示子卡片 (支持全景与分割模式复用)
struct GestureTelemetrySubcard: View {
    @ObservedObject var gestureService = AirWaveGestureService.shared
    var isCompact: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A. 双摄优先级仲裁与模式标签
            HStack(spacing: 8) {
                let isLectern = (gestureService.activeCameraRole == .frontLectern)
                Circle()
                    .fill(isLectern ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                
                Text(gestureService.activeCameraRole.rawValue)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(isLectern ? .green : .orange)
                
                Spacer()
                
                if gestureService.isDualCameraActive {
                    Text(isLectern ? "后摄静音保护中" : "后摄姿态过滤中")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background((isLectern ? Color.green : Color.orange).opacity(0.15))
                        .foregroundColor(isLectern ? .green : .orange)
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(UIColor.tertiarySystemFill))
            .cornerRadius(6)
            
            // B. 姿态遥测指标网格
            HStack(spacing: 6) {
                // 站立讲师
                VStack(spacing: 1) {
                    Text("站姿(讲师)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("\(gestureService.standingPersonCount)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.green)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.1))
                .cornerRadius(6)
                
                // 坐姿学生
                VStack(spacing: 1) {
                    Text("坐姿(学生)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("\(gestureService.seatedPersonCount)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(6)
                
                // 拦截干扰
                VStack(spacing: 1) {
                    Text("拦截干扰")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("\(gestureService.ignoredSeatedGestureCount)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.orange)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            }
            
            // C. 讲师锚定状态与一键重置
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 10))
                    .foregroundColor(.teal)
                Text(gestureService.teacherAnchorStatus)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                Spacer()
                
                Button(action: {
                    gestureService.resetTeacherAnchor()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }) {
                    Text("重置锚定")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.teal.opacity(0.15))
                        .foregroundColor(.teal)
                        .cornerRadius(4)
                }
            }
            
            // D. 业务翻页指令通道 (纯净独立)
            HStack(spacing: 10) {
                Image(systemName: gestureService.lastTriggeredDirection == .nextPage ? "arrow.left.circle.fill" : (gestureService.lastTriggeredDirection == .previousPage ? "arrow.right.circle.fill" : "hand.wave.fill"))
                    .font(.system(size: 16))
                    .foregroundColor(gestureService.lastTriggeredDirection == .nextPage ? .green : (gestureService.lastTriggeredDirection == .previousPage ? .blue : .secondary))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("最近翻页指令")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(gestureService.lastGestureTitle)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(gestureService.lastTriggeredDirection != nil ? .primary : .secondary)
                }
                
                Spacer()
                
                if gestureService.lastGestureTimestamp != Date.distantPast {
                    Text(gestureService.lastGestureTimestamp, style: .time)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.tertiarySystemFill))
            .cornerRadius(8)
            
            // E. 安全防误触阻尼状态行
            let isCooldownActive = (gestureService.cooldownBlockedNotice != nil && Date().timeIntervalSince(gestureService.cooldownBlockedTimestamp) < 3.0)
            HStack(spacing: 10) {
                Image(systemName: isCooldownActive ? "shield.righthalf.filled" : "checkmark.shield.fill")
                    .font(.system(size: 16))
                    .foregroundColor(isCooldownActive ? .orange : .green)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("防误触保护状态")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    if isCooldownActive, let notice = gestureService.cooldownBlockedNotice {
                        Text(notice)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.orange)
                    } else {
                        Text(String(format: "防护引擎就绪 (反向保护 %.1fs)", gestureService.reverseCooldownInterval))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Text(isCooldownActive ? "拦截中" : "就绪")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background((isCooldownActive ? Color.orange : Color.green).opacity(0.18))
                    .foregroundColor(isCooldownActive ? .orange : .green)
                    .cornerRadius(4)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isCooldownActive ? Color.orange.opacity(0.08) : Color(UIColor.tertiarySystemFill).opacity(0.7))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isCooldownActive ? Color.orange.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .padding(10)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

