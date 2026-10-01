import Foundation
import SwiftUI
import Darwin

struct VideoScene: Codable, Identifiable, Hashable {
    var step: Int
    var layout: String
    var kicker: String?
    var title: String
    var body: String
    var highlight: String
    var items: [String]
    var duration_seconds: Double
    var sync_phrase: String
    var sync_start_seconds: Double?
    var asset_id: String?
    var narration: String?
    var source_start_seconds: Double?
    var focus: [Double]?
    var source_crop: [Double]?
    var comparison_asset_id: String?
    var comparison_start_seconds: Double?
    var comparison_crop: [Double]?
    var left_label: String?
    var right_label: String?
    var id: Int { step }

    static func blank(_ step: Int) -> VideoScene {
        VideoScene(step: step, layout: step == 1 ? "hero" : "statement", kicker: nil,
                   title: "", body: "", highlight: "", items: [], duration_seconds: 5,
                   sync_phrase: "", sync_start_seconds: nil, asset_id: nil)
    }
}

struct VideoProject: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var audience: String
    var problem: String
    var platform: String
    var script: String
    var scenes: [VideoScene]
    var benchmark_id: String
    var voice_id: String
    var audio_path: String
    var phase: String
    var output: String
    var updated_at: String
    var product: String?
    var idea: String
    var visual_mode: String
    var frame_format: String
    var is_example: Bool
    var workflow_id: String = ""
    var production_goal: String = "polished"
    var output_signature: String = ""
    var output_complete: Bool = false
    var output_bundle: String = ""
    var audio_script_signature: String = ""
    var audio_content_signature: String = ""

    enum CodingKeys: String, CodingKey {
        case id, title, audience, problem, platform, script, scenes, benchmark_id,
             voice_id, audio_path, phase, output, updated_at, product, idea, visual_mode, frame_format, is_example,
             workflow_id, production_goal, output_signature, output_complete, output_bundle, audio_script_signature, audio_content_signature
    }

    init(id: String, title: String, audience: String, problem: String, platform: String,
         script: String, scenes: [VideoScene], benchmark_id: String, voice_id: String,
         audio_path: String, phase: String, output: String, updated_at: String, product: String?, idea: String,
         visual_mode: String = "recording", frame_format: String = "auto", is_example: Bool = false) {
        self.id = id; self.title = title; self.audience = audience; self.problem = problem
        self.platform = platform; self.script = script; self.scenes = scenes
        self.benchmark_id = benchmark_id; self.voice_id = voice_id; self.audio_path = audio_path
        self.phase = phase; self.output = output; self.updated_at = updated_at; self.product = product
        self.idea = idea
        self.visual_mode = visual_mode; self.frame_format = frame_format; self.is_example = is_example
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        audience = try values.decodeIfPresent(String.self, forKey: .audience) ?? ""
        problem = try values.decodeIfPresent(String.self, forKey: .problem) ?? ""
        platform = try values.decodeIfPresent(String.self, forKey: .platform) ?? "抖音"
        script = try values.decodeIfPresent(String.self, forKey: .script) ?? ""
        scenes = try values.decodeIfPresent([VideoScene].self, forKey: .scenes) ?? []
        benchmark_id = try values.decodeIfPresent(String.self, forKey: .benchmark_id) ?? ""
        voice_id = try values.decodeIfPresent(String.self, forKey: .voice_id) ?? ""
        audio_path = try values.decodeIfPresent(String.self, forKey: .audio_path) ?? ""
        phase = try values.decodeIfPresent(String.self, forKey: .phase) ?? "准备中"
        output = try values.decodeIfPresent(String.self, forKey: .output) ?? ""
        updated_at = try values.decodeIfPresent(String.self, forKey: .updated_at) ?? ""
        product = try values.decodeIfPresent(String.self, forKey: .product)
        idea = try values.decodeIfPresent(String.self, forKey: .idea) ?? ""
        visual_mode = try values.decodeIfPresent(String.self, forKey: .visual_mode) ?? "recording"
        frame_format = try values.decodeIfPresent(String.self, forKey: .frame_format) ?? "auto"
        is_example = try values.decodeIfPresent(Bool.self, forKey: .is_example) ?? false
        workflow_id = try values.decodeIfPresent(String.self, forKey: .workflow_id) ?? ""
        production_goal = try values.decodeIfPresent(String.self, forKey: .production_goal) ?? "polished"
        output_signature = try values.decodeIfPresent(String.self, forKey: .output_signature) ?? ""
        output_complete = try values.decodeIfPresent(Bool.self, forKey: .output_complete) ?? false
        output_bundle = try values.decodeIfPresent(String.self, forKey: .output_bundle) ?? ""
        audio_script_signature = try values.decodeIfPresent(String.self, forKey: .audio_script_signature) ?? ""
        audio_content_signature = try values.decodeIfPresent(String.self, forKey: .audio_content_signature) ?? ""
    }

    static func blank(title: String) -> VideoProject {
        VideoProject(id: String(UUID().uuidString.prefix(12)).lowercased(), title: title,
                     audience: "", problem: "", platform: "抖音", script: "", scenes: [],
                     benchmark_id: "", voice_id: "", audio_path: "", phase: "准备中",
                     output: "", updated_at: DateFormatter.workbench.string(from: Date()), product: "", idea: "")
    }
}

