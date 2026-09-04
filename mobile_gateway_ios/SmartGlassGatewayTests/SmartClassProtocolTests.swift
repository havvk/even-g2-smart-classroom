import XCTest
@testable import SmartGlassGateway

final class SmartClassProtocolTests: XCTestCase {
    
    // MARK: - 1. 课时剧本与预解析段落解码测试
    func testSessionInfoDecoding() throws {
        let jsonStr = """
        {
            "session_id": "sess_class_101",
            "course_name": "人机协同程序设计",
            "session_name": "第十讲 工作流与ReAct范式",
            "phase": "LECTURE",
            "script": "# 课件标题\\n\\n---\\n\\n## 第一页幻灯片\\n\\n:::playbook\\n同学们好！欢迎进入今天的实战教学。(Visual: @focus #hero)\\n:::\\n",
            "playbook_data": {
                "segments": [
                    {
                        "id": "seg_0_0",
                        "text": "同学们好！欢迎进入今天的实战教学。",
                        "slide_index": 0
                    },
                    {
                        "id": "seg_1_0",
                        "text": "在人机协同中，工作流是将大模型融入业务的核心架构。",
                        "slide_index": 1
                    }
                ]
            },
            "current_page_index": 0,
            "image_base_url": "/static/images"
        }
        """
        
        let data = jsonStr.data(using: .utf8)!
        let info = try JSONDecoder().decode(SmartClassSessionInfo.self, from: data)
        
        XCTAssertEqual(info.sessionId, "sess_class_101")
        XCTAssertEqual(info.courseName, "人机协同程序设计")
        XCTAssertEqual(info.currentPageIndex, 0, "严格对齐 0-based 规范")
        XCTAssertEqual(info.playbookData?.segments.count, 2)
        XCTAssertEqual(info.playbookData?.segments[0].text, "同学们好！欢迎进入今天的实战教学。")
        XCTAssertEqual(info.playbookData?.segments[0].slideIndex, 0)
        XCTAssertEqual(info.playbookData?.segments[1].slideIndex, 1)
    }
    
    // MARK: - 2. 信令报文解码测试
    func testStateSyncMessageDecoding() throws {
        let jsonStr = """
        {
            "type": "STATE_SYNC",
            "sender": "presenter",
            "payload": {
                "currentPageIndex": 5,
                "totalSlides": 28,
                "qrContent": "https://example.com/checkin"
            }
        }
        """
        let data = jsonStr.data(using: .utf8)!
        let msg = try JSONDecoder().decode(SmartClassStateSyncMessage.self, from: data)
        XCTAssertEqual(msg.type, "STATE_SYNC")
        XCTAssertEqual(msg.payload.currentPageIndex, 5)
        XCTAssertEqual(msg.payload.totalSlides, 28)
    }
    
    func testPageNavMessageDecoding() throws {
        let jsonStr = """
        {
            "type": "PAGE_NAV",
            "target_page": 6,
            "sender": "screen"
        }
        """
        let data = jsonStr.data(using: .utf8)!
        let msg = try JSONDecoder().decode(SmartClassPageNavMessage.self, from: data)
        XCTAssertEqual(msg.type, "PAGE_NAV")
        XCTAssertEqual(msg.targetPage, 6)
        XCTAssertEqual(msg.sender, "screen")
    }
    
    // MARK: - 3. 身份认证模型测试
    func testAuthModels() throws {
        let tokenJson = """
        {
            "access_token": "jwt_token_sample_abc123",
            "token_type": "bearer",
            "user_id": "004475",
            "role": "TEACHER"
        }
        """
        let data = tokenJson.data(using: .utf8)!
        let auth = try JSONDecoder().decode(AuthTokenResponse.self, from: data)
        XCTAssertEqual(auth.accessToken, "jwt_token_sample_abc123")
        XCTAssertEqual(auth.tokenType, "bearer")
        XCTAssertEqual(auth.userId, "004475")
        XCTAssertEqual(auth.role, "TEACHER")
    }
}
