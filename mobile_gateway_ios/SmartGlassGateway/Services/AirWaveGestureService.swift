import Foundation
import AVFoundation
import Vision
import UIKit
import Combine

/// 隔空挥手手势翻页服务 (Air Wave Gesture Service)
/// 支持两种采流模式：
/// 1. 【单摄模式】：标准 AVCaptureSession，可在前置/后置之间切换；
/// 2. 【前后双摄同开模式 (MultiCam)】：采用 AVCaptureMultiCamSession 同时开启前置与后置摄像头。
///    - 后置摄像头：输出大屏环境/讲台全景流；
///    - 前置摄像头：以 25 FPS 输出人脸/人手流，驱动 Apple Vision 关键点识别与时序挥手翻页。
final class AirWaveGestureService: NSObject, ObservableObject {
    static let shared = AirWaveGestureService()
    
    // MARK: - 翻页方向枚举
    enum FlipDirection {
        case nextPage      // 下一页 (向左划动)
        case previousPage  // 上一页 (向右划动)
        
        var title: String {
            switch self {
            case .nextPage: return "👈 向左挥动：下一页"
            case .previousPage: return "👉 向右挥动：上一页"
            }
        }
    }
    
    // MARK: - 时序轨迹点
    struct TimedTrajectoryPoint: Identifiable {
        let id = UUID()
        let point: CGPoint          // 归一化坐标 (0...1, 原点对齐左上角供 UI 绘制)
        let timestamp: TimeInterval
    }
    
    // MARK: - UI 状态发布
    @Published var isRunning: Bool = false
    @Published var isAuthorized: Bool = false
    @Published var isDualCameraActive: Bool = false
    @Published var isMultiCamSupported: Bool = AVCaptureMultiCamSession.isMultiCamSupported
    @Published var cameraPosition: AVCaptureDevice.Position = .front
    @Published var isHandDetected: Bool = false
    @Published var handConfidence: Float = 0.0
    
    // 实时手部关键点坐标与最近轨迹 (归一化 0.0~1.0，原点左上角)
    @Published var currentHandPoint: CGPoint? = nil
    @Published var recentTrajectory: [TimedTrajectoryPoint] = []
    
    // 手势识别结果与反馈
    @Published var lastGestureTitle: String = "待命中 (请在镜头前挥手)"
    @Published var lastGestureTimestamp: Date = Date.distantPast
    @Published var lastTriggeredDirection: FlipDirection? = nil
    
    // 冷却期拦截通知 (向用户明确反馈)
    @Published var cooldownBlockedNotice: String? = nil
    @Published var cooldownBlockedTimestamp: Date = Date.distantPast
    
    // 翻页统计
    @Published var nextPageCount: Int = 0
    @Published var prevPageCount: Int = 0
    
    // 灵敏度配置
    @Published var minHorizontalDistance: CGFloat = 0.20 // 最小横向位移比例 (屏幕宽度的 20%)
    @Published var maxVerticalDeviation: CGFloat = 0.16   // 允许的最大纵向偏移比例
    @Published var cooldownInterval: TimeInterval = 0.65   // 同方向连续翻页冷却 (秒)
    @Published var reverseCooldownInterval: TimeInterval = 3.00 // 反方向翻页保护期 (默认 3.0 秒，防止慢速收手误触)
    
    // 联动控制：是否实际驱动课件翻页
    @Published var isLinkToSmartClassEnabled: Bool = true
    
    // MARK: - 独立预览图层引用 (由后台配置完成并在主线程安全发布)
    @Published var frontPreviewLayer: AVCaptureVideoPreviewLayer? = nil
    @Published var backPreviewLayer: AVCaptureVideoPreviewLayer? = nil
    
    // MARK: - 讲师专属优先仲裁与姿态过滤状态
    public enum CameraPriorityRole: String {
        case frontLectern = "讲台模式 (前置主控，后置静音)"
        case backPatrol = "巡堂模式 (前置离台，后置接管)"
    }
    
    public enum BodyPoseCategory: String {
        case standing = "站立讲师"
        case seated = "坐姿学生"
        case unknown = "未定"
    }
    
