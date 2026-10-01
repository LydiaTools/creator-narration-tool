import Foundation
@main struct WhiteboardCheck {
    @MainActor static func main() throws {
        let catalog = try JSONDecoder().decode(WorkbenchCatalog.self, from: Data(contentsOf: WorkbenchStore.dataURL))
        var project = catalog.projects.first { $0.id == "sample-whiteboard" }!
        let root = URL(fileURLWithPath: "/Users/macmini/Developer/creator-video-workbench/NativeApp/Resources")
        let workflow = try WorkflowLibrary.read(folder: root).first { $0.id == "whiteboard-map" }!
        project.id = "whiteboard-fix-native"; project.title = "白板修复同内容短样"
        project.visual_mode = "whiteboard"; project.workflow_id = workflow.id
        project.frame_format = "vertical"; project.script = ""; project.audio_path = ""
        project.scenes = [project.scenes[1], project.scenes[3]]
        for i in project.scenes.indices {
            project.scenes[i].duration_seconds = 5; project.scenes[i].narration = ""
            project.scenes[i].asset_id = nil; project.scenes[i].sync_start_seconds = nil
        }
        project.scenes[0].narration = ""; project.scenes[0].asset_id = nil
        project.scenes[0].sync_start_seconds = nil
        let plan = try WorkbenchEngine.mediaPlan(project: project, assets: [], workflow: workflow)
        guard plan["fps"] as? Int == 30,
              ProductionReadiness(project: project, assets: [], workflow: workflow).missingScenes.isEmpty,
              workflow.canGenerate else { fatalError("白板路线未接通") }
        print("PASS 白板无素材可独立生成关系示意，30fps")
        var invalid = project; invalid.script = "字幕不一致"
        do { _ = try WorkbenchEngine.mediaPlan(project: invalid, assets: [], workflow: workflow); fatalError("稿件保护失效") } catch { print("PASS 保留稿件逐段一致性保护") }
        invalid = project; invalid.scenes[0].title = String(repeating: "字", count: 19)
        do { _ = try WorkbenchEngine.mediaPlan(project: invalid, assets: [], workflow: workflow); fatalError("白板文字超长未拦截") } catch { print("PASS 超长文字先阻止，避免静默裁切") }
        invalid = project; invalid.audio_path = "/不存在/音轨.wav"
        do { _ = try WorkbenchEngine.render(project: invalid, assets: [], resourceFolder: root); fatalError("错误音轨未拦截") } catch { print("PASS 白板同样先核验批准音轨") }
        let folder = URL(fileURLWithPath: "/Volumes/Obsidian知识库/Codex工作运行/10_视频进行中/口播制作/白板修复-2026-10-01")
        let result = try WorkbenchEngine.render(project: project, assets: [], resourceFolder: root, outputRoot: folder)
        print("PASS 原生一键相同引擎完整运行：" + result.path)
        try JSONEncoder().encode(project).write(to: folder.appendingPathComponent("原生验收项目.json"))
    }
}
