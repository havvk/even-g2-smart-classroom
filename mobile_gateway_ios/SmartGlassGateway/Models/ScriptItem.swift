import Foundation

/// 提词器滚动模式
enum TeleprompterScrollMode: String, Codable, CaseIterable, Identifiable {
    case ai = "AI"
    case auto = "Auto"
    case manual = "Manual"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .ai: return "AI 语音跟随"
        case .auto: return "Auto 匀速"
        case .manual: return "Manual 手动"
        }
    }
    
    var iconName: String {
        switch self {
        case .ai: return "sparkles"
        case .auto: return "timer"
        case .manual: return "hand.tap"
        }
    }
}

/// 讲稿实体数据模型
struct ScriptItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var content: String
    var updatedAt: Date
    var scrollMode: TeleprompterScrollMode
    var targetWidthChars: Int
    
    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        updatedAt: Date = Date(),
        scrollMode: TeleprompterScrollMode = .ai,
        targetWidthChars: Int = 28
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.updatedAt = updatedAt
        self.scrollMode = scrollMode
        self.targetWidthChars = targetWidthChars
    }
    
    var formattedDateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm yyyy/MM/dd"
        return formatter.string(from: updatedAt)
    }
    
    var totalLines: Int {
        return content.filter({ $0 == "\n" }).count + 1
    }
    
    var characterCount: Int {
        return content.count
    }
}