struct VideoBenchmark: Codable, Identifiable {
    var id: String
    var title: String
    var url: String
    var creator: String
    var why: String
    var structure: String
    var created_at: String
}

struct VideoAsset: Codable, Identifiable {
    var id: String
    var title: String
    var path: String
    var tags: String
    var rights: String
    var project_id: String?
    var created_at: String
}

struct VoiceProfile: Codable, Identifiable {
    var voice_id: String
    var name: String
    var category: String?
    var region_style: String?
    var status: String?
    var recommended_for: [String]?
    var profile: String?
    var id: String { voice_id }
}

struct WorkbenchCatalog: Codable {
    var schema: Int
    var projects: [VideoProject]
    var benchmarks: [VideoBenchmark]
    var assets: [VideoAsset]
}

extension DateFormatter {
    static let workbench: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return format
    }()
}

@MainActor final class WorkbenchStore: ObservableObject {
    @Published var catalog = WorkbenchCatalog(schema: 1, projects: [], benchmarks: [], assets: [])
    @Published var voices: [VoiceProfile] = []
    @Published var message = ""
    @Published var isBusy = false
    @Published private(set) var isLoading = false
    @Published var selectedID = ""
    @Published private(set) var verifiedMount = false
    @Published var workflows: [VideoWorkflow] = []
    private(set) var hasUnsavedChanges = false

    nonisolated static let volume = URL(fileURLWithPath: "/Volumes/Obsidian知识库", isDirectory: true)
    nonisolated static let work = volume.appendingPathComponent("Codex工作运行/10_视频进行中/口播制作", isDirectory: true)
    nonisolated static let dataURL = work.appendingPathComponent("项目资料.json")
    nonisolated static let voiceURL = work.appendingPathComponent("音色列表.json")
    nonisolated static let markerURL = work.appendingPathComponent(".creator-video-volume.json")
    nonisolated static let expectedUUID = "B3E5063B-1F8A-32A4-9864-FA421DC7C9EC"

    private var selectedFolder: URL?
    private var loadRequest = 0
    private var editRevision = 0
    private let snapshotReader: @Sendable () throws -> (WorkbenchCatalog, [VoiceProfile])

    init(snapshotReader: (@Sendable () throws -> (WorkbenchCatalog, [VoiceProfile]))? = nil,
         automaticallyLoad: Bool = true) {
        self.snapshotReader = snapshotReader ?? { try Self.readSnapshot() }
        message = "首次使用，请选择这款工具在外接盘上的资料文件夹。"
        do { workflows = try WorkflowLibrary.read() }
        catch { message = "制作流程没读到：\(error.localizedDescription)" }
        if automaticallyLoad && (UserDefaults.standard.bool(forKey: "creatorVideoFolderSelected") || FileManager.default.fileExists(atPath: Self.markerURL.path)) { load() }
    }

