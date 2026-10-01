import Foundation

private final class DelayedSnapshot: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let snapshot: WorkbenchCatalog
    init(_ snapshot: WorkbenchCatalog) { self.snapshot = snapshot }
    func read() -> (WorkbenchCatalog, [VoiceProfile]) {
        entered.signal()
        release.wait()
        return (snapshot, [])
    }
}

@main struct RevisionProtectionCheck {
    @MainActor static func main() async throws {
        func require(_ value: Bool, _ label: String) throws {
            guard value else { throw NSError(domain: "Regression", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            print("PASS " + label)
        }
        var first = VideoProject.blank(title: "列表首项目")
        first.id = "first"
        var second = VideoProject.blank(title: "正在编辑的第二项目")
        second.id = "second"; second.idea = "已保存的想法"
        let catalog = WorkbenchCatalog(schema: 1, projects: [first, second], benchmarks: [], assets: [])
        let gate = DelayedSnapshot(catalog)
        let store = WorkbenchStore(snapshotReader: { gate.read() }, automaticallyLoad: false)
        store.catalog = catalog; store.selectedID = second.id
        store.load()
        try require(store.isLoading, "load发起即锁定加载状态")
        var edit = second; edit.idea = "读取未返回时尝试编辑"
        store.update(edit)
        try require(store.selectedProject?.idea == second.idea, "延迟读取期间编辑被拒绝，没有写入/覆盖窗口")
        try require(!store.save(), "加载期间保存被拒绝")
        gate.release.signal()
        for _ in 0..<1000 where store.isLoading { try await Task.sleep(nanoseconds: 1_000_000) }
        try require(!store.isLoading && store.selectedID == second.id, "真实异步回调结束后仍选择第二项目")
        try require(store.selectedProject?.idea == second.idea, "加载完成保留第二项目内容")
        enum ReadFailure: Error { case unavailable }
        let failed = WorkbenchStore(snapshotReader: { throw ReadFailure.unavailable }, automaticallyLoad: false)
        failed.catalog = catalog; failed.selectedID = second.id; failed.load()
        for _ in 0..<1000 where failed.isLoading { try await Task.sleep(nanoseconds: 1_000_000) }
        try require(!failed.isLoading && failed.selectedID == second.id && failed.catalog.projects == catalog.projects,
                    "异步读取失败不清空已有项目或切换选择")

        let folder = WorkbenchStore.work.appendingPathComponent("检查/0.2.1修复/音轨哈希试验")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("测试音轨内容.bin")
        try Data("approved".utf8).write(to: audio)
        var approved = second
        approved.script = "本期稿件"; approved.audio_path = audio.path
        approved.audio_script_signature = WorkbenchEngine.scriptSignature(approved.script)
        approved.audio_content_signature = try WorkbenchEngine.digest(audio)
        let persisted = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(approved))
        try WorkbenchEngine.validateApprovedAudio(persisted)
        try require(persisted.audio_content_signature == approved.audio_content_signature, "批准音轨哈希持久化后可核验")
        let attributes = try FileManager.default.attributesOfItem(atPath: audio.path)
        try Data("replaced".utf8).write(to: audio)
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: audio.path)
        try require(!ProductionReadiness(project: persisted, assets: [], workflow: nil).audioAvailable,
                    "同路径/同长度/保留mtime覆盖音轨仍失效")
        do {
            _ = try WorkbenchEngine.render(project: persisted, assets: [])
            throw NSError(domain: "Regression", code: 2)
        } catch let error as NSError {
            try require(error.domain == "口播制作" && error.code == 9, "合成入口在启动渲染前拒绝被覆盖音轨")
        }
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(approved)) as! [String: Any]
        legacy.removeValue(forKey: "audio_content_signature")
        let old = try JSONDecoder().decode(VideoProject.self, from: JSONSerialization.data(withJSONObject: legacy))
        try require(old.audio_content_signature.isEmpty && !ProductionReadiness(project: old, assets: [], workflow: nil).audioAvailable,
                    "旧档无音轨哈希要求重新确认，不猜测通过")
    }
}
