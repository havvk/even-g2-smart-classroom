import SwiftUI

/// 智慧课堂与隔空手势统一参数设置面板
struct SmartClassSettingsSheet: View {
    @ObservedObject var gestureService = AirWaveGestureService.shared
    @ObservedObject var lectureManager = LectureSessionManager.shared
    @ObservedObject var authService = AuthService.shared
    @ObservedObject var ble = BLEManager.shared
    @Environment(\.presentationMode) var presentationMode
    
    @State private var serverUrlInput: String = ""
    @State private var sessionIdInput: String = ""
    @State private var showResetAlert: Bool = false
    
    var body: some View {
        NavigationView {
            Form {
                // MARK: - 1. 隔空手势算法与防误触调优
                Section(header: Label("隔空手势算法调优", systemImage: "hand.wave.fill").foregroundColor(.teal)) {
                    // 横向触发位移比例
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("横向触发位移比例")
                                .font(.subheadline)
                            Spacer()
                            Text(String(format: "%.0f%% 屏幕宽", gestureService.minHorizontalDistance * 100))
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .foregroundColor(.teal)
                        }
                        Slider(value: $gestureService.minHorizontalDistance, in: 0.12...0.35, step: 0.02)
                            .accentColor(.teal)
                        Text("手掌横向位移超过该比例即识别为挥手动作")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                    
                    // 同向连续翻页冷却
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("同向连续翻页冷却")
                                .font(.subheadline)
                            Spacer()
                            Text(String(format: "%.2f 秒", gestureService.cooldownInterval))
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .foregroundColor(.teal)
                        }
                        Slider(value: $gestureService.cooldownInterval, in: 0.4...1.5, step: 0.05)
                            .accentColor(.teal)
                        Text("同方向两次挥手之间的最小时间间隔，防止连续误翻")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                    
                    // 反向回程防误触保护冷却 (核心保障)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("反向回程防误触冷却")
                                .font(.subheadline)
                            Spacer()
                            Text(String(format: "%.2f 秒", gestureService.reverseCooldownInterval))
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .foregroundColor(.orange)
                        }
                        Slider(value: $gestureService.reverseCooldownInterval, in: 1.5...6.0, step: 0.25)
                            .accentColor(.orange)
                        Text("挥手后手臂收回（反向移动）期间的强制阻尼抑制期，彻底杜绝回程误翻")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                
                // MARK: - 2. 讲台与教室环境抗干扰
                Section(header: Label("讲台环境抗干扰", systemImage: "figure.walk").foregroundColor(.indigo)) {
                    Toggle(isOn: $gestureService.isPoseFilterEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("坐姿学生手势智能过滤")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text("仅响应站立讲师的挥手指令，屏蔽台下所有坐姿学生动作")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if gestureService.isMultiCamSupported {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("前后双摄并发模式")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Text(gestureService.isDualCameraActive ? "已开启 (前摄识别手势，后摄监测环境)" : "已关闭 (单镜头轻量运行)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { gestureService.isDualCameraActive },
                                set: { _ in gestureService.toggleDualCameraMode() }
                            ))
                            .labelsHidden()
                        }
                    }
                    
                    Button(action: {
                        gestureService.resetTeacherAnchor()
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }) {
                        HStack {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                            Text("重置讲师目标追踪锚定 (PersonID)")
                        }
                        .font(.subheadline)
                        .foregroundColor(.teal)
                    }
                }
                
                // MARK: - 3. 智能眼镜屏显视口配置
                Section(header: Label("智能眼镜屏显视口", systemImage: "eyeglasses").foregroundColor(.purple)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("每屏行数")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text("控制 Even G2 镜片单屏可视区行数")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding<Int>(
                            get: { ble.linesPerPage },
                            set: { (newVal: Int) in
                                ble.linesPerPage = min(9, max(1, newVal))
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                lectureManager.pushCurrentSlideToGlasses(force: true)
                            }
                        )) {
                            Text("5行").tag(5)
                            Text("8行").tag(8)
                            Text("9行").tag(9)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 150)
                    }
                }
                
                // MARK: - 4. 智慧课堂联动与大屏控制
                Section(header: Label("智慧课堂多端联动", systemImage: "tv.and.mediabox").foregroundColor(.indigo)) {
                    Toggle(isOn: $gestureService.isLinkToSmartClassEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("手势驱动大屏与提词器翻页")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text("挥手动作直接下发至 WebSocket 大屏并驱动眼镜同步切页")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Button(action: {
                        gestureService.resetStats()
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }) {
                        HStack {
                            Image(systemName: "arrow.counterclockwise")
                            Text("重置翻页计数统计")
                        }
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    }
                }
                
                // MARK: - 4. 课时连接与统一身份认证配置
                Section(header: Label("服务与课时连接", systemImage: "network").foregroundColor(.blue)) {
                    HStack {
                        Text("服务地址")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(width: 70, alignment: .leading)
                        TextField("https://syb.ncu.edu.cn", text: $serverUrlInput)
                            .font(.system(.subheadline, design: .monospaced))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    
                    HStack {
                        Text("课时 ID")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(width: 70, alignment: .leading)
                        TextField("session_id", text: $sessionIdInput)
                            .font(.system(.subheadline, design: .monospaced))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    
                    Button(action: {
                        lectureManager.loadLectureSession(baseURL: serverUrlInput, sessionId: sessionIdInput)
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        HStack {
                            Spacer()
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("保存并重新加载课时")
                                .fontWeight(.bold)
                            Spacer()
                        }
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(.vertical, 8)
                        .background(Color.purple)
                        .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .navigationTitle("授课偏好与设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .font(.subheadline)
                    .fontWeight(.bold)
                }
            }
            .onAppear {
                serverUrlInput = lectureManager.baseURL
                sessionIdInput = lectureManager.sessionId
            }
        }
    }
}
