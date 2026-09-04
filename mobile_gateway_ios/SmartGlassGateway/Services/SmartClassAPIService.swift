import Foundation

/// 智慧课堂生产 RESTful API 通信服务
class SmartClassAPIService {
    static let shared = SmartClassAPIService()
    private let session = URLSession(configuration: .default)
    
    private func normalizeBaseURL(_ baseURL: String) -> String {
        var clean = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                           .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if clean.hasSuffix("/smart-class") {
            clean = String(clean.dropLast("/smart-class".count))
        }
        return clean
    }
    
    /// 1. 获取课时完整剧本、预解析口述稿与当前进度 (自动注入 Bearer Token)
    func fetchSessionInfo(baseURL: String, sessionId: String, token: String? = AuthService.shared.token, completion: @escaping (Result<SmartClassSessionInfo, Error>) -> Void) {
        let cleanBase = normalizeBaseURL(baseURL)
        guard let url = URL(string: "\(cleanBase)/smart-class/api/sessions/\(sessionId)/info") else {
            completion(.failure(URLError(.badURL)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let token = token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        session.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                AuthService.shared.handleUnauthorized()
                completion(.failure(URLError(.userAuthenticationRequired)))
                return
            }
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(URLError(.zeroByteResource)))
                return
            }
            if let rawStr = String(data: data, encoding: .utf8) {
                NSLog("📥 [Session Info] 状态码 %ld，响应长度 %ld 字符", (response as? HTTPURLResponse)?.statusCode ?? 0, rawStr.count)
            }
            do {
                let info = try JSONDecoder().decode(SmartClassSessionInfo.self, from: data)
                completion(.success(info))
            } catch {
                NSLog("❌ [Session Info] 解码失败: %@", error.localizedDescription)
                completion(.failure(error))
            }
        }.resume()
    }
    
    /// 获取课程下所有课时列表 (GET /api/courses/{course_id}/sessions)
    func fetchCourseSessions(baseURL: String, courseId: Int, token: String? = AuthService.shared.token, completion: @escaping (Result<[SmartClassCourseSession], Error>) -> Void) {
        var cleanBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !cleanBase.hasSuffix("/smart-class") {
            cleanBase += "/smart-class"
        }
        let urlStr = "\(cleanBase)/api/courses/\(courseId)/sessions"
        guard let url = URL(string: urlStr) else {
            completion(.failure(URLError(.badURL)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let token = token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(URLError(.zeroByteResource)))
                return
            }
            do {
                let resp = try JSONDecoder().decode(SmartClassCourseSessionListResponse.self, from: data)
                completion(.success(resp.sessions))
            } catch {
                NSLog("❌ [Course Sessions] 解码失败: %@", error.localizedDescription)
                completion(.failure(error))
            }
        }.resume()
    }
    
    /// 2. 激光翻页笔平级反向翻页广播通知 (POST page-nav)
    func notifyPageNav(baseURL: String, sessionId: String, targetPage: Int, token: String? = AuthService.shared.token, completion: ((Bool) -> Void)? = nil) {
        let cleanBase = normalizeBaseURL(baseURL)
        guard let url = URL(string: "\(cleanBase)/smart-class/api/sessions/\(sessionId)/page-nav") else {
            completion?(false)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = ["target_page": targetPage]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        session.dataTask(with: request) { _, response, error in
            let success = (error == nil && (response as? HTTPURLResponse)?.statusCode == 200)
            completion?(success)
        }.resume()
    }
    
    /// 3. 页面进度持久化落库 (PUT page-index)
    func persistPageIndex(baseURL: String, sessionId: String, pageIndex: Int, token: String? = AuthService.shared.token, completion: ((Bool) -> Void)? = nil) {
        let cleanBase = normalizeBaseURL(baseURL)
        guard let url = URL(string: "\(cleanBase)/smart-class/api/sessions/\(sessionId)/page-index") else {
            completion?(false)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = ["page_index": pageIndex]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        session.dataTask(with: request) { _, response, error in
            let success = (error == nil && (response as? HTTPURLResponse)?.statusCode == 200)
            completion?(success)
        }.resume()
    }
    
    /// 获取课程当前活跃的课时 ID (GET /api/courses/{course_id}/active-session)
    func fetchActiveSession(baseURL: String, courseId: Int, completion: @escaping (String?) -> Void) {
        let cleanBase = normalizeBaseURL(baseURL)
        guard let url = URL(string: "\(cleanBase)/smart-class/api/courses/\(courseId)/active-session") else {
            completion(nil)
            return
        }
        session.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = json["session_id"] as? String else {
                completion(nil)
                return
            }
            completion(sid)
        }.resume()
    }
    
    /// 激活指定课时为主屏幕授课课时 (POST /api/sessions/{session_id}/activate)
    func activateSession(baseURL: String, sessionId: String, token: String? = AuthService.shared.token, completion: ((Result<String, Error>) -> Void)? = nil) {
        let cleanBase = normalizeBaseURL(baseURL)
        guard let url = URL(string: "\(cleanBase)/smart-class/api/sessions/\(sessionId)/activate") else {
            completion?(.failure(URLError(.badURL)))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = "{}".data(using: .utf8)
        
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion?(.failure(error))
                return
            }
            guard let data = data else {
                completion?(.failure(URLError(.zeroByteResource)))
                return
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let activeSid = json["active_session_id"] as? String {
                completion?(.success(activeSid))
            } else {
                completion?(.success(sessionId))
            }
        }.resume()
    }
}
