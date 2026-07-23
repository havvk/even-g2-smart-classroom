import Foundation

// MARK: - Server Teleprompter Sync Payload
struct TeleprompterSyncPayload: Codable {
    let type: String
    let sessionId: String
    let currentPage: Int
    let totalPages: Int
    let slideTitle: String
    let bulletPoints: [String]
    let scriptText: String
    let endKeywords: [String]?
    let classroomStatus: ClassroomStatus?
    
    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case currentPage = "current_page"
        case totalPages = "total_pages"
        case slideTitle = "slide_title"
        case bulletPoints = "bullet_points"
        case scriptText = "script_text"
        case endKeywords = "end_keywords"
        case classroomStatus = "classroom_status"
    }
}

struct ClassroomStatus: Codable {
    let phase: String
    let checkinCount: Int
    let totalCount: Int
    
    enum CodingKeys: String, CodingKey {
        case phase
        case checkinCount = "checkin_count"
        case totalCount = "total_count"
    }
}

// MARK: - Client Page Control Command
struct PageControlCommand: Codable {
    let type: String = "PAGE_CONTROL"
    let sessionId: String
    let action: String // "NEXT" | "PREV" | "JUMP"
    let triggerSource: String // "RING_CLICK" | "TOUCHPAD_SWIPE" | "VOICE_KEYWORD"
    let targetPage: Int?
    let timestamp: Int64
    
    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case action
        case triggerSource = "trigger_source"
        case targetPage = "target_page"
        case timestamp
    }
}

// MARK: - HUD Display Chunk
struct HUDDisplayChunk: Identifiable {
    let id = UUID()
    let headerText: String // e.g. "[P06/24] ⏱️15:30"
    let highlightedLine: String // Current spoken/focused line
    let nextLinePreview: String // Next line preview
    let footerStatus: String // Status bar
}
