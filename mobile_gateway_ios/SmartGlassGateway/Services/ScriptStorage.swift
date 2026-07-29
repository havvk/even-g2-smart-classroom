import Foundation
import Combine

enum ScriptSortOrder: String, CaseIterable, Identifiable {
    case dateDesc = "更新日期 ↓"
    case dateAsc = "更新日期 ↑"
    case titleAsc = "标题 A-Z"
    
    var id: String { rawValue }
}

/// 讲稿持久化与文件管理服务
class ScriptStorage: ObservableObject {
    static let shared = ScriptStorage()
    
    @Published var scripts: [ScriptItem] = []
    @Published var selectedSortOrder: ScriptSortOrder = .dateDesc {
        didSet {
            sortScripts()
        }
    }
    
    private let storageKey = "G2SmartGlass_Teleprompter_Scripts"
    
    init() {
        loadScripts()
    }
    
    // MARK: - CRUD Operations
    
    func loadScripts() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ScriptItem].self, from: data) {
            self.scripts = decoded
        } else {
            // 预置官方同款 3 篇讲稿
            self.scripts = ScriptStorage.defaultSampleScripts
            saveScripts()
        }
        sortScripts()
    }
    
    func saveScripts() {
        if let encoded = try? JSONEncoder().encode(scripts) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }
    
    func addScript(_ script: ScriptItem) {
        scripts.insert(script, at: 0)
        saveScripts()
        sortScripts()
    }
    
    func updateScript(_ script: ScriptItem) {
        if let index = scripts.firstIndex(where: { $0.id == script.id }) {
            var updated = script
            updated.updatedAt = Date()
            scripts[index] = updated
            saveScripts()
            sortScripts()
        }
    }
    
    func deleteScript(at offsets: IndexSet) {
        scripts.remove(atOffsets: offsets)
        saveScripts()
    }
    
    func deleteScript(_ script: ScriptItem) {
        scripts.removeAll(where: { $0.id == script.id })
        saveScripts()
    }
    
    func sortScripts() {
        switch selectedSortOrder {
        case .dateDesc:
            scripts.sort(by: { $0.updatedAt > $1.updatedAt })
        case .dateAsc:
            scripts.sort(by: { $0.updatedAt < $1.updatedAt })
        case .titleAsc:
            scripts.sort(by: { $0.title < $1.title })
        }
    }
    
    // MARK: - File Import Helper
    
    func importFromFile(url: URL) -> ScriptItem? {
        guard url.startAccessingSecurityScopedResource() else {
            return nil
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        do {
            let fileContent = try String(contentsOf: url, encoding: .utf8)
            let title = url.deletingPathExtension().lastPathComponent
            let newItem = ScriptItem(
                title: title,
                content: fileContent,
                updatedAt: Date(),
                scrollMode: .ai
            )
            addScript(newItem)
            return newItem
        } catch {
            print("❌ 文件导入失败: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Sample Data
    
    static var defaultSampleScripts: [ScriptItem] {
        return [
            ScriptItem(
                title: "人机协同程序设计课程建设思路_演讲版_逐字稿",
                content: """
各位领导、各位老师，大家上午好！
今天我们召开《人机协同程序设计》课程全校统一数智化教学集体备课研讨会，主要目的是为了贯彻落实教务处文件精神，面向各理工学院及医学院负责该课程授课的全体老师，共同研讨教学规范，明确教学要求，并合力推进标准化教学资源的建设。
我们这门课程定位为跨界通识课，将在 2026 年秋季学期，也就是今年 9 月份正式开课。课程设置可能是 2.0 或 3.0 学分，对应 32 或 48 学时。今天我将围绕本门课程的建设思路、教学策略、考核改革以及资源保障等方面，与各位老师进行深入的探讨与交流。

首先，我们来看一下执行摘要的第一部分，关于课程的痛点与定位。
为了响应全校“专业+AI”的培养大势，我们采用了每周“2+2”的理实一体课时设置：包含 2 学时理论、2 学时实践，以及 2 学时课后协同大作业。这旨在通过“人机协同”与“人际协同”的双重训练，补足大一新生在传统应试教育中缺乏的核心沟通协作本领。

接下来是执行摘要的第二部分，介绍教学策略与资源部署。
策略上，我们基于 A/S/P 标记框架实施渐进式脚手架拆除，帮助学生从依赖 AI 工具逐渐过渡到独立掌控核心逻辑。
在资源建设上，建议学校拨出专项算力资金在本地私有部署 Python 和 LLM 模型，消除开销壁垒。

第三部分是考核改革方案的详细介绍。
我们大幅提高了过程性评价的比重，重点引入了限时人机协作编程测试与结构化 Code Review，杜绝代码抄袭。

第四部分是资源标准化建设。
我们将建立全校统一的教案库、案例库与自动化评分 Pipeline，保障各院系平行班教学质量的一致性。

现在让我们进入第一部分：从成果导向的逻辑出发，阐述课程目标定位。
在深入第一章细节前，我们先来看第一章的全局逻辑链图。这页概念图体现了基于 OBE 反向推导的全貌。
为此我们引入了人机协同新范式，明确人类主导问题域与审计，AI 托管求解域。推导出最下层 OBE 目标。
这一部分的组织逻辑是层层递进的，极大地降低了编程学习门槛，帮助学生快速获得掌控感与成就感。
""",
                updatedAt: Date(timeIntervalSince1970: 1784894880), // 2026/07/24 22:48
                scrollMode: .ai
            ),
            ScriptItem(
                title: "Even Realities へようこそ",
                content: """
Even Realities へようこそ！
スマートグラス G2 へようこそ。
このデバイスは、あなたの毎日のコミュニケーションとプレゼンテーションをよりスマートにサポートします。
リアルタイムの字幕表示やプロンプター機能により、視線を落とすことなく自然な対話が可能です。
""",
                updatedAt: Date(timeIntervalSince1970: 1784823240), // 2026/07/24 02:54
                scrollMode: .ai
            ),
            ScriptItem(
                title: "Welcome to Even Realities",
                content: """
Welcome to Even Realities!
Welcome to Even G2 Smart Glasses.
This device empowers your daily presentation and communication seamlessly.
With real-time teleprompter and head-up display technology, you can engage with your audience effortlessly while keeping full eye contact.
""",
                updatedAt: Date(timeIntervalSince1970: 1784778060), // 2026/07/23 14:41
                scrollMode: .ai
            )
        ]
    }
}