    @Published var activeCameraRole: CameraPriorityRole = .frontLectern
    @Published var isFrontPersonDetected: Bool = false
    @Published var standingPersonCount: Int = 0
    @Published var seatedPersonCount: Int = 0
    @Published var ignoredSeatedGestureCount: Int = 0
    @Published var isPoseFilterEnabled: Bool = true
    @Published var isTeacherAnchorLocked: Bool = false
    @Published var teacherAnchorStatus: String = "等待首位站立讲师..."
    
    // MARK: - 回调通知
    var onPageFlipDetected: ((FlipDirection) -> Void)?
    
    // MARK: - 会话与私有属性
    private var currentSession: AVCaptureSession?
    private let sessionQueue = DispatchQueue(label: "edu.ncu.smartglass.gesture.session")
    private let visionQueue = DispatchQueue(label: "edu.ncu.smartglass.gesture.vision")
    private let handPoseRequest = VNDetectHumanHandPoseRequest()
    private let bodyPoseRequest = VNDetectHumanBodyPoseRequest()
    
    // 双摄连接引用与优先级仲裁
    private weak var frontDataConnection: AVCaptureConnection?
    private weak var backDataConnection: AVCaptureConnection?
    private var lastFrontPersonTime: TimeInterval = 0
    private var teacherAnchorId: UUID? = nil
    
    // 轨迹缓冲与状态机
    private var pointBuffer: [TimedTrajectoryPoint] = []
    private let windowDuration: TimeInterval = 0.38
    private var lastTriggerTime: TimeInterval = 0
    private var lastTriggeredDirectionHistory: FlipDirection? = nil
    private var lastTriggerTimestampHistory: TimeInterval = 0
    private var reverseCooldownExpiryTime: TimeInterval = 0
    private var lastFrameProcessTime: TimeInterval = 0
    private let minFrameInterval: TimeInterval = 0.04 // 限频约 25 FPS
    
    private override init() {
        super.init()
        handPoseRequest.maximumHandCount = 3 // 支持多手掌检测以便甄别与过滤
    }
    
    // MARK: - 相机生命周期管理
    
