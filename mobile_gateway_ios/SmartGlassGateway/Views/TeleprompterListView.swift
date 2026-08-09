import SwiftUI
import UniformTypeIdentifiers

/// 官方同款 提词器主列表视图 (Teleprompter List View)
struct TeleprompterListView: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject var storage = ScriptStorage.shared
    
    @State private var showingNewEditor: Bool = false
    @State private var showingFileImporter: Bool = false
    @State private var importErrorMessage: String? = nil
    @State private var showingErrorAlert: Bool = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 🌟 策略切换开关 Toggle
                HStack {
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .foregroundColor(bleManager.useV2OnDemandPadding ? .blue : .orange)
                        .font(.system(size: 18))
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text(bleManager.useV2OnDemandPadding ? "下发策略: V2 按需下发 (100% 官方)" : "下发策略: V1 14页固定补满")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(bleManager.useV2OnDemandPadding ? .blue : .orange)
                        Text(bleManager.useV2OnDemandPadding ? "零多余空页填充，推屏更快" : "补满 14 页 Buffer 槽位")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $bleManager.useV2OnDemandPadding)
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: .blue))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.06))
                
                Divider()
                
                // MARK: - 排序与记录条数工具栏
                HStack {
                    Text("\(storage.scripts.count) 记录")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    // 排序维度选择
                    Menu {
                        ForEach(ScriptSortOrder.allCases) { order in
                            Button(action: {
                                storage.selectedSortOrder = order
                            }) {
                                HStack {
                                    Text(order.rawValue)
                                    if storage.selectedSortOrder == order {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(storage.selectedSortOrder.rawValue)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(8)
                        .foregroundColor(.primary)
                    }
                    
                    // 排序切换按钮
                    Button(action: {
                        withAnimation {
                            if storage.selectedSortOrder == .dateDesc {
                                storage.selectedSortOrder = .dateAsc
                            } else {
                                storage.selectedSortOrder = .dateDesc
                            }
                        }
                    }) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.subheadline)
                            .padding(6)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(8)
                            .foregroundColor(.primary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                
                // MARK: - 讲稿卡片列表
                if storage.scripts.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 60))
                            .foregroundColor(.gray.opacity(0.5))
                        Text("暂无讲稿")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("点击下方“新建”或“导入”开始创建你的演讲逐字稿")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Spacer()
                    }
                } else {
                    List {
                        ForEach(storage.scripts) { script in
                            NavigationLink(destination: TeleprompterPreviewView(script: script)) {
                                ScriptRowCard(script: script)
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                        .onDelete(perform: storage.deleteScript)
                    }
                    .listStyle(.plain)
                }
                
                // MARK: - 底部新建与导入按钮
                HStack(spacing: 16) {
                    Button(action: {
                        showingNewEditor = true
                    }) {
                        HStack {
                            Image(systemName: "plus.square")
                            Text("新建")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                        .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 3)
                    }
                    
                    Button(action: {
                        showingFileImporter = true
                    }) {
                        HStack {
                            Image(systemName: "arrow.down.doc")
                            Text("导入")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                        .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 3)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Color(UIColor.systemGroupedBackground).edgesIgnoringSafeArea(.bottom))
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("提词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {}) {
                        Image(systemName: "crop")
                            .foregroundColor(.primary)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {}) {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundColor(.primary)
                    }
                }
            }
            .sheet(isPresented: $showingNewEditor) {
                ScriptEditorView()
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.plainText, .text, .utf8PlainText],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let selectedUrl = urls.first {
                        if storage.importFromFile(url: selectedUrl) == nil {
                            importErrorMessage = "导入读取失败，请检查文件格式是否为纯文本。"
                            showingErrorAlert = true
                        }
                    }
                case .failure(let error):
                    importErrorMessage = error.localizedDescription
                    showingErrorAlert = true
                }
            }
            .alert(isPresented: $showingErrorAlert) {
                Alert(title: Text("导入失败"), message: Text(importErrorMessage ?? "未知错误"), dismissButton: .default(Text("确定")))
            }
        }
    }
}

/// 单张讲稿卡片组件 (适配浅色与深色模式)
struct ScriptRowCard: View {
    let script: ScriptItem
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(script.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                
                Text(script.formattedDateString)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.04), radius: 4, x: 0, y: 2)
    }
}
