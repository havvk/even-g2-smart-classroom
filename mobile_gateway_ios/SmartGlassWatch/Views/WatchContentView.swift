import SwiftUI

struct WatchContentView: View {
    @StateObject private var watchService = WatchBLEGatewayService()
    @State private var crownValue: Double = 0.0
    @State private var lastCrownValue: Double = 0.0
    
    var body: some View {
        VStack(spacing: 8) {
            // 页码与在线状态 Header
            HStack {
                Text("P\(String(format: "%02d", watchService.currentPage))/\(String(format: "%02d", watchService.totalPages))")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)
                Spacer()
                Circle()
                    .fill(watchService.isPhoneReachable ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
            }
            .padding(.horizontal, 4)
            
            // 捏手指手势提示
            Text("👌 捏手指/点击翻页")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            
            // 控屏主按键区
            HStack(spacing: 8) {
                Button(action: {
                    watchService.sendPageControl(action: "PREV", source: "WATCH_TAP")
                }) {
                    VStack {
                        Image(systemName: "chevron.left")
                            .font(.title3)
                        Text("上一页")
                            .font(.system(size: 10))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.gray.opacity(0.3))
                    .cornerRadius(10)
                }
                .buttonStyle(PlainButtonStyle())
                
                Button(action: {
                    watchService.sendPageControl(action: "NEXT", source: "WATCH_TAP")
                }) {
                    VStack {
                        Image(systemName: "chevron.right")
                            .font(.title3)
                        Text("下一页")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .frame(height: 70)
        }
        .padding(4)
        .focusable(true)
        .digitalCrownRotation($crownValue)
        .onChange(of: crownValue) { newValue in
            // 数字表冠转动事件解调
            if newValue > lastCrownValue + 1.0 {
                watchService.sendPageControl(action: "NEXT", source: "WATCH_CROWN")
                lastCrownValue = newValue
            } else if newValue < lastCrownValue - 1.0 {
                watchService.sendPageControl(action: "PREV", source: "WATCH_CROWN")
                lastCrownValue = newValue
            }
        }
    }
}
