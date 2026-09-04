import Foundation
import Security

/// 智慧课堂身份认证与凭证管理服务 (支持工号密码登录、演练安全码快捷登录与 Keychain 安全存储)
class AuthService: ObservableObject {
    static let shared = AuthService()
    
    @Published var token: String?
    @Published var currentUser: UserProfile?
    @Published var isAuthenticated: Bool = false
    @Published var isLoading: Bool = false
    @Published var lastError: String?
    
    private let tokenKey = "com.smartcourse.smartglass.jwt"
    private let session = URLSession(configuration: .default)
    
    init() {
        if let savedToken = readTokenFromKeychain(), !savedToken.isEmpty {
            self.token = savedToken
            self.isAuthenticated = true
        }
    }
    
    /// 1. 本地账号密码登录: POST /smart-class/api/auth/login
    func login(baseURL: String, request: LocalLoginRequest, completion: @escaping (Result<String, Error>) -> Void) {
        postAuth(baseURL: baseURL, path: "/smart-class/api/auth/login", body: request, completion: completion)
    }
    
    /// 2. 演练/开发环境快捷登录: POST /smart-class/api/auth/dev-login
    func devLogin(baseURL: String, request: DevLoginRequest, completion: @escaping (Result<String, Error>) -> Void) {
        postAuth(baseURL: baseURL, path: "/smart-class/api/auth/dev-login", body: request, completion: completion)
    }
    
    private func normalizeBaseURL(_ baseURL: String) -> String {
        var clean = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                           .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if clean.hasSuffix("/smart-class") {
            clean = String(clean.dropLast("/smart-class".count))
        }
        return clean
    }
    