    func connect(_ folder: URL) {
        guard folder.standardizedFileURL.path == Self.work.standardizedFileURL.path else {
            message = "请选择“口播制作”资料文件夹。"
            return
        }
        selectedFolder?.stopAccessingSecurityScopedResource()
        _ = folder.startAccessingSecurityScopedResource()
        selectedFolder = folder
        UserDefaults.standard.set(true, forKey: "creatorVideoFolderSelected")
        load()
    }

    nonisolated private static func realMount() -> Bool {
        var info = statfs()
        guard statfs(volume.path, &info) == 0 else { return false }
        let mountedAt = withUnsafePointer(to: &info.f_mntonname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
        }
        return mountedAt == volume.path
    }

    func mounted() -> Bool {
        verifiedMount && Self.realMount()
    }

    func load() {
        guard !isLoading, !isBusy else { return }
        if hasUnsavedChanges {
            if !save() { return }
        }
        message = "正在读取外接盘资料…"
        isLoading = true
        loadRequest += 1
        let request = loadRequest
        let revision = editRevision
        let reader = snapshotReader
        Task.detached(priority: .userInitiated) {
            let result = Result { try reader() }
            await MainActor.run {
                guard request == self.loadRequest else { return }
                self.isLoading = false
                guard revision == self.editRevision, !self.hasUnsavedChanges else {
                    self.message = "读取期间资料已有更新，保留当前编辑；请稍后重新读取。"
                    return
                }
                switch result {
                case .success(let snapshot):
                    self.catalog = snapshot.0
                    self.voices = snapshot.1
                    if !snapshot.0.projects.contains(where: { $0.id == self.selectedID }) {
                        self.selectedID = snapshot.0.projects.first(where: { !$0.is_example })?.id ?? snapshot.0.projects.first(where: { $0.phase != "已退回" })?.id ?? ""
                    }
                    self.verifiedMount = true
                    self.message = ""
                    self.receiveSelectedAssets()
                case .failure(let error):
                    self.verifiedMount = false
                    self.message = "外接盘资料没读到：\(error.localizedDescription)"
                }
            }
        }
    }