    /// 检查权限并启动相机
    func start() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
            switch authStatus {
            case .authorized:
                DispatchQueue.main.async { self.isAuthorized = true }
                self.setupAndStartSession()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async { self.isAuthorized = granted }
                    if granted {
                        self.sessionQueue.async { self.setupAndStartSession() }
                    }
                }
            default:
                DispatchQueue.main.async {
                    self.isAuthorized = false
                    self.lastGestureTitle = "⚠️ 相机权限受限，请在系统设置中允许"
                }
            }
        }
    }
    
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if let session = self.currentSession, session.isRunning {
                session.stopRunning()
            }
            self.currentSession = nil
            DispatchQueue.main.async {
                self.isRunning = false
                self.isHandDetected = false
                self.currentHandPoint = nil
                self.recentTrajectory.removeAll()
                self.frontPreviewLayer = nil
                self.backPreviewLayer = nil
            }
        }
    }
    
    /// 切换单摄 / 前后双摄模式
    func toggleDualCameraMode() {
        guard isMultiCamSupported else {
            DispatchQueue.main.async {
                self.lastGestureTitle = "⚠️ 当前设备不支持前后多摄并发"
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            }
            return
        }
        
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let targetMode = !self.isDualCameraActive
            DispatchQueue.main.async {
                self.isDualCameraActive = targetMode
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            self.setupAndStartSession()
        }
    }
    
    /// 单摄模式下切换前置/后置
    func toggleCameraPosition() {
        guard !isDualCameraActive else { return }
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.cameraPosition = (self.cameraPosition == .front) ? .back : .front
            self.setupAndStartSession()
        }
    }
    
    // MARK: - 会话配置引擎
    private func setupAndStartSession() {
        // 1. 彻底停用旧会话
        if let oldSession = currentSession, oldSession.isRunning {
            oldSession.stopRunning()
        }
        currentSession = nil
        
        // 2. 根据用户设置选择配置单摄还是双摄
        if isDualCameraActive && isMultiCamSupported {
            let success = setupDualCamSession()
            if !success {
                // 如果双摄初始化失败，优雅回退到单摄，避免崩溃
                DispatchQueue.main.async {
                    self.isDualCameraActive = false
                    self.lastGestureTitle = "⚠️ 双摄并发配置失败，已安全降级至单摄"
                }
                setupSingleCamSession()
            }
        } else {
            setupSingleCamSession()
        }
    }
    
    /// 配置前后双摄并发会话 (AVCaptureMultiCamSession)
    @discardableResult
    private func setupDualCamSession() -> Bool {
        let multiCam = AVCaptureMultiCamSession()
        multiCam.beginConfiguration()
        
        // 1. 获取前置与后置摄像头硬件
        guard let frontDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let backDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let frontInput = try? AVCaptureDeviceInput(device: frontDevice),
              let backInput = try? AVCaptureDeviceInput(device: backDevice) else {
            multiCam.commitConfiguration()
            return false
        }
        
        // 2. 检查多摄格式兼容性 (优先保留设备默认已兼容的 format，仅在不兼容时切换)
        if !frontDevice.activeFormat.isMultiCamSupported {
            if let validFrontFormat = frontDevice.formats.first(where: { $0.isMultiCamSupported && $0.formatDescription.dimensions.height <= 1080 }) {
                try? frontDevice.lockForConfiguration()
                frontDevice.activeFormat = validFrontFormat
                frontDevice.unlockForConfiguration()
            }
        }
        if !backDevice.activeFormat.isMultiCamSupported {
            if let validBackFormat = backDevice.formats.first(where: { $0.isMultiCamSupported && $0.formatDescription.dimensions.height <= 1080 }) {
                try? backDevice.lockForConfiguration()
                backDevice.activeFormat = validBackFormat
                backDevice.unlockForConfiguration()
            }
        }
        
        // 3. 添加两个摄像头输入
        guard multiCam.canAddInput(frontInput), multiCam.canAddInput(backInput) else {
            multiCam.commitConfiguration()
            return false
        }
        multiCam.addInputWithNoConnections(frontInput)
        multiCam.addInputWithNoConnections(backInput)
        
        // 4. 获取视频端口
        guard let frontPort = frontInput.ports(for: .video, sourceDeviceType: frontDevice.deviceType, sourceDevicePosition: .front).first,
              let backPort = backInput.ports(for: .video, sourceDeviceType: backDevice.deviceType, sourceDevicePosition: .back).first else {
            multiCam.commitConfiguration()
            return false
        }
        
        // 5. 前置手势识别输出数据管道
        let frontOutput = AVCaptureVideoDataOutput()
        frontOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        frontOutput.alwaysDiscardsLateVideoFrames = true
        frontOutput.setSampleBufferDelegate(self, queue: visionQueue)
        
        guard multiCam.canAddOutput(frontOutput) else {
            multiCam.commitConfiguration()
            return false
        }
        multiCam.addOutputWithNoConnections(frontOutput)
        
        let frontDataConn = AVCaptureConnection(inputPorts: [frontPort], output: frontOutput)
        if frontDataConn.isVideoOrientationSupported { frontDataConn.videoOrientation = .portrait }
        if frontDataConn.isVideoMirroringSupported {
            frontDataConn.automaticallyAdjustsVideoMirroring = false
            frontDataConn.isVideoMirrored = true
        }
        guard multiCam.canAddConnection(frontDataConn) else {
            multiCam.commitConfiguration()
            return false
        }
        multiCam.addConnection(frontDataConn)
        
        // 6. 构造前置与后置独立预览图层 (必须通过 sessionWithNoConnection 关联)
        let frontLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: multiCam)
        frontLayer.videoGravity = .resizeAspectFill
        let frontPreviewConn = AVCaptureConnection(inputPort: frontPort, videoPreviewLayer: frontLayer)
        if frontPreviewConn.isVideoOrientationSupported { frontPreviewConn.videoOrientation = .portrait }
        if frontPreviewConn.isVideoMirroringSupported {
            frontPreviewConn.automaticallyAdjustsVideoMirroring = false
            frontPreviewConn.isVideoMirrored = true
        }
        
        guard multiCam.canAddConnection(frontPreviewConn) else {
            multiCam.commitConfiguration()
            return false
        }
        multiCam.addConnection(frontPreviewConn)
        
        let backLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: multiCam)
        backLayer.videoGravity = .resizeAspectFill
        let backPreviewConn = AVCaptureConnection(inputPort: backPort, videoPreviewLayer: backLayer)
        if backPreviewConn.isVideoOrientationSupported { backPreviewConn.videoOrientation = .portrait }
        
        guard multiCam.canAddConnection(backPreviewConn) else {
            multiCam.commitConfiguration()
            return false
        }
        multiCam.addConnection(backPreviewConn)
        
        // 7. 后置手势识别输出数据管道 (用于讲师走下讲台时的巡堂模式接管)
        let backOutput = AVCaptureVideoDataOutput()
        backOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        backOutput.alwaysDiscardsLateVideoFrames = true
        backOutput.setSampleBufferDelegate(self, queue: visionQueue)
        
        var backDataConn: AVCaptureConnection? = nil
        if multiCam.canAddOutput(backOutput) {
            multiCam.addOutputWithNoConnections(backOutput)
            let conn = AVCaptureConnection(inputPorts: [backPort], output: backOutput)
            if conn.isVideoOrientationSupported { conn.videoOrientation = .portrait }
            if multiCam.canAddConnection(conn) {
                multiCam.addConnection(conn)
                backDataConn = conn
            }
        }
        
        self.frontDataConnection = frontDataConn
        self.backDataConnection = backDataConn
        
        multiCam.commitConfiguration()
        multiCam.startRunning()
        
        self.currentSession = multiCam
        
        DispatchQueue.main.async {
            self.frontPreviewLayer = frontLayer
            self.backPreviewLayer = backLayer
            self.isRunning = multiCam.isRunning
            self.lastGestureTitle = "🎥 前后双摄已就绪 (前置识别手势中)"
        }
        
        return true
    }
    
    /// 配置单摄像头会话 (AVCaptureSession)
    private func setupSingleCamSession() {
        let singleSession = AVCaptureSession()
        singleSession.beginConfiguration()
        singleSession.sessionPreset = .medium
        
        let position = cameraPosition
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              singleSession.canAddInput(input) else {
            singleSession.commitConfiguration()
            return
        }
        singleSession.addInput(input)
        
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: visionQueue)
        
        if singleSession.canAddOutput(videoOutput) {
            singleSession.addOutput(videoOutput)
        }
        
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = (position == .front)
            }
            if position == .front {
                self.frontDataConnection = connection
                self.backDataConnection = nil
            } else {
                self.frontDataConnection = nil
                self.backDataConnection = connection
            }
        }
        
        // 创建用于单摄的预览图层
        let previewLayer = AVCaptureVideoPreviewLayer(session: singleSession)
        previewLayer.videoGravity = .resizeAspectFill
        
        singleSession.commitConfiguration()
        singleSession.startRunning()
        
        self.currentSession = singleSession
        
        DispatchQueue.main.async {
            if position == .front {
                self.frontPreviewLayer = previewLayer
                self.backPreviewLayer = nil
            } else {
                self.backPreviewLayer = previewLayer
                self.frontPreviewLayer = nil
            }
            self.isRunning = singleSession.isRunning
            self.lastGestureTitle = "待命中 (请在镜头前挥手)"
        }
    }
    
    // MARK: - 模拟测试接口
    func simulateGesture(direction: FlipDirection) {
        let now = CACurrentMediaTime()
        lastTriggerTime = now
        lastTriggerTimestampHistory = now
        lastTriggeredDirectionHistory = direction
        reverseCooldownExpiryTime = now + reverseCooldownInterval
        pointBuffer.removeAll()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lastGestureTitle = direction.title + " (手动模拟)"
            self.lastGestureTimestamp = Date()
            self.lastTriggeredDirection = direction
            
            if direction == .nextPage {
                self.nextPageCount += 1
            } else {
                self.prevPageCount += 1
            }
            
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            self.onPageFlipDetected?(direction)
            
            if self.isLinkToSmartClassEnabled {
                if direction == .nextPage {
                    LectureSessionManager.shared.gotoNextSlide()
                } else {
                    LectureSessionManager.shared.gotoPrevSlide()
                }
            }
        }
    }
    
    func resetStats() {
        nextPageCount = 0
        prevPageCount = 0
        lastGestureTitle = isDualCameraActive ? "🎥 前后双摄已就绪 (前置识别手势中)" : "待命中 (请在镜头前挥手)"
        lastTriggeredDirection = nil
        lastTriggeredDirectionHistory = nil
        lastTriggerTimestampHistory = 0
        reverseCooldownExpiryTime = 0
    }
}