    /// 3. 校验 Token 并获取当前用户信息: GET /smart-class/api/users/me
    func validateToken(baseURL: String, completion: ((Result<UserProfile, Error>) -> Void)? = nil) {
        guard let currentToken = self.token, !currentToken.isEmpty else {
            completion?(.failure(URLError(.userAuthenticationRequired)))
            return
        }
        
        let cleanBase = normalizeBaseURL(baseURL)
        guard let url = URL(string: "\(cleanBase)/smart-class/api/users/me") else {
            completion?(.failure(URLError(.badURL)))
            return
        }
        
        var req = URLRequest(url: url)
        req.setValue("Bearer \(currentToken)", forHTTPHeaderField: "Authorization")
        
        session.dataTask(with: req) { [weak self] data, response, error in
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                self?.handleUnauthorized()
                completion?(.failure(URLError(.userAuthenticationRequired)))
                return
            }
            if let error = error {
                completion?(.failure(error))
                return
            }
            guard let data = data else {
                completion?(.failure(URLError(.zeroByteResource)))
                return
            }
            do {
                let profile = try JSONDecoder().decode(UserProfile.self, from: data)
                DispatchQueue.main.async {
                    self?.currentUser = profile
                    self?.isAuthenticated = true
                }
                completion?(.success(profile))
            } catch {
                completion?(.failure(error))
            }
        }.resume()
    }
    
    /// 检查 JWT Payload 中是否处于 pending 状态
    private func isPendingToken(_ jwtToken: String) -> Bool {
        let parts = jwtToken.components(separatedBy: ".")
        guard parts.count >= 2 else { return false }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return false
        }
        return type == "pending"
    }

    /// 自动将 pending 身份升级为 teacher 身份
    private func upgradePendingTokenToTeacher(_ pendingToken: String, baseURL: String, completion: @escaping (String) -> Void) {
        let cleanBase = normalizeBaseURL(baseURL)
        guard let url = URL(string: "\(cleanBase)/smart-class/api/auth/select-role") else {
            completion(pendingToken)
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(pendingToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["role": "teacher"])
        
        session.dataTask(with: req) { data, _, error in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let realToken = json["access_token"] as? String, !realToken.isEmpty {
                NSLog("🎉 [Auth] 成功将 CAS Pending Token 自动升级为正式 Teacher Token")
                completion(realToken)
            } else {
                completion(pendingToken)
            }
        }.resume()
    }

    /// 讲师一键快捷授信登录 (工号 004475 专属安全通道)
    func quickTeacherLogin(baseURL: String, completion: @escaping (Result<String, Error>) -> Void) {
        let req = DevLoginRequest(username: "004475", role: "teacher", accessCode: "OoAA75!")
        devLogin(baseURL: baseURL, request: req) { [weak self] result in
            switch result {
            case .success(let token):
                self?.importToken(token, baseURL: baseURL) { _ in
                    completion(.success(token))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    /// 4. 导入/保存 Token（统一身份认证 CAS 截获或手动粘贴导入）
    func importToken(_ token: String, baseURL: String = "https://syb.ncu.edu.cn", completion: ((Result<UserProfile, Error>) -> Void)? = nil) {
        var clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
                         .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if clean.lowercased().hasPrefix("bearer ") {
            clean = String(clean.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !clean.isEmpty else {
            completion?(.failure(URLError(.badServerResponse)))
            return
        }
        
        // 若为 CAS 生成的双角色 Pending Token，自动以教师身份完成换签
        if isPendingToken(clean) {
            upgradePendingTokenToTeacher(clean, baseURL: baseURL) { [weak self] realToken in
                self?.applyFinalToken(realToken, baseURL: baseURL, completion: completion)
            }
        } else {
            applyFinalToken(clean, baseURL: baseURL, completion: completion)
        }
    }
    
    private func applyFinalToken(_ finalToken: String, baseURL: String, completion: ((Result<UserProfile, Error>) -> Void)?) {
        saveTokenToKeychain(finalToken)
        DispatchQueue.main.async {
            self.token = finalToken
            self.isAuthenticated = true
            self.lastError = nil
        }
        validateToken(baseURL: baseURL, completion: completion)
    }
    
    /// 5. 注销登录与凭据清理
    func logout() {
        deleteTokenFromKeychain()
        DispatchQueue.main.async {
            self.token = nil
            self.currentUser = nil
            self.isAuthenticated = false
            self.lastError = nil
        }
    }
    
    /// 5. 统一处理 401 凭证失效
    func handleUnauthorized() {
        logout()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("AuthTokenExpiredNotification"), object: nil)
        }
    }
    
    // MARK: - 内部辅助方法
    
    private func postAuth<T: Encodable>(baseURL: String, path: String, body: T, completion: @escaping (Result<String, Error>) -> Void) {
        let cleanBase = normalizeBaseURL(baseURL)
        guard let url = URL(string: "\(cleanBase)\(path)") else {
            completion(.failure(URLError(.badURL)))
            return
        }
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            req.httpBody = try JSONEncoder().encode(body)
        } catch {
            completion(.failure(error))
            return
        }
        
        DispatchQueue.main.async {
            self.isLoading = true
            self.lastError = nil
        }
        
        session.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false
            }
            if let error = error {
                DispatchQueue.main.async { self?.lastError = error.localizedDescription }
                completion(.failure(error))
                return
            }
            guard let data = data else {
                let err = URLError(.zeroByteResource)
                DispatchQueue.main.async { self?.lastError = err.localizedDescription }
                completion(.failure(err))
                return
            }
            
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let errMsg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                let err = NSError(domain: "AuthService", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: errMsg])
                DispatchQueue.main.async { self?.lastError = errMsg }
                completion(.failure(err))
                return
            }
            
            do {
                let res = try JSONDecoder().decode(AuthTokenResponse.self, from: data)
                self?.saveTokenToKeychain(res.accessToken)
                DispatchQueue.main.async {
                    self?.token = res.accessToken
                    self?.isAuthenticated = true
                    self?.lastError = nil
                }
                completion(.success(res.accessToken))
            } catch {
                DispatchQueue.main.async { self?.lastError = error.localizedDescription }
                completion(.failure(error))
            }
        }.resume()
    }
    
    // MARK: - Keychain 安全持久化
    
    private func saveTokenToKeychain(_ token: String) {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tokenKey,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
    
    private func readTokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tokenKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return nil
    }
    
    private func deleteTokenFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tokenKey
        ]
        SecItemDelete(query as CFDictionary)
    }
}
