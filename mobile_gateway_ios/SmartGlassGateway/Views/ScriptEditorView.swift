import SwiftUI

/// 讲稿新建/编辑视图
struct ScriptEditorView: View {
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject var storage = ScriptStorage.shared
    
    var scriptToEdit: ScriptItem?
    
    @State private var title: String = ""
    @State private var content: String = ""
    @State private var scrollMode: TeleprompterScrollMode = .ai
    @State private var targetWidthChars: Int = 28
    
    var isNew: Bool { scriptToEdit == nil }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("讲稿元数据")) {
                    TextField("输入讲稿标题", text: $title)
                        .font(.headline)
                    
                    Picker("提词滚动模式", selection: $scrollMode) {
                        ForEach(TeleprompterScrollMode.allCases) { mode in
                            Label(mode.displayName, systemImage: mode.iconName).tag(mode)
                        }
                    }
                }
                
                Section(header: Text("讲稿正文 (自动按 28 汉字 x 10 行切分全屏)")) {
                    TextEditor(text: $content)
                        .frame(minHeight: 280)
                        .font(.system(.body, design: .default))
                }
                
                Section(header: Text("排版统计")) {
                    HStack {
                        Text("总字符数")
                        Spacer()
                        Text("\(content.count) 字")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("自然换行数")
                        Spacer()
                        Text("\(content.filter({ $0 == "\n" }).count + 1) 行")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("估算 G2 显存页数")
                        Spacer()
                        let pagesCount = max(1, (content.count / (28 * 10)) + 1)
                        Text("\(pagesCount) 页 (全屏 28 字 x 10 行)")
                            .foregroundColor(.purple)
                            .fontWeight(.bold)
                    }
                }
            }
            .navigationTitle(isNew ? "新建讲稿" : "编辑讲稿")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || content.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let script = scriptToEdit {
                    title = script.title
                    content = script.content
                    scrollMode = script.scrollMode
                    targetWidthChars = script.targetWidthChars
                } else {
                    title = "未命名讲稿_\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
                }
            }
        }
    }
    
    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if var script = scriptToEdit {
            script.title = trimmedTitle
            script.content = trimmedContent
            script.scrollMode = scrollMode
            script.targetWidthChars = targetWidthChars
            storage.updateScript(script)
        } else {
            let newScript = ScriptItem(
                title: trimmedTitle,
                content: trimmedContent,
                updatedAt: Date(),
                scrollMode: scrollMode,
                targetWidthChars: targetWidthChars
            )
            storage.addScript(newScript)
        }
        presentationMode.wrappedValue.dismiss()
    }
}