// MARK: - AVCaptureVideoDataOutput 帧分析与手势判定
extension AirWaveGestureService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let currentTime = CACurrentMediaTime()
        
        // 1. 限频控制 (~25 fps)
        guard currentTime - lastFrameProcessTime >= minFrameInterval else { return }
        lastFrameProcessTime = currentTime
        
        // 2. 区分当前帧来源于前置还是后置镜头
        let isFromFront: Bool
        if let frontConn = frontDataConnection {
            isFromFront = (connection == frontConn)
        } else {
            isFromFront = (cameraPosition == .front)
        }
        
        // 3. 讲台优先级仲裁：如果后置帧到达，且前置最近 1.2 秒内检测到有人，直接短路静音后置！
        if !isFromFront {
            let isLecternActive = (currentTime - lastFrontPersonTime < 1.2)
            if isLecternActive {
                // 讲师在讲台（前置有人），后置完全静音，学生无论怎么动都不处理，节省算力与杜绝误触
                DispatchQueue.main.async {
                    if self.activeCameraRole != .frontLectern {
                        self.activeCameraRole = .frontLectern
                    }
                }
                return
            } else {
                // 讲师走下讲台（前置无人），后置接管巡堂模式
                DispatchQueue.main.async {
                    if self.activeCameraRole != .backPatrol {
                        self.activeCameraRole = .backPatrol
                    }
                }
            }
        } else {
            // 前置帧：保持讲台模式
            DispatchQueue.main.async {
                if self.activeCameraRole != .frontLectern {
                    self.activeCameraRole = .frontLectern
                }
            }
        }
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            // 同时执行人体骨骼与手掌姿态检测
            try handler.perform([handPoseRequest, bodyPoseRequest])
            
            // 4. 分析人体骨骼与姿态 (坐姿 vs 站姿)
            var standingBodies: [VNHumanBodyPoseObservation] = []
            var seatedBodies: [VNHumanBodyPoseObservation] = []
            
            if let bodyResults = bodyPoseRequest.results {
                for body in bodyResults {
                    let poseCategory = classifyBodyPose(observation: body)
                    if poseCategory == .standing {
                        standingBodies.append(body)
                    } else if poseCategory == .seated {
                        seatedBodies.append(body)
                    }
                }
            }
            
            // 前置摄像头心跳维护
            if isFromFront {
                let hasFrontPerson = (standingBodies.count > 0 || seatedBodies.count > 0 || (handPoseRequest.results?.count ?? 0) > 0)
                if hasFrontPerson {
                    lastFrontPersonTime = currentTime
                    DispatchQueue.main.async {
                        self.isFrontPersonDetected = true
                    }
                } else {
                    DispatchQueue.main.async {
                        self.isFrontPersonDetected = false
                    }
                }
            }
            
            // 实时更新当前画面的姿态统计遥测
            DispatchQueue.main.async {
                self.standingPersonCount = standingBodies.count
                self.seatedPersonCount = seatedBodies.count
            }
            
            // 5. 讲师初始锚定 (Initial Standing Teacher Anchor)
            // 在后置巡堂模式下，优先绑定首位出现的稳定站立者
            if !isFromFront && standingBodies.count > 0 && !isTeacherAnchorLocked {
                DispatchQueue.main.async {
                    self.isTeacherAnchorLocked = true
                    self.teacherAnchorStatus = "已锚定巡堂讲师 (站立姿态)"
                }
            }
            
            // 6. 手部检测结果提取与过滤
            guard let handObservations = handPoseRequest.results, !handObservations.isEmpty else {
                DispatchQueue.main.async {
                    if self.isHandDetected {
                        self.isHandDetected = false
                        self.currentHandPoint = nil
                    }
                }
                return
            }
            
            // 遍历检测到的手掌，找到第一个属于合法站立人员的手（如果在后置巡堂模式启用了姿态过滤）
            var validHandObservation: VNHumanHandPoseObservation? = nil
            var filteredDueToSeated: Bool = false
            
            for handObs in handObservations {
                guard let wristPt = try? handObs.recognizedPoints(.all)[.wrist], wristPt.confidence > 0.45 else {
                    continue
                }
                
                if !isFromFront && isPoseFilterEnabled {
                    // 后置巡堂模式下：如果存在坐姿人员，判断此手腕是否归属于坐姿人员
                    let isSeatedHand = isWristBelongsToBodies(wristPoint: wristPt.location, bodies: seatedBodies)
                    let isStandingHand = standingBodies.isEmpty || isWristBelongsToBodies(wristPoint: wristPt.location, bodies: standingBodies)
                    
                    if isSeatedHand && !isStandingHand {
                        filteredDueToSeated = true
                        continue // 丢弃坐姿手势
                    }
                    
                    if isStandingHand {
                        validHandObservation = handObs
                        break
                    }
                } else {
                    // 前置讲台模式或未启用姿态过滤：直接放行
                    validHandObservation = handObs
                    break
                }
            }
            
            if filteredDueToSeated && validHandObservation == nil {
                // 本帧中检测到了手掌，但全部属于坐姿学生，记为成功拦截 (不覆盖真正的翻页动作结果)
                DispatchQueue.main.async {
                    self.ignoredSeatedGestureCount += 1
                    self.isHandDetected = false
                    self.currentHandPoint = nil
                }
                return
            }
            
            guard let targetHand = validHandObservation else {
                DispatchQueue.main.async {
                    self.isHandDetected = false
                    self.currentHandPoint = nil
                }
                return
            }
            
            // 7. 提取有效手部的手腕或指关节
            let recognizedPoints = try targetHand.recognizedPoints(.all)
            let anchorPoint: VNRecognizedPoint? = recognizedPoints[.wrist] ?? recognizedPoints[.indexMCP]
            
            guard let anchor = anchorPoint, anchor.confidence > 0.55 else {
                DispatchQueue.main.async {
                    self.isHandDetected = false
                    self.currentHandPoint = nil
                }
                return
            }
            
            let normalizedPoint = CGPoint(x: anchor.location.x, y: 1.0 - anchor.location.y)
            let timedPoint = TimedTrajectoryPoint(point: normalizedPoint, timestamp: currentTime)
            
            // 8. 维护轨迹历史
            pointBuffer.append(timedPoint)
            pointBuffer.removeAll { currentTime - $0.timestamp > windowDuration }
            
            let snapshotTrajectory = pointBuffer
            DispatchQueue.main.async {
                self.isHandDetected = true
                self.handConfidence = anchor.confidence
                self.currentHandPoint = normalizedPoint
                self.recentTrajectory = snapshotTrajectory
            }
            
            // 9. 挥手时序判定
            detectWaveGesture(currentTime: currentTime)
            
        } catch {
            // 忽略非致命解析错误
        }
    }
    
    // MARK: - 辅助姿态分类器与坐姿判定
    private func classifyBodyPose(observation: VNHumanBodyPoseObservation) -> BodyPoseCategory {
        do {
            let points = try observation.recognizedPoints(.all)
            let neck = points[.neck]
            let leftHip = points[.leftHip]
            let rightHip = points[.rightHip]
            let leftKnee = points[.leftKnee]
            let rightKnee = points[.rightKnee]
            
            let hip = (leftHip?.confidence ?? 0 > 0.3) ? leftHip : rightHip
            let knee = (leftKnee?.confidence ?? 0 > 0.3) ? leftKnee : rightKnee
            
            if let h = hip, let k = knee, h.confidence > 0.35, k.confidence > 0.35 {
                let deltaY = abs(h.location.y - k.location.y)
                let deltaX = abs(h.location.x - k.location.x)
                if deltaY > 0.12 && (deltaY / (deltaX + 0.001)) > 1.3 {
                    return .standing
                } else {
                    return .seated
                }
            }
            
            if let n = neck, n.confidence > 0.4 {
                if (knee == nil || knee!.confidence < 0.2) && (hip == nil || hip!.confidence < 0.2) {
                    return .seated
                }
            }
            return .unknown
        } catch {
            return .unknown
        }
    }
    
    private func isWristBelongsToBodies(wristPoint: CGPoint, bodies: [VNHumanBodyPoseObservation]) -> Bool {
        for body in bodies {
            if let points = try? body.recognizedPoints(.all) {
                let leftWrist = points[.leftWrist]
                let rightWrist = points[.rightWrist]
                let leftElbow = points[.leftElbow]
                let rightElbow = points[.rightElbow]
                let neck = points[.neck]
                
                for pt in [leftWrist, rightWrist, leftElbow, rightElbow, neck].compactMap({ $0 }) {
                    guard pt.confidence > 0.25 else { continue }
                    let dx = pt.location.x - wristPoint.x
                    let dy = pt.location.y - wristPoint.y
                    let dist = sqrt(dx * dx + dy * dy)
                    if dist < 0.22 {
                        return true
                    }
                }
            }
        }
        return false
    }
    
    /// 手动重置讲师锚定状态
    func resetTeacherAnchor() {
        DispatchQueue.main.async {
            self.isTeacherAnchorLocked = false
            self.teacherAnchorStatus = "已重置，等待首位站立讲师..."
            self.ignoredSeatedGestureCount = 0
        }
    }
    
    private func detectWaveGesture(currentTime: TimeInterval) {
        guard let startPoint = pointBuffer.first,
              let endPoint = pointBuffer.last,
              pointBuffer.count >= 4 else { return }
        
        let deltaX = endPoint.point.x - startPoint.point.x
        let deltaY = abs(endPoint.point.y - startPoint.point.y)
        let deltaTime = endPoint.timestamp - startPoint.timestamp
        
        if abs(deltaX) >= minHorizontalDistance &&
           deltaY <= maxVerticalDeviation &&
           deltaY < abs(deltaX) * 0.70 &&
           deltaTime >= 0.10 && deltaTime <= windowDuration {
            
            let detectedDirection: FlipDirection = (deltaX < 0) ? .nextPage : .previousPage
            
            // 核心关键：非对称冷却期校验（区分同向连续翻页 vs 反方向收手归位）
            let isReverseDirection = (lastTriggeredDirectionHistory != nil && detectedDirection != lastTriggeredDirectionHistory)
            
            let isBlocked: Bool
            let remaining: Double
            let notice: String
            
            if isReverseDirection {
                // 反向翻页：必须超过截止时间 reverseCooldownExpiryTime (默认 3.0 秒)
                if currentTime < reverseCooldownExpiryTime {
                    isBlocked = true
                    remaining = max(0.2, reverseCooldownExpiryTime - currentTime)
                    notice = String(format: "⏳ 反向防误触保护中 (剩余 %.1fs)", remaining)
                    // 关键自适应顺延：检测到反向动作说明手臂仍在收回过程中，自动将保护期动态顺延至少 1.8 秒
                    reverseCooldownExpiryTime = max(reverseCooldownExpiryTime, currentTime + 1.8)
                } else {
                    isBlocked = false
                    remaining = 0
                    notice = ""
                }
            } else {
                // 同向连续翻页：使用短冷却 cooldownInterval (0.65s)
                let timeSinceLastTrigger = currentTime - lastTriggerTimestampHistory
                if timeSinceLastTrigger < cooldownInterval {
                    isBlocked = true
                    remaining = max(0.1, cooldownInterval - timeSinceLastTrigger)
                    notice = String(format: "⏳ 翻页过快冷却中 (剩余 %.1fs)", remaining)
                } else {
                    isBlocked = false
                    remaining = 0
                    notice = ""
                }
            }
            
            if isBlocked {
                pointBuffer.removeAll()
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.cooldownBlockedNotice = notice
                    self.cooldownBlockedTimestamp = Date()
                    // 绝不覆盖真正的翻页动作 lastGestureTitle，两者彻底独立
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                }
                return
            }
            
            // 通过非对称冷却校验，确凿触发翻页动作
            lastTriggerTime = currentTime
            lastTriggerTimestampHistory = currentTime
            lastTriggeredDirectionHistory = detectedDirection
            // 反向翻页保护期重置为：当前时间 + reverseCooldownInterval (默认 3.0 秒)
            reverseCooldownExpiryTime = currentTime + reverseCooldownInterval
            pointBuffer.removeAll()
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                self.lastGestureTitle = detectedDirection.title
                self.lastGestureTimestamp = Date()
                self.lastTriggeredDirection = detectedDirection
                
                if detectedDirection == .nextPage {
                    self.nextPageCount += 1
                } else {
                    self.prevPageCount += 1
                }
                
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                self.onPageFlipDetected?(detectedDirection)
                
                if self.isLinkToSmartClassEnabled {
                    if detectedDirection == .nextPage {
                        LectureSessionManager.shared.gotoNextSlide()
                    } else {
                        LectureSessionManager.shared.gotoPrevSlide()
                    }
                }
            }
        }
    }
}
