//
//  WatchSessionManagerTests.swift
//  SmartGlassGatewayTests
//
//  Apple Watch 操控与消息解调单元测试集
//

import XCTest
import Combine
@testable import SmartGlassGateway

final class WatchSessionManagerTests: XCTestCase {
    
    var manager: WatchSessionManager!
    
    override func setUp() {
        super.setUp()
        manager = WatchSessionManager.shared
    }
    
    // MARK: - TC_WATCH_001: 校验 Watch 捏手指 / Tap 下一步翻页指令解调
    func testWatchPageControlNext_TC_WATCH_001() {
        let expectation = expectation(description: "Watch NEXT page control closure invoked")
        
        manager.onPageControlTriggered = { action, source in
            XCTAssertEqual(action, "NEXT")
            XCTAssertEqual(source, "WATCH_TAP")
            expectation.fulfill()
        }
        
        // 模拟捕获 WCSession 收到 Watch 消息
        let mockMessage: [String: Any] = [
            "type": "PAGE_CONTROL",
            "action": "NEXT",
            "source": "WATCH_TAP",
            "timestamp": 1784783900
        ]
        
        manager.session(WCSession.default, didReceiveMessage: mockMessage)
        
        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(manager.lastWatchGesture, "WATCH_TAP: NEXT")
    }
    
    // MARK: - TC_WATCH_002: 校验 CoreMotion 甩手姿态 (Wrist Flick) 上一步翻页指令解调
    func testWatchPageControlPrev_TC_WATCH_002() {
        let expectation = expectation(description: "Watch PREV wrist flick closure invoked")
        
        manager.onPageControlTriggered = { action, source in
            XCTAssertEqual(action, "PREV")
            XCTAssertEqual(source, "WATCH_WRIST_FLICK")
            expectation.fulfill()
        }
        
        let mockMessage: [String: Any] = [
            "type": "PAGE_CONTROL",
            "action": "PREV",
            "source": "WATCH_WRIST_FLICK",
            "timestamp": 1784783905
        ]
        
        manager.session(WCSession.default, didReceiveMessage: mockMessage)
        
        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(manager.lastWatchGesture, "WATCH_WRIST_FLICK: PREV")
    }
    
    // MARK: - TC_WATCH_003: 校验 Eye 显存休眠/唤醒指令解调
    func testWatchDisplaySleepWake_TC_WATCH_003() {
        let sleepExpectation = expectation(description: "Sleep HUD closure invoked")
        var receivedIsWake: Bool?
        
        manager.onDisplayToggleTriggered = { isWake in
            receivedIsWake = isWake
            sleepExpectation.fulfill()
        }
        
        // 1. 模拟收到 SLEEP_HUD
        let sleepMessage: [String: Any] = [
            "type": "PAGE_CONTROL",
            "action": "SLEEP_HUD",
            "source": "WATCH_POWER_TOGGLE"
        ]
        manager.session(WCSession.default, didReceiveMessage: sleepMessage)
        wait(for: [sleepExpectation], timeout: 1.0)
        XCTAssertEqual(receivedIsWake, false)
        
        // 2. 模拟收到 WAKE_HUD
        let wakeExpectation = expectation(description: "Wake HUD closure invoked")
        manager.onDisplayToggleTriggered = { isWake in
            receivedIsWake = isWake
            wakeExpectation.fulfill()
        }
        let wakeMessage: [String: Any] = [
            "type": "PAGE_CONTROL",
            "action": "WAKE_HUD",
            "source": "WATCH_POWER_TOGGLE"
        ]
        manager.session(WCSession.default, didReceiveMessage: wakeMessage)
        wait(for: [wakeExpectation], timeout: 1.0)
        XCTAssertEqual(receivedIsWake, true)
    }
    
    // MARK: - TC_WATCH_004: 校验 AI对话与实时转录快捷按键回调
    func testWatchAIChatAndTranscribe_TC_WATCH_004() {
        let aiExpectation = expectation(description: "AI Chat closure invoked")
        manager.onAIChatTriggered = {
            aiExpectation.fulfill()
        }
        
        let aiMessage: [String: Any] = [
            "type": "PAGE_CONTROL",
            "action": "TRIGGER_AI_CHAT",
            "source": "WATCH_AI_BUTTON"
        ]
        manager.session(WCSession.default, didReceiveMessage: aiMessage)
        wait(for: [aiExpectation], timeout: 1.0)
        
        let transcribeExpectation = expectation(description: "Transcribe closure invoked")
        manager.onTranscribeTriggered = {
            transcribeExpectation.fulfill()
        }
        let transcribeMessage: [String: Any] = [
            "type": "PAGE_CONTROL",
            "action": "TOGGLE_TRANSCRIBE",
            "source": "WATCH_TRANSCRIBE_BUTTON"
        ]
        manager.session(WCSession.default, didReceiveMessage: transcribeMessage)
        wait(for: [transcribeExpectation], timeout: 1.0)
    }
    
    // MARK: - TC_WATCH_005: 校验 Watch 状态同步参数构造
    func testWatchStateSync_TC_WATCH_005() {
        XCTAssertNoThrow(
            manager.syncStateToWatch(currentPage: 5, totalPages: 24, isServerConnected: true)
        )
    }
}
