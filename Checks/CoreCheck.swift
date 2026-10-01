import Foundation

@main struct CoreCheck {
    @MainActor static func main() throws {
        let catalog = try JSONDecoder().decode(WorkbenchCatalog.self, from: Data(contentsOf: WorkbenchStore.dataURL))
        var project = catalog.projects.first { $0.id == "sample-recording" }!
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "Check", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            print("PASS " + message)
        }
        func rejects(_ message: String, _ body: () throws -> Void) throws {
            do { try body() } catch { print("PASS " + message + ": " + error.localizedDescription); return }
            throw NSError(domain: "Check", code: 2, userInfo: [NSLocalizedDescriptionKey: "未拦截：" + message])
        }
        try require(project.workflow_id.isEmpty, "旧JSON缺新字段可加载")
        let signature = WorkbenchEngine.renderSignature(project: project, assets: catalog.assets)
        project.output_signature = signature
        try require(ProductionReadiness(project: project, assets: catalog.assets, workflow: nil).currentOutput, "旧样片附当前签名后可识别")
        project.idea += "改稿"
        try require(!ProductionReadiness(project: project, assets: catalog.assets, workflow: nil).currentOutput, "输入变化令视频过期")
        project.script = "手改新文案"
        try rejects("稿件与字幕不一致") { _ = try WorkbenchEngine.mediaPlan(project: project, assets: catalog.assets, workflow: nil) }
        project.script = ""
        project.visual_mode = "comparison"
        try rejects("对比缺右素材") { _ = try WorkbenchEngine.mediaPlan(project: project, assets: catalog.assets, workflow: nil) }
        project.scenes[0].comparison_asset_id = project.scenes[0].asset_id
        try rejects("对比同素材") { _ = try WorkbenchEngine.mediaPlan(project: project, assets: catalog.assets, workflow: nil) }
        project.visual_mode = "screenshot"
        try rejects("截图输入视频") { _ = try WorkbenchEngine.mediaPlan(project: project, assets: catalog.assets, workflow: nil) }
        project.visual_mode = "recording"; project.production_goal = "batch"
        let plan = try WorkbenchEngine.mediaPlan(project: project, assets: catalog.assets, workflow: nil)
        try require(plan["fps"] as? Int == 15, "快产使用15帧")
        project.production_goal = "polished"
        try require(try WorkbenchEngine.mediaPlan(project: project, assets: catalog.assets, workflow: nil)["fps"] as? Int == 30, "精修使用30帧")
        project.scenes[0].sync_start_seconds = 1
        try rejects("音轨锚点不完整") { _ = try WorkbenchEngine.mediaPlan(project: project, assets: catalog.assets, workflow: nil, audioDuration: 12) }
        project.audio_path = "/不存在/音轨.wav"
        try require(!ProductionReadiness(project: project, assets: catalog.assets, workflow: nil).audioAvailable, "缺音轨指向下一步")
        project.audio_path = catalog.assets.first!.path
        project.audio_script_signature = WorkbenchEngine.scriptSignature(project.script)
        project.script = "音轨已录好后又改稿"
        try require(!ProductionReadiness(project: project, assets: catalog.assets, workflow: nil).audioAvailable, "改稿令已有音轨需要重新确认")
        let unloaded = WorkbenchStore(automaticallyLoad: false)
        try require(!unloaded.save() && unloaded.hasUnsavedChanges, "资料未读好时保存失败仍保留未保存状态")
    }
}
