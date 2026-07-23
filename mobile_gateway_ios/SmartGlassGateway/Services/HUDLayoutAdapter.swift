import Foundation

class HUDLayoutAdapter {
    static let shared = HUDLayoutAdapter()
    
    let maxCharsPerLine = 18 // 18 汉字或 36 英文字符
    
    /// 将一长段逐字稿拆分为符合 18 字符每行的句子数组
    func formatScriptToLines(script: String) -> [String] {
        var lines: [String] = []
        let rawParagraphs = script.components(separatedBy: CharacterSet(charactersIn: "。！？；\n"))
        
        for paragraph in rawParagraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            
            var currentLine = ""
            for char in trimmed {
                currentLine.append(char)
                if currentLine.count >= maxCharsPerLine {
                    lines.append(currentLine)
                    currentLine = ""
                }
            }
            if !currentLine.isEmpty {
                lines.append(currentLine)
            }
        }
        return lines
    }
    
    /// 根据当前高亮的文本行索引，构建 HUD 3 行显存显示块
    func buildHUDChunk(
        currentPage: Int,
        totalPages: Int,
        checkinText: String,
        lines: [String],
        activeLineIndex: Int
    ) -> HUDDisplayChunk {
        let pageStr = String(format: "%02d", currentPage)
        let totalStr = String(format: "%02d", totalPages)
        let header = "[P\(pageStr)/\(totalStr)] \(checkinText)"
        
        guard !lines.isEmpty else {
            return HUDDisplayChunk(
                headerText: header,
                highlightedLine: "暂无逐字稿提示",
                nextLinePreview: "轻按戒指切换 Slide",
                footerStatus: "‹ 上一页 | 下一页 ›"
            )
        }
        
        let validIndex = min(max(0, activeLineIndex), lines.count - 1)
        let activeLine = lines[validIndex]
        let nextLine = (validIndex + 1 < lines.count) ? lines[validIndex + 1] : "--- 本页终点 ---"
        
        return HUDDisplayChunk(
            headerText: header,
            highlightedLine: activeLine,
            nextLinePreview: nextLine,
            footerStatus: "‹ 上一页 | 下一页 ›"
        )
    }
}
