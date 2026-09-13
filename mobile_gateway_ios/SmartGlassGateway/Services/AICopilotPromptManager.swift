import Foundation
import Combine

/// Even G2 AI 提词卡片管理器 (Calm Technology 平静技术单卡静默推送)
///
/// 核心职责:
/// 1. 微标签规范门禁 (Micro-Tag Guard): 强制过滤并约束单行标题在 8~12 个汉字，避免 MicroLED 视口出现截断省略号；
/// 2. 20 槽位镜像抽屉 (20-Slot Mirror Drawer): 本地维护容量为 20 的先进先出 (FIFO) 队列，与镜腿硬件环形存储保持绝对同步；
/// 3. 展开事件联动: 监听来自眼镜 0x0B-01 的物理展开通知，实时同步佩戴者的阅读状态。
class AICopilotPromptManager: ObservableObject {
    
    // MARK: - Models
    
    struct CopilotCardItem: Identifiable, Equatable {
        let id: UUID
        let msgId: Int
        let title: String
        let detail: String
        let timestamp: Date
        var isExpanded: Bool
        
        init(id: UUID = UUID(), msgId: Int, title: String, detail: String = "", timestamp: Date = Date(), isExpanded: Bool = false) {
            self.id = id
            self.msgId = msgId
            self.title = title
            self.detail = detail
            self.timestamp = timestamp
            self.isExpanded = isExpanded
        }
    }
    
    // MARK: - Published State
    
    /// 当前最新活跃在前台的胶囊卡片
    @Published var activeCard: CopilotCardItem?
    
    /// 与眼镜硬件镜像同步的历史卡片抽屉 (上限严格为 20 条，FIFO 队列)
    @Published var drawerCards: [CopilotCardItem] = []
    
    /// 最大硬件槽位上限
    static let maxDrawerCapacity = 20
    
    // MARK: - Singleton
    
    static let shared = AICopilotPromptManager()
    
    init() {}
    
    // MARK: - Micro-Tag Guard & Card Push
    
    /// 格式化并净化大模型返回的胶囊标题，确保严格适配 G2 单行胶囊 (8~12 汉字)
    /// - Parameter rawTitle: 原始标题文本
    /// - Returns: 净化后无换行、不超过 14 字符的极简微标签
    static func sanitizeTitle(_ rawTitle: String) -> String {
        var clean = rawTitle
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 如果包含引号或 Markdown 符号，进行清除
        clean = clean.replacingOccurrences(of: "**", with: "")
        clean = clean.replacingOccurrences(of: "“", with: "")
        clean = clean.replacingOccurrences(of: "”", with: "")
        clean = clean.replacingOccurrences(of: "\"", with: "")
        
        // 字符数门禁：超过 13 个字符严格安全截断，保证在眼镜端不出现截断省略号
        if clean.count > 13 {
            let index = clean.index(clean.startIndex, offsetBy: 13)
            clean = String(clean[..<index])
        }
        
        return clean
    }
    
    /// 压入一张新卡片 (进入 20 槽位队列并设为当前活跃卡片)
    /// - Parameters:
    ///   - msgId: 对应的消息 ID
    ///   - rawTitle: 胶囊标题 (将自动通过门禁净化)
    ///   - detail: 展开详情多行正文
    /// - Returns: 构造完成的卡片对象
    @discardableResult
    func pushCard(msgId: Int, rawTitle: String, detail: String = "") -> CopilotCardItem {
        let cleanTitle = Self.sanitizeTitle(rawTitle)
        let item = CopilotCardItem(msgId: msgId, title: cleanTitle, detail: detail)
        
        DispatchQueue.main.async {
            self.activeCard = item
            
            // 压入历史抽屉
            self.drawerCards.append(item)
            
            // 严格执行 20 槽位先进先出淘汰律 (与眼镜硬件对齐)
            while self.drawerCards.count > Self.maxDrawerCapacity {
                self.drawerCards.removeFirst()
            }
        }
        
        return item
    }
    
    // MARK: - Notification Handling (0x0B-01)
    
    /// 处理眼镜端上报的 0x0B-01 事件通知
    /// - Parameter notif: 解析后的通知包
    func handleConversateNotification(_ notif: G2ProtocolEncoder.ConversateNotification) {
        guard notif.isCardExpanded else { return }
        
        DispatchQueue.main.async {
            // 优先匹配 msgId，若未匹配则默认标记当前活跃卡片
            if let index = self.drawerCards.firstIndex(where: { $0.msgId == notif.msgId }) {
                self.drawerCards[index].isExpanded = true
            } else if self.activeCard != nil {
                self.activeCard?.isExpanded = true
                if let lastIndex = self.drawerCards.indices.last {
                    self.drawerCards[lastIndex].isExpanded = true
                }
            }
            print("🌟 [CopilotManager] 感知到佩戴者物理展开卡片! (msgId=\(notif.msgId))")
        }
    }
    
    // MARK: - Reset
    
    /// 重置清空所有状态
    func reset() {
        DispatchQueue.main.async {
            self.activeCard = nil
            self.drawerCards.removeAll()
        }
    }
}
