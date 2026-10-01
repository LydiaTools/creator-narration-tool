import SwiftUI
import AppKit

private enum Stage: String, CaseIterable {
    case words = "写文字"
    case picture = "做画面"
    case voice = "配声音"

    var number: String {
        switch self { case .words: return "01"; case .picture: return "02"; case .voice: return "03" }
    }
    var explanation: String {
        switch self {
        case .words: return "确定要讲什么，留下可用的口播稿"
        case .picture: return "按文案剪真实录屏或素材"
        case .voice: return "从你的音色库选择，配上本期音频"
        }
    }
}

private enum DeskStyle {
    static let ink = Color.primary
    static let teal = Color(red: 0.208, green: 0.400, blue: 0.839)
    static let pale = Color(nsColor: .controlBackgroundColor)
    static let line = Color(nsColor: .separatorColor)
    static let sidebar = Color(red: 0.098, green: 0.169, blue: 0.267)
}

@main struct CreatorVideoWorkbenchApp: App {
    @NSApplicationDelegateAdaptor(AppExitDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup("口播制作") {
            DeskView().frame(minWidth: 780, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 760)
    }
}

private struct DeskView: View {
    @StateObject private var store = WorkbenchStore()
    @State private var project = VideoProject.blank(title: "")
    @State private var stage: Stage = .words
    @State private var showingBenchmark = false
    @State private var showingAsset = false
    @State private var benchmarkURL = ""
    @State private var benchmarkWhy = ""
    @State private var assetURL: URL?
    @State private var assetTags = ""
    @State private var assetSource = ""
    @State private var assetAuthorization = ""
    @State private var detail = ""
    @State private var showSceneDetails = false
    @State private var pageWidth: CGFloat = 900

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 205)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                if store.selectedProject == nil {
                    emptyProject
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            switch stage {
                            case .words: wordsPage
                            case .picture: picturePage
                            case .voice: voicePage
                            }
                        }
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GeometryReader { geometry in
                            Color.clear.onAppear { pageWidth = geometry.size.width }
                                .onChange(of: geometry.size.width) { _, value in pageWidth = value }
                        })
                    }
                    .background(Color(nsColor: .windowBackgroundColor))
                }
                statusBar
            }
        }
        .disabled(store.isLoading)
        .foregroundStyle(DeskStyle.ink)
        .tint(DeskStyle.teal)
        .background(WindowExitHook())
        .onAppear {
            selectCurrent()
            ExitGuard.shared.saveBeforeExit = {
                if store.isBusy || store.isLoading {
                    let alert = NSAlert(); alert.messageText = "正在制作，请完成后再退出"
                    alert.informativeText = "本轮输入已保存；当前生成任务仍在运行。"
                    alert.runModal(); return false
                }
                guard store.selectedProject != nil else { return true }
                store.update(project)
                if store.message.hasPrefix("保存失败") || store.message.contains("停止保存") {
                    let alert = NSAlert(); alert.messageText = "本期尚未保存"
                    alert.informativeText = store.message + "。请恢复外盘后再关闭。"
                    alert.runModal(); return false
                }
                return true
            }
        }
        .onChange(of: project) { _, _ in
            guard store.selectedID == project.id, store.selectedProject != nil, !store.isBusy, !store.isLoading else { return }
            store.update(project)
            if let current = store.selectedProject, current != project { project = current }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !store.isBusy && !store.isLoading {
                if store.mounted() { store.receiveSelectedAssets() }
                else { store.load() }
            }
        }
        .onChange(of: project.visual_mode) { _, mode in
            if let selectedWorkflow, selectedWorkflow.engine != mode { project.workflow_id = "" }
        }
        .onChange(of: store.selectedID) { _, _ in selectCurrent() }
        .onChange(of: store.isLoading) { _, loading in
            if !loading { selectCurrent() }
        }
        .sheet(isPresented: $showingBenchmark) { benchmarkSheet }
        .sheet(isPresented: $showingAsset) { assetSheet }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("口播制作", systemImage: "play.rectangle.on.rectangle.fill")
                .font(.system(size: 18, weight: .bold)).padding(.top, 12)
            VStack(spacing: 5) {
                ForEach(Stage.allCases, id: \.self) { item in
                    Button { if saveChanges() { stage = item } } label: {
                        Label(item.rawValue, systemImage: item == .words ? "square.and.pencil" : item == .picture ? "film" : "waveform")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(stage == item ? Color.white.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).disabled(store.isBusy)
                }
            }
            Divider().overlay(Color.white.opacity(0.15))
            Menu {
                ForEach(store.catalog.projects.filter { !$0.is_example }) { item in
                    Button(item.title) { if saveChanges() { store.selectedID = item.id } }
                }
                Divider()
                Button("新建一期视频") { createProject() }
            } label: {
                Text("切换项目 / 新建").font(.system(size: 13, weight: .medium))
            }.menuStyle(.borderlessButton).disabled(store.isBusy)
            ScrollView {
                DisclosureGroup("看示例") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(store.catalog.projects.filter { $0.is_example && $0.phase != "已退回" }) { item in
                            Button { if saveChanges() { store.selectedID = item.id } } label: {
                                Text(item.title).font(.system(size: 12)).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                            }.buttonStyle(.plain).disabled(store.isBusy)
                        }
                    }
                }.font(.system(size: 13))
            }
            Spacer(minLength: 0)
            Label(store.mounted() ? "外盘已连接" : "请连接资料外盘", systemImage: "externaldrive")
                .font(.system(size: 12)).opacity(0.7)
        }.padding(17).foregroundStyle(.white).tint(.white)
            .background(DeskStyle.sidebar)
    }
    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(stage.rawValue).font(.system(size: 24, weight: .bold))
                Text(project.title.isEmpty ? "从一句想法开始" : project.title)
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !project.title.isEmpty {
                Button("保存") { saveChanges() }.buttonStyle(.bordered).disabled(store.isBusy)
                    .help("输入会自动保存；也可手动保存本期")
            }
        }.padding(.horizontal, 22).padding(.vertical, 16)
    }
    private var emptyProject: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack").font(.system(size: 46)).foregroundStyle(DeskStyle.teal)
            if store.mounted() {
                Text("先新建一期视频").font(.system(size: 22, weight: .bold))
                Button("新建一期视频") { createProject() }.buttonStyle(.borderedProminent)
            } else {
                Text("连接视频资料").font(.system(size: 22, weight: .bold))
                Text("第一次使用，选一次外接盘上的视频资料文件夹。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Button("选择资料文件夹") { connectFolder() }.buttonStyle(.borderedProminent)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 9) {
            Circle().fill(store.isBusy ? .orange : store.mounted() ? .green : .red)
                .frame(width: 7, height: 7)
            Text(store.isBusy ? "正在处理，请勿关闭应用" : (detail.isEmpty ? store.message : detail))
                .lineLimit(2).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text("本期：\(project.phase)").font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(.horizontal, 22).padding(.vertical, 11)
            .background(DeskStyle.pale)
    }

    private var wordsPage: some View {
        adaptiveColumns {
            VStack(alignment: .leading, spacing: 16) {
                Text("这期想讲什么？").font(.system(size: 17, weight: .semibold))
                TextEditor(text: binding(\.idea)).font(.system(size: 14))
                    .scrollContentBackground(.hidden).padding(8).frame(height: 86)
                    .background(DeskStyle.pale, in: RoundedRectangle(cornerRadius: 6))
                Picker("制作目的", selection: binding(\.production_goal)) {
                    Text("批量快做").tag("batch"); Text("精品制作").tag("polished")
                }.pickerStyle(.segmented)
                workflowPicker
                Button(project.script.isEmpty ? "生成口播稿" : "重新生成口播稿") { generateDraft() }
                    .buttonStyle(.borderedProminent).disabled(store.isBusy)
                HStack {
                    Text("口播稿").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Button("去做画面") { if saveChanges() { stage = .picture } }.buttonStyle(.bordered)
                }
                TextEditor(text: binding(\.script)).font(.system(size: 14))
                    .scrollContentBackground(.hidden).padding(8).frame(minHeight: 200)
                    .background(DeskStyle.pale, in: RoundedRectangle(cornerRadius: 6))
                if project.script.contains("【待补") {
                    Text("【待补】需要补真实证据。允许直接编辑稿件。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                DisclosureGroup("平台、受众与对标") {
                    VStack(alignment: .leading, spacing: 12) {
                        field("视频题目", text: binding(\.title))
                        Picker("发布平台", selection: binding(\.platform)) {
                            ForEach(["抖音", "B站", "视频号", "小红书", "TikTok", "YouTube", "先做样片"], id: \.self) { Text($0) }
                        }
                        Picker("参考视频", selection: binding(\.benchmark_id)) {
                            Text("不选").tag("")
                            ForEach(store.catalog.benchmarks) { Text($0.title).tag($0.id) }
                        }
                        Button("存对标") { showingBenchmark = true }
                        field("想讲给谁", text: binding(\.audience))
                        field("要解决的问题", text: binding(\.problem))
                        field("产品或办法", text: Binding(get: { project.product ?? "" }, set: { project.product = $0 }))
                    }.padding(.top, 10)
                }.font(.system(size: 13))
            }.frame(maxWidth: .infinity, alignment: .leading)
        } preview: {
            VStack(alignment: .leading, spacing: 14) {
                outputPreview
                DisclosureGroup("选流程 · 看样片与费用") {
                    WorkflowGallery(workflows: store.workflows, project: project) { workflow in
                        project.workflow_id = workflow.id; project.visual_mode = workflow.engine; saveChanges()
                    }.padding(.top, 10)
                }.font(.system(size: 13))
            }
        }.disabled(store.isBusy)
    }

    private var workflowPicker: some View {
        Picker("本期流程", selection: Binding(get: { project.workflow_id }, set: { id in
            project.workflow_id = id
            if let workflow = store.workflows.first(where: { $0.id == id }) { project.visual_mode = workflow.engine }
        })) {
            Text("按想法推荐").tag("")
            ForEach(store.workflows) { Text($0.title).tag($0.id) }
        }
    }

    private func adaptiveColumns<Editor: View, Preview: View>(@ViewBuilder editor: () -> Editor,
                                                             @ViewBuilder preview: () -> Preview) -> some View {
        let layout = pageWidth >= 850 ? AnyLayout(HStackLayout(alignment: .top, spacing: 24)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 22))
        return layout {
            editor().frame(maxWidth: .infinity, alignment: .leading)
            preview().frame(maxWidth: pageWidth >= 850 ? 380 : .infinity, alignment: .leading)
        }
    }

    private var outputPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(project.output.isEmpty ? "流程效果" : "本期预览").font(.system(size: 17, weight: .semibold))
                Spacer()
                if !project.output.isEmpty {
                    Text(readiness.currentOutput ? "本版本 · 待审" : "旧版本 · 已过期")
                        .font(.system(size: 12)).foregroundStyle(readiness.currentOutput ? Color.secondary : Color.orange)
                }
            }
            if !project.output.isEmpty {
                WorkbenchMedia(path: project.output, height: 310)
                Text(readiness.currentOutput ? "检查声音、镜头和字幕后再交付。" : "保留旧片供参考。修改后须重新制作，旧片不代表当前输入。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("在访达中查看") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.output)]) }
                    .buttonStyle(.link)
            } else if let workflow = selectedWorkflow, !workflow.preview_file.isEmpty {
                WorkbenchMedia(path: workflow.preview_file, height: 310)
                Text(workflow.previewLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(workflow.preview_scope ?? workflow.summary).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "film").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("还没有本期视频").font(.system(size: 15, weight: .medium))
                    Text("先选流程看真实样片，再准备本期镜头与配音。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(DeskStyle.pale)
            }
        }
    }
    private var picturePage: some View {
        adaptiveColumns {
            VStack(alignment: .leading, spacing: 16) {
                workflowPicker
                Picker("画面方式", selection: binding(\.visual_mode)) {
                    Text("录屏讲解").tag("recording"); Text("素材混剪").tag("montage")
                    Text("截图讲解").tag("screenshot"); Text("并排对比").tag("comparison")
                    Text("整图白板").tag("whiteboard")
                }
                Picker("画幅", selection: binding(\.frame_format)) {
                    Text("按发布平台").tag("auto"); Text("横版").tag("horizontal"); Text("竖版").tag("vertical")
                }
                Text(readiness.next).font(.system(size: 13)).foregroundStyle(.secondary)
                HStack {
                    Button(project.scenes.isEmpty ? "生成镜头安排" : "一键制作本版本") { startProduction() }
                        .buttonStyle(.borderedProminent).disabled(store.isBusy || selectedWorkflow?.canGenerate == false)
                    if project.visual_mode != "whiteboard" {
                        Button(project.visual_mode == "recording" ? "导入录屏" : "导入素材") { chooseAsset() }.buttonStyle(.bordered)
                    }
                }
                if project.visual_mode == "whiteboard" {
                    Text("\(project.scenes.count) 段关系图。白板用于解释关系，不能替代真实操作证据。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("本期镜头").font(.system(size: 17, weight: .semibold))
                        Spacer(); Button("重新匹配") { matchAssets() }.buttonStyle(.link)
                    }
                    if project.scenes.isEmpty {
                        Text("先在写文字页生成稿件与镜头安排。").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    ForEach(project.scenes) { scene in
                        HStack(alignment: .top, spacing: 12) {
                            if let asset = store.catalog.assets.first(where: { $0.id == scene.asset_id }) {
                                WorkbenchThumbnail(path: asset.path).frame(width: 96, height: 60)
                            } else {
                                Label("缺素材", systemImage: "photo").font(.system(size: 12))
                                    .frame(width: 96, height: 60).background(DeskStyle.pale)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(scene.title).font(.system(size: 14, weight: .medium))
                                Text(scene.body).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                                Text(String(format: "%.1f 秒", scene.duration_seconds) + (readiness.missingScenes.contains(scene.step) ? " · 需要补齐素材" : ""))
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4)
                    }
                }
                DisclosureGroup("调整镜头与卡点") {
                    VStack(alignment: .leading, spacing: 12) {
                        Button("加一段画面") { addScene() }.disabled(project.scenes.count >= 12)
                        ForEach(project.scenes.indices, id: \.self) { index in sceneEditor(index) }
                    }.padding(.top, 10)
                }.font(.system(size: 13))
                DisclosureGroup("只做画面试片") {
                    Text("只生成无声或已有配音的画面供技术检查，不替代完整审片。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
                    Button("生成画面试片") { render() }.buttonStyle(.bordered).disabled(store.isBusy)
                }.font(.system(size: 13))
            }
        } preview: { outputPreview }.disabled(store.isBusy)
    }
    private func sceneEditor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(String(format: "画面 %02d", index + 1)).font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(DeskStyle.teal)
                Spacer()
                TextField("秒数", value: sceneBinding(index, \.duration_seconds), format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 75)
                Text("秒").font(.system(size: 12))
                Button(role: .destructive) { project.scenes.remove(at: index); renumberScenes() } label: {
                    Image(systemName: "trash")
                }.buttonStyle(.plain)
            }
            TextField("本段口播与字幕", text: Binding(get: { project.scenes[index].narration ?? "" },
                set: { project.scenes[index].narration = $0 }))
                .textFieldStyle(.roundedBorder)
            Button("按各段口播同步本期稿") {
                project.script = project.scenes.map { $0.narration ?? "" }.joined(); saveChanges()
            }.font(.system(size: 12))
            TextField("镜头名称", text: sceneBinding(index, \.title))
                .font(.system(size: 15, weight: .medium)).textFieldStyle(.roundedBorder)
            HStack {
                TextField(project.visual_mode == "whiteboard" ? "关系与逻辑说明" : "录什么动作和结果", text: sceneBinding(index, \.body)).textFieldStyle(.roundedBorder)
            }
            if project.visual_mode == "whiteboard" {
                TextField("重点结论", text: sceneBinding(index, \.highlight)).textFieldStyle(.roundedBorder)
                TextField("关系节点，用 / 分隔", text: Binding(
                    get: { project.scenes[index].items.joined(separator: " / ") },
                    set: { project.scenes[index].items = $0.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                    .textFieldStyle(.roundedBorder)
                Picker("关系图", selection: sceneBinding(index, \.layout)) {
                    Text("流程").tag("flow"); Text("对照").tag("compare")
                    Text("循环").tag("loop"); Text("观点").tag("statement")
                    Text("开场").tag("hero")
                }
                Text("文字关系示意；真实操作和效果仍需素材证据。").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
            HStack {
                Text("素材从第").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("秒", value: Binding(get: { project.scenes[index].source_start_seconds ?? 0 },
                    set: { project.scenes[index].source_start_seconds = max(0, $0) }), format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                Text("秒开始").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                Picker("取景", selection: sceneCropBinding(index)) {
                    Text("完整画面").tag("full")
                    Text("浏览器内容区").tag("browser")
                    Text("左侧操作区").tag("left")
                    Text("右侧操作区").tag("right")
                    Text("已设取景").tag("custom")
                }.frame(width: 260)
                Toggle("放大重点", isOn: Binding(get: { project.scenes[index].focus != nil },
                    set: { project.scenes[index].focus = $0 ? [0.5, 0.5, 1.5] : nil }))
                    .toggleStyle(.checkbox)
            }
            HStack {
                Text("画面素材").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("画面素材", selection: sceneAssetBinding(index)) {
                    Text("还缺素材").tag("")
                    ForEach(store.catalog.assets.filter { project.visual_mode != "screenshot" || VideoWorkflow.isImage($0.path) }) { asset in Text(asset.title).tag(asset.id) }
                }.labelsHidden().frame(maxWidth: 330)
                Spacer()
                if let asset = store.catalog.assets.first(where: { $0.id == project.scenes[index].asset_id }) {
                    Text(asset.rights).lineLimit(1).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            }
            if project.visual_mode == "comparison" || project.visual_mode == "screenshot" {
                Picker("右侧素材（截图可留空）", selection: Binding(get: { project.scenes[index].comparison_asset_id ?? "" },
                    set: { project.scenes[index].comparison_asset_id = $0.isEmpty ? nil : $0 })) {
                    Text("未选").tag("")
                    ForEach(store.catalog.assets.filter { project.visual_mode != "screenshot" || VideoWorkflow.isImage($0.path) }) {
                        Text($0.title).tag($0.id)
                    }
                }
                HStack {
                    TextField("左侧标签", text: Binding(get: { project.scenes[index].left_label ?? "左侧" }, set: { project.scenes[index].left_label = $0 }))
                    TextField("右侧标签", text: Binding(get: { project.scenes[index].right_label ?? "右侧" }, set: { project.scenes[index].right_label = $0 }))
                }.textFieldStyle(.roundedBorder)
            }
        }.padding(18)
            .background(DeskStyle.pale)
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var voicePage: some View {
        adaptiveColumns {
            VStack(alignment: .leading, spacing: 16) {
                Text("本期声音").font(.system(size: 17, weight: .semibold))
                Picker("本期音色", selection: binding(\.voice_id)) {
                    Text("尚未选择").tag("")
                    ForEach(store.voices) { Text($0.name).tag($0.id) }
                }
                if let chosen = store.voices.first(where: { $0.id == project.voice_id }) {
                    Text("适合：\((chosen.recommended_for ?? []).joined(separator: "、"))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Button("生成本期配音") { generateAudio() }.buttonStyle(.borderedProminent)
                    .disabled(store.isBusy || project.voice_id.isEmpty || project.script.isEmpty)
                Text("按需运行，完成后试听。内存或存储不足时会停止。").font(.system(size: 12)).foregroundStyle(.secondary)
                Button("导入已有配音") { chooseAudio() }.buttonStyle(.bordered)
                    .help("仅导入与当前稿件一致、已批准使用的音频")
                if !project.audio_path.isEmpty {
                    Text("本期配音").font(.system(size: 17, weight: .semibold))
                    Text(URL(fileURLWithPath: project.audio_path).lastPathComponent).font(.system(size: 12)).lineLimit(2)
                    WorkbenchMedia(path: project.audio_path, audioOnly: true)
                    Text(readiness.audioAvailable ? "已确认与本期稿件对应，合成前仍核验内容。" : "配音需重新确认：稿件或音频内容已变化，或旧档缺少批准记录。")
                        .font(.system(size: 12)).foregroundStyle(readiness.audioAvailable ? Color.secondary : Color.orange)
                    Button("一键制作本版本") { startProduction() }.buttonStyle(.bordered)
                        .disabled(store.isBusy || selectedWorkflow?.canGenerate == false)
                } else {
                    Label("尚无本期配音，请导入或生成", systemImage: "waveform")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                DisclosureGroup("音色建议") {
                    let candidate = store.recommendVoice(for: project)
                    Text(candidate.1).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
                    if let voice = candidate.0 {
                        Button("选择\(voice.name)") { project.voice_id = voice.id; saveChanges() }
                    }
                }.font(.system(size: 13))
                DisclosureGroup("画面卡点与音轨管理") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("未填起点时按时长估算；逐句试听后校准。").font(.system(size: 12)).foregroundStyle(.secondary)
                        ForEach(project.scenes.indices, id: \.self) { index in
                            HStack {
                                Text("画面 \(index + 1)  \(project.scenes[index].title)").lineLimit(1)
                                Spacer()
                                TextField("起点", text: sceneStartBinding(index)).textFieldStyle(.roundedBorder).frame(width: 70)
                                Text("秒")
                            }.font(.system(size: 12))
                        }
                        if !project.audio_path.isEmpty {
                            Button("清除本期配音", role: .destructive) { project.audio_path = ""; saveChanges() }
                        }
                    }.padding(.top, 10)
                }.font(.system(size: 13))
            }
        } preview: { outputPreview }.disabled(store.isBusy)
    }
    private var benchmarkSheet: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("存一条参考视频").font(.system(size: 19, weight: .bold))
            TextField("粘贴视频链接", text: $benchmarkURL)
            TextField("想学它哪一点？可不填", text: $benchmarkWhy)
            Text("这里只保存你给的链接和备注；没看到视频内容时不会编造它的结构。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { showingBenchmark = false }; Button("保存") {
                let title = suggestedBenchmarkTitle(url: benchmarkURL, note: benchmarkWhy)
                store.addBenchmark(title: title, url: benchmarkURL, creator: "",
                                   why: benchmarkWhy, structure: benchmarkWhy.isEmpty ? "" : "用户想借鉴：\(benchmarkWhy)")
                if let item = store.catalog.benchmarks.first, item.title == title {
                    project.benchmark_id = item.id; saveChanges(); showingBenchmark = false
                }
            }.buttonStyle(.borderedProminent) }
        }.textFieldStyle(.roundedBorder).padding(26).frame(width: 560)
    }

    private func suggestedBenchmarkTitle(url: String, note: String) -> String {
        let hint = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hint.isEmpty { return String(hint.prefix(24)) }
        guard let parsed = URL(string: url), let host = parsed.host else { return "参考视频" }
        let platform = host.contains("bilibili") ? "B站" : host.contains("douyin") ? "抖音" : host.contains("youtube") ? "YouTube" : host.contains("tiktok") ? "TikTok" : host
        return "\(platform)参考 · \(DateFormatter.workbench.string(from: Date()).prefix(10))"
    }

    private var assetSheet: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("存一段自己的素材").font(.system(size: 19, weight: .bold))
            Text(assetURL?.lastPathComponent ?? "未选择文件").lineLimit(1)
            Picker("素材来源", selection: $assetSource) {
                Text("请选择").tag("")
                Text("我自己制作的").tag("self")
                Text("别人授权我使用的").tag("authorized")
            }
            if assetSource == "authorized" {
                TextField("谁授权、允许用在哪里？", text: $assetAuthorization)
            }
            TextField("补充关键词（可不填）", text: $assetTags)
            Text("文件名会用于找画面；别人的素材仍要保留授权依据。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { showingAsset = false }; Button("保存素材") {
                let rights = assetSource == "self" ? "用户确认：本人制作" : "用户确认：已获授权；\(assetAuthorization)"
                if let assetURL { store.addAsset(url: assetURL, tags: assetTags, rights: rights) }
                if !store.catalog.assets.isEmpty, store.catalog.assets.first?.path == assetURL?.path {
                    if let asset = store.catalog.assets.first {
                        if project.visual_mode == "recording" {
                            for index in project.scenes.indices where project.scenes[index].asset_id == nil {
                                project.scenes[index].asset_id = asset.id
                            }
                        } else if let index = project.scenes.firstIndex(where: { $0.asset_id == nil }) {
                            project.scenes[index].asset_id = asset.id
                        }
                        saveChanges()
                    }
                    showingAsset = false; self.assetURL = nil; assetTags = ""; assetSource = ""; assetAuthorization = ""
                }
            }.buttonStyle(.borderedProminent)
                .disabled(assetURL == nil || assetSource.isEmpty || (assetSource == "authorized" && assetAuthorization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)) }
        }.textFieldStyle(.roundedBorder).padding(26).frame(width: 520)
    }

    private func stageTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    private func field(_ title: String, text: Binding<String>, hint: String = "") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            TextField(hint.isEmpty ? title : hint, text: text).textFieldStyle(.roundedBorder)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func binding(_ key: WritableKeyPath<VideoProject, String>) -> Binding<String> {
        Binding(get: { project[keyPath: key] }, set: { project[keyPath: key] = $0 })
    }
    private func sceneBinding<T>(_ index: Int, _ key: WritableKeyPath<VideoScene, T>) -> Binding<T> {
        Binding(get: { project.scenes[index][keyPath: key] }, set: { project.scenes[index][keyPath: key] = $0 })
    }
    private func sceneAssetBinding(_ index: Int) -> Binding<String> {
        Binding(get: { project.scenes[index].asset_id ?? "" }, set: { project.scenes[index].asset_id = $0.isEmpty ? nil : $0 })
    }
    private func sceneCropBinding(_ index: Int) -> Binding<String> {
        let presets: [String: [Double]] = ["browser": [0, 0.28, 1, 0.61], "left": [0.03, 0.38, 0.43, 0.50], "right": [0.48, 0.38, 0.49, 0.50]]
        return Binding(get: {
            guard let crop = project.scenes[index].source_crop else { return "full" }
            return presets.first { $0.value == crop }?.key ?? "custom"
        }, set: { key in
            if key != "custom" { project.scenes[index].source_crop = presets[key] }
        })
    }
    private func sceneStartBinding(_ index: Int) -> Binding<String> {
        Binding(get: { project.scenes[index].sync_start_seconds.map { String($0) } ?? "" },
                set: { project.scenes[index].sync_start_seconds = Double($0) })
    }
    private func selectCurrent() {
        if let selected = store.selectedProject { project = selected; detail = "" }
    }
    private func createProject() {
        guard !store.isLoading else { return }
        guard store.mounted() else { detail = "先连接外接盘资料。"; return }
        guard saveChanges() else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        store.addProject("新视频｜\(formatter.string(from: Date()))")
        stage = .words
    }
    @discardableResult private func saveChanges() -> Bool {
        guard !store.isLoading else { return false }
        guard store.selectedProject != nil else { return true }
        store.update(project)
        if let current = store.selectedProject { project = current }
        detail = store.message
        return !store.hasUnsavedChanges
    }
    private var selectedWorkflow: VideoWorkflow? {
        WorkflowLibrary.selected(for: project, in: store.workflows)
    }
    private var readiness: ProductionReadiness {
        ProductionReadiness(project: project, assets: store.catalog.assets, workflow: selectedWorkflow)
    }
    private func startProduction() {
        if project.workflow_id.isEmpty, let candidate = store.workflows.filter({ $0.canGenerate }).max(by: {
            $0.recommendationScore(idea: project.idea, goal: project.production_goal) < $1.recommendationScore(idea: project.idea, goal: project.production_goal)
        }) {
            project.workflow_id = candidate.id; project.visual_mode = candidate.engine
        }
        if project.scenes.isEmpty { generateDraft() }
        else if !readiness.missingScenes.isEmpty { detail = readiness.next; stage = .picture }
        else if !readiness.audioAvailable { detail = readiness.next; stage = .voice }
        else { render() }
    }
    private func renumberScenes() {
        for index in project.scenes.indices { project.scenes[index].step = index + 1 }
        saveChanges()
    }
    private func addScene() {
        guard project.scenes.count < 12 else { return }
        project.scenes.append(.blank(project.scenes.count + 1)); saveChanges()
    }
    private func matchAssets() {
        var matched = 0
        for index in project.scenes.indices {
            let scene = project.scenes[index]
            if let asset = store.matchAsset(for: "\(scene.title) \(scene.body) \(scene.highlight)", imagesOnly: project.visual_mode == "screenshot") {
                project.scenes[index].asset_id = asset.id; matched += 1
            }
        }
        saveChanges()
        detail = "已匹配 \(matched) 段素材；缺的镜头已列出，导入后再生成。"
    }
    private func chooseAsset() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video, .image]
        if panel.runModal() == .OK { assetURL = panel.url; showingAsset = true }
    }
    private func connectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择此文件夹"
        panel.message = "请选择外接盘上的视频资料文件夹。"
        panel.directoryURL = WorkbenchStore.work
        if panel.runModal() == .OK, let url = panel.url { store.connect(url) }
    }
    private func chooseAudio() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let hash = try WorkbenchEngine.digest(url)
                project.audio_path = url.path
                project.audio_script_signature = WorkbenchEngine.scriptSignature(project.script)
                project.audio_content_signature = hash
                saveChanges()
            } catch { detail = "音轨未确认：\(error.localizedDescription)" }
        }
    }
    private func generateDraft() {
        guard !store.isLoading else { return }
        guard store.mounted() else { detail = "先连接外接盘"; return }
        guard !project.idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { detail = "先写一句这期的想法。"; return }
        guard saveChanges() else { return }; store.isBusy = true; detail = "Luna 正在写初稿…"
        let snapshot = project
        let benchmark = store.catalog.benchmarks.first { $0.id == snapshot.benchmark_id }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try WorkbenchEngine.generateDraft(project: snapshot, benchmark: benchmark) }
            DispatchQueue.main.async {
                store.isBusy = false
                switch result {
                case .success(let draft):
                    if project.title.hasPrefix("新视频｜") { project.title = draft.title }
                    project.audience = draft.audience
                    project.problem = draft.problem
                    project.product = draft.product
                    project.script = draft.script
                    project.scenes = draft.scenes.enumerated().map { index, item in
                        var scene = VideoScene.blank(index + 1)
                        scene.title = item.title; scene.body = item.body; scene.highlight = item.highlight
                        scene.narration = item.narration
                        if project.visual_mode == "whiteboard" {
                            scene.layout = item.layout ?? "statement"; scene.items = item.items ?? []
                        }
                        return scene
                    }
                    for index in project.scenes.indices {
                        let scene = project.scenes[index]
                        project.scenes[index].asset_id = store.matchAsset(for: "\(scene.title) \(scene.body) \(scene.highlight)", imagesOnly: project.visual_mode == "screenshot")?.id
                    }
                    if project.voice_id.isEmpty { project.voice_id = store.recommendVoice(for: project).0?.id ?? "" }
                    project.phase = "初稿待确认"; saveChanges()
                    detail = "初稿、画面方案和建议音色已存好；先核对文案事实。"
                case .failure(let error): detail = "初稿没生成：\(error.localizedDescription)"
                }
            }
        }
    }
    private func render() {
        guard !store.isLoading else { return }
        guard store.mounted() else { detail = "先连接外接盘"; return }
        guard saveChanges() else { return }; store.isBusy = true; detail = "正在生成画面…"
        let snapshot = project
        let assets = store.catalog.assets
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try WorkbenchEngine.render(project: snapshot, assets: assets) }
            DispatchQueue.main.async {
                store.isBusy = false
                switch result {
                case .success(let output):
                    project.output = output.path
                    project.output_bundle = output.deletingLastPathComponent().path
                    if let data = try? Data(contentsOf: output.deletingLastPathComponent().appendingPathComponent("素材与时码manifest.json")),
                       let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        project.output_signature = manifest["input_signature"] as? String ?? ""
                        project.output_complete = manifest["components_complete"] as? Bool ?? false
                    }
                    project.phase = snapshot.audio_path.isEmpty ? "无声画面待审" : "带配音待审"
                    saveChanges(); detail = "已生成待审片：\(output.lastPathComponent)"
                case .failure(let error): detail = error.localizedDescription
                }
            }
        }
    }

    private func generateAudio() {
        guard !store.isLoading else { return }
        guard store.mounted() else { detail = "先连接外接盘"; return }
        guard let chosen = store.voices.first(where: { $0.id == project.voice_id }) else {
            detail = "先选一款音色。"; return
        }
        guard saveChanges() else { return }; store.isBusy = true; detail = "正在用本地音色生成配音；完成后请试听。"
        let snapshot = project
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try WorkbenchEngine.synthesize(project: snapshot, voice: chosen) }
            DispatchQueue.main.async {
                store.isBusy = false
                switch result {
                case .success(let audio):
                    project.audio_path = audio.path
                    project.audio_script_signature = WorkbenchEngine.scriptSignature(snapshot.script)
                    project.audio_content_signature = (try? WorkbenchEngine.digest(audio)) ?? ""
                    project.phase = "配音待试听"; saveChanges()
                    detail = "配音已生成。先听一遍短语和停顿，再合成画面。"
                case .failure(let error): detail = "配音没生成：\(error.localizedDescription)"
                }
            }
        }
    }
}