    nonisolated private static func readSnapshot() throws -> (WorkbenchCatalog, [VoiceProfile]) {
        guard realMount() else {
            throw NSError(domain: "镜头工位", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先连接“Obsidian知识库”外接盘。"])
        }
        let markerData = try Data(contentsOf: markerURL)
        let marker = try JSONSerialization.jsonObject(with: markerData) as? [String: String] ?? [:]
        guard marker["volume_uuid"] == expectedUUID else {
            throw NSError(domain: "镜头工位", code: 2, userInfo: [NSLocalizedDescriptionKey: "外接盘身份不符，已停止读取。"])
        }
        let catalog = FileManager.default.fileExists(atPath: dataURL.path)
            ? try JSONDecoder().decode(WorkbenchCatalog.self, from: Data(contentsOf: dataURL))
            : WorkbenchCatalog(schema: 1, projects: [], benchmarks: [], assets: [])
        var voices: [VoiceProfile] = []
        if let data = try? Data(contentsOf: voiceURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = root["voices"] as? [[String: Any]],
           let serialized = try? JSONSerialization.data(withJSONObject: list),
           let decoded = try? JSONDecoder().decode([VoiceProfile].self, from: serialized) {
            voices = decoded
        }
        return (catalog, voices)
    }

    @discardableResult func save() -> Bool {
        guard !isLoading else { message = "正在读取资料，请读完后再保存。"; return false }
        editRevision += 1
        hasUnsavedChanges = true
        guard mounted() else { message = "外接盘没有连接，已停止保存。"; return false }
        do {
            try FileManager.default.createDirectory(at: Self.work, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(catalog).write(to: Self.dataURL, options: .atomic)
            hasUnsavedChanges = false
            message = "已保存到外接盘"
            return true
        } catch { message = "保存失败：\(error.localizedDescription)"; return false }
    }

    var selectedProject: VideoProject? { catalog.projects.first { $0.id == selectedID } }

    func update(_ project: VideoProject) {
        guard !isLoading else { message = "正在读取资料，暂不能编辑。"; return }
        guard let index = catalog.projects.firstIndex(where: { $0.id == project.id }) else { return }
        var copy = project
        if !copy.output.isEmpty, !copy.output_signature.isEmpty,
           copy.output_signature != WorkbenchEngine.renderSignature(project: copy, assets: catalog.assets) {
            copy.phase = "旧视频已过期"
            copy.output_complete = false
        } else if !copy.output.isEmpty && copy.output_signature.isEmpty {
            copy.phase = "旧视频需重新生成"
            copy.output_complete = false
        } else if !copy.output.isEmpty && copy.phase == "旧视频已过期" {
            copy.phase = copy.audio_path.isEmpty ? "无声画面待审" : "带配音待审"
            copy.output_complete = !copy.script.isEmpty && !copy.script.contains("【待补") &&
                !copy.audio_path.isEmpty && (try? WorkbenchEngine.validateApprovedAudio(copy)) != nil
        }
        copy.updated_at = DateFormatter.workbench.string(from: Date())
        catalog.projects[index] = copy
        save()
    }

    func addProject(_ title: String) {
        guard !isLoading else { return }
        guard mounted() else { message = "外接盘还没读好，先不要新建。"; return }
        let p = VideoProject.blank(title: title)
        catalog.projects.insert(p, at: 0)
        selectedID = p.id
        save()
    }

    func addBenchmark(title: String, url: String, creator: String, why: String, structure: String) {
        guard !isLoading else { return }
        guard let parsed = URL(string: url), ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""), !title.isEmpty else {
            message = "请填写对标名称和有效网页链接"
            return
        }
        catalog.benchmarks.insert(VideoBenchmark(id: UUID().uuidString, title: title, url: url,
                                                 creator: creator, why: why, structure: structure,
                                                 created_at: DateFormatter.workbench.string(from: Date())), at: 0)
        save()
    }

    func addAsset(url: URL, tags: String, rights: String) {
        guard !isLoading else { return }
        guard FileManager.default.fileExists(atPath: url.path), !rights.trimmingCharacters(in: .whitespaces).isEmpty else {
            message = "素材文件或使用范围缺失"
            return
        }
        catalog.assets.insert(VideoAsset(id: UUID().uuidString, title: url.deletingPathExtension().lastPathComponent,
                                         path: url.path, tags: tags, rights: rights, project_id: selectedID,
                                         created_at: DateFormatter.workbench.string(from: Date())), at: 0)
        save()
    }

    func recommendVoice(for project: VideoProject) -> (VoiceProfile?, String) {
        let context = "\(project.platform) \(project.title) \(project.audience) \(project.script)"
        if context.localizedCaseInsensitiveContains("TikTok") || context.localizedCaseInsensitiveContains("YouTube") || context.contains("英文") {
            return (voices.first { $0.name == "英文音色" }, "本期面向英文平台；首次使用前先试听。")
        }
        if context.contains("出海") && context.contains("B站") {
            return (voices.first { $0.name == "仇哥" }, "公司出海、B站内容有已保存的仇哥工作流。")
        }
        if context.contains("工具") || context.contains("产品") || context.contains("教程") {
            return (voices.first { $0.name == "小宁子" }, "工具讲解需要清楚又有个人感；这款音色需先试听本期稿。")
        }
        return (voices.first { $0.name == "台湾 Kelly" }, "本期偏自然分享；使用前仍要听完整短样。")
    }

    func matchAsset(for text: String, imagesOnly: Bool = false) -> VideoAsset? {
        let terms = text.lowercased()
        let ranked = catalog.assets.compactMap { asset -> (VideoAsset, Int)? in
            guard FileManager.default.fileExists(atPath: asset.path), !asset.rights.isEmpty else { return nil }
            if imagesOnly && !VideoWorkflow.isImage(asset.path) { return nil }
            let tags = (asset.tags + "," + asset.title).split(whereSeparator: { ",，、 /".contains($0) })
            let score = tags.filter { $0.count >= 2 && terms.contains($0.lowercased()) }.count
            return score > 0 ? (asset, score) : nil
        }
        return ranked.max { $0.1 < $1.1 }?.0
    }
}
