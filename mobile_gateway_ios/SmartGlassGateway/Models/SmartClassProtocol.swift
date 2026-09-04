import Foundation

// MARK: - 生产环境 Session Info
struct SmartClassSessionInfo: Codable {
    let sessionId: String?
    let courseName: String?
    let courseId: Int?
    let sessionName: String?
    let phase: String?
    let script: String?
    let markdown: String?
    let playbookData: PlaybookData?
    let currentPageIndex: Int?
    let savedPageIndex: Int?
    let imageBaseUrl: String?
    
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case courseName = "course_name"
        case courseId = "course_id"
        case sessionName = "session_name"
        case phase, script, markdown
        case playbookData = "playbook_data"
        case currentPageIndex = "current_page_index"
        case savedPageIndex = "saved_page_index"
        case imageBaseUrl = "image_base_url"
    }
}

// MARK: - 课程多课时模型
struct SmartClassCourseSessionListResponse: Codable {
    let sessions: [SmartClassCourseSession]
}

struct SmartClassCourseSession: Codable, Identifiable {
    let id: Int
    let courseId: Int?
    let name: String
    let script: String?
    let runtimeSessionId: String?
    let deliveryTime: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case courseId = "course_id"
        case name, script
        case runtimeSessionId = "runtime_session_id"
        case deliveryTime = "delivery_time"
    }
}

// 预解析语音片段
struct PlaybookData: Codable {
    let segments: [PlaybookSegment]?
    let visualActions: [PlaybookVisualAction]?
    
    enum CodingKeys: String, CodingKey {
        case segments
        case visualActions = "visual_actions"
    }
}

struct PlaybookSegment: Codable, Identifiable {
    var id: String {
        return rawId ?? "seg_\(slideIndex)"
    }
    let rawId: String?
    let text: String?
    private let explicitSlideIndex: Int?
    
    var slideIndex: Int {
        if let exp = explicitSlideIndex { return exp }
        // 后端 playbook.py 生成规则: seg_{block_id}_{index}
        if let idStr = rawId {
            let parts = idStr.components(separatedBy: "_")
            if parts.count >= 2, let parsed = Int(parts[1]) {
                return parsed
            }
        }
        return 0
    }
    
    enum CodingKeys: String, CodingKey {
        case rawId = "id"
        case text
        case explicitSlideIndex = "slide_index"
    }
}

struct PlaybookVisualAction: Codable {
    let action: String?
    let target: String?
    let slideIndex: Int?
    
    enum CodingKeys: String, CodingKey {
        case action, target
        case slideIndex = "slide_index"
    }
}


// MARK: - WebSocket 信令模型

/// 导播台/服务端广播的状态同步消息 (STATE_SYNC)
struct SmartClassStateSyncMessage: Codable {
    let type: String
    let sender: String?
    let payload: StateSyncPayload
    
    struct StateSyncPayload: Codable {
        let currentPageIndex: Int
        let totalSlides: Int?
        let qrContent: String?
    }
}

/// 实体激光笔/大屏/服务端广播的跳转消息 (PAGE_NAV)
struct SmartClassPageNavMessage: Codable {
    let type: String
    let targetPage: Int
    let sender: String?
    
    enum CodingKeys: String, CodingKey {
        case type
        case targetPage = "target_page"
        case sender
    }
}

// MARK: - 身份认证与凭证模型

struct LocalLoginRequest: Codable {
    let username: String
    let password: String
}

struct DevLoginRequest: Codable {
    let username: String
    let role: String
    let accessCode: String
    
    enum CodingKeys: String, CodingKey {
        case username, role
        case accessCode = "access_code"
    }
}

struct AuthTokenResponse: Codable {
    let accessToken: String
    let tokenType: String
    let userId: String?
    let role: String?
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case userId = "user_id"
        case role
    }
}

struct UserProfile: Codable {
    let username: String?
    let fullName: String?
    let role: String?
    
    enum CodingKeys: String, CodingKey {
        case username
        case fullName = "full_name"
        case role
    }
}
