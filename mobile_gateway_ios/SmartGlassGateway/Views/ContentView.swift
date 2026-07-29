import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @EnvironmentObject var bleManager: BLEManager
    
    @State private var testText: String = """
各位领导、各位老师，大家上午好！欢迎参加 2026 年人机协同 Smart Classroom 集体备课会。
首先我们来看执行摘要的第一部分，关于课程痛点与定位。为了响应专业+AI 的培养大势，采用了每周 2+2 理实一体课。
因此本课程重新确立了 HOTL (Human-On-The-Loop) 人在回路上的核心定位，引入人机环路控制理论。
接下来是执行摘要的第二部分，介绍教学策略与资源部署。策略上基于 A/S/P 标记框架实施渐进式脚手架拆除。
在资源建设上，建议学校拨出专项算力资金在本地私有部署 Python 和 LLM 模型，消除开销壁垒。
第二部分是教学方法与策略，讲解每周 2+2 理实一体设置；第三部分是考核改革，重点介绍限时测试。
第四部分是资源标准化建设。接下来我们进入第一部分：成果导向的逻辑出发，阐述课程目标定位。
在深入第一章细节前，我们先来看第一章的全局逻辑链图。这页概念图体现了基于 OBE 反向推导的全貌。
为此我们引入了人机协同新范式，明确人类主导问题域与审计，AI 托管求解域。推导出最下层 OBE 目标。
这一部分的组织逻辑是层层递进的，极大地降低了编程学习门槛，帮助学生快速获得掌控感与成就感。
"""

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // 标题
            VStack(spacing: 8) {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 50))
                    .foregroundColor(.purple)
                Text("Even G2 官方协议推屏")
                    .font(.title)
                    .fontWeight(.bold)
                Text("100% 严格对齐 teleprompter.py 协议")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            // 状态指示
            HStack {
                Circle()
                    .fill(bleManager.isNotifyReady ? Color.green : Color.orange)
                    .frame(width: 12, height: 12)
                Text(bleManager.isNotifyReady ? "🟢 蓝牙与 Notify 已完全就绪: \(bleManager.connectedPeripheralName ?? "Even G2_L")" : (bleManager.isConnected ? "🟡 正在握手 Notify 订阅..." : "🔴 蓝牙未连接"))
                    .font(.headline)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(20)
            
            // 唯一的核心主按钮
            if !bleManager.isConnected {
                Button(action: {
                    bleManager.startScanning()
                }) {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text("1. 扫描并连接 G2 眼镜")
                    }
                    .font(.title3)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
                .padding(.horizontal, 24)
            } else {
                VStack(spacing: 14) {
                    Button(action: {
                        bleManager.sendTeleprompterText(testText, targetWidthChars: 14)
                    }) {
                        HStack {
                            Image(systemName: "paperplane.fill")
                            Text(bleManager.isNotifyReady ? "2. 1:1 原装抓包一键推屏" : "等待 Notify 订阅就绪...")
                        }
                        .font(.title3)
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(bleManager.isNotifyReady ? Color.purple : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(14)
                    }
                    .disabled(!bleManager.isNotifyReady)
                    
                    Button(action: {
                        bleManager.sendExitTeleprompterMode()
                    }) {
                        HStack {
                            Image(systemName: "xmark.circle")
                            Text("退出提词模式")
                        }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.gray.opacity(0.2))
                        .foregroundColor(.primary)
                        .cornerRadius(10)
                    }
                }
                .padding(.horizontal, 24)
            }
            
            Spacer()
            
            // 日志展示
            VStack(alignment: .leading, spacing: 6) {
                Text("状态日志:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ScrollView {
                    Text(bleManager.bleLogHistory.suffix(15).joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
                .padding(8)
                .background(Color.black.opacity(0.04))
                .cornerRadius(8)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }
}
