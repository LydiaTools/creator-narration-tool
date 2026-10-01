import Foundation

struct VideoWorkflow: Codable, Identifiable {
    var id: String
    var title: String
    var summary: String
    var engine: String
    var script_structure: [String]
    var frame_recommendation: String
    var source_paths: [String]
    var voice_hint: String?
    var availability: String
    var unavailable_reason: String?
    var preview_file: String
    var thumbnail_path: String
    var preview_status: String
    var production_goals: [String]
    var costs: WorkflowCosts
    var keywords: [String]?
    var genre: String?
    var min_inputs: [String]?
    var preview_scope: String?
    var quality_note: String?

    var canGenerate: Bool {
        availability == "ready" && ["recording", "montage", "screenshot", "comparison", "whiteboard"].contains(engine)
    }
    var previewLabel: String {
        switch preview_status {
        case "accepted": return "已审样片"
        case "voiced_candidate": return "带声候选 · 待审片"
        case "silent_candidate": return "无声画面试片 · 待审片"
        default: return "暂缺真实样片"
        }
    }
    static func isImage(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "webp"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
    func recommendationScore(idea: String, goal: String) -> Int {
        let terms = keywords ?? []
        return terms.filter { idea.localizedCaseInsensitiveContains($0) }.count * 3
            + (production_goals.contains(goal) ? 1 : 0)
    }
}

struct WorkflowCosts: Codable {
    var editing: String
    var writing: String
    var voice: String
    var video_model: String
    var time: String
}

enum WorkflowLibrary {
    struct Document: Decodable { var schema: Int; var workflows: [VideoWorkflow] }
    static func read(folder: URL = WorkbenchEngine.resources) throws -> [VideoWorkflow] {
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: folder.appendingPathComponent("workflows.json")))
        guard document.schema == 1, !document.workflows.isEmpty,
              Set(document.workflows.map(\.id)).count == document.workflows.count,
              document.workflows.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty && !$0.script_structure.isEmpty &&
                  ["horizontal", "vertical", "platform"].contains($0.frame_recommendation) &&
                  ["ready", "manual", "experiment"].contains($0.availability) }) else {
            throw NSError(domain: "口播制作", code: 30, userInfo: [NSLocalizedDescriptionKey: "流程资源格式不完整；请恢复应用的 workflows.json。"])
        }
        return document.workflows
    }
    static func selected(for project: VideoProject, in workflows: [VideoWorkflow]) -> VideoWorkflow? {
        workflows.first { $0.id == project.workflow_id }
    }
}

struct ProductionReadiness {
    var missingScenes: [Int]
    var audioAvailable: Bool
    var hasScenes: Bool
    var currentOutput: Bool
    var next: String

    init(project: VideoProject, assets: [VideoAsset], workflow: VideoWorkflow?) {
        hasScenes = !project.scenes.isEmpty
        audioAvailable = !project.audio_path.isEmpty && (try? WorkbenchEngine.validateApprovedAudio(project)) != nil
        missingScenes = project.visual_mode == "whiteboard" ? [] : project.scenes.compactMap { scene in
            func valid(_ id: String?) -> Bool {
                guard let asset = assets.first(where: { $0.id == id }) else { return false }
                return !asset.rights.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    FileManager.default.fileExists(atPath: asset.path) &&
                    (project.visual_mode != "screenshot" || VideoWorkflow.isImage(asset.path))
            }
            let primary = valid(scene.asset_id)
            let needsSecond = project.visual_mode == "comparison" ||
                (project.visual_mode == "screenshot" && scene.comparison_asset_id != nil)
            let comparison = !needsSecond ||
                (valid(scene.comparison_asset_id) && scene.asset_id != scene.comparison_asset_id)
            return primary && comparison ? nil : scene.step
        }
        currentOutput = !project.output.isEmpty && FileManager.default.fileExists(atPath: project.output) &&
            !project.output_signature.isEmpty &&
            project.output_signature == WorkbenchEngine.renderSignature(project: project, assets: assets)
        if let workflow, !workflow.canGenerate { next = workflow.unavailable_reason ?? "这条流程需要已有外部工具，暂未接通本应用生成。" }
        else if !hasScenes { next = project.script.isEmpty ? "输入一句想法，选流程开始生成稿件。" : "已有稿件；开始生成镜头安排。" }
        else if !missingScenes.isEmpty { next = "补齐第 \(missingScenes.map(String.init).joined(separator: "、")) 段真实素材。" }
        else if !audioAvailable { next = "导入已批准配音，或到“配声音”生成本期音轨。" }
        else if !currentOutput { next = "材料已齐，生成本版本视频与审片包。" }
        else { next = "播放本版本，检查实际声音、镜头和字幕。" }
    }
}
