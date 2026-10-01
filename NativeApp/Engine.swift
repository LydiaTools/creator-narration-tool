import Foundation
import CryptoKit
import NaturalLanguage

enum WorkbenchEngine {
    static let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: "/Users/macmini/Developer/creator-video-workbench/NativeApp/Resources")
    static let python = URL(fileURLWithPath: "/Users/macmini/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3")
    static let packages = "/Users/macmini/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/lib/python3.12/site-packages"
    static let ffmpeg = URL(fileURLWithPath: "/Users/macmini/bin/ffmpeg")
    static let ffprobe = URL(fileURLWithPath: "/Users/macmini/bin/ffprobe")
    static let codex = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")

    static func run(_ executable: URL, _ arguments: [String], at folder: URL, log: URL,
                    input: String? = nil, timeout: TimeInterval = 600,
                    environment: [String: String] = [:]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = output
        if let input {
            let pipe = Pipe()
            process.standardInput = pipe
            try process.run()
            pipe.fileHandleForWriting.write(Data(input.utf8))
            try pipe.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        let limit = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < limit { Thread.sleep(forTimeInterval: 0.2) }
        if process.isRunning { process.terminate(); process.waitUntilExit(); throw NSError(domain: "口播制作", code: 1, userInfo: [NSLocalizedDescriptionKey: "执行时间过长，已停止。详见项目运行记录。"]) }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let detail = (try? String(contentsOf: log, encoding: .utf8))?.suffix(700) ?? ""
            throw NSError(domain: "口播制作", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "处理失败：\(detail)"])
        }
    }

    static func duration(_ file: URL, folder: URL) throws -> Double {
        let log = folder.appendingPathComponent("时长检查.txt")
        try run(ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", file.path], at: folder, log: log, timeout: 30)
        return Double((try String(contentsOf: log, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func renderSignature(project: VideoProject, assets: [VideoAsset]) -> String {
        var input = project
        input.output = ""; input.output_signature = ""; input.output_bundle = ""
        input.output_complete = false; input.phase = ""; input.updated_at = ""
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var bytes = (try? encoder.encode(input)) ?? Data()
        let identifiers = Set(project.scenes.flatMap { [$0.asset_id, $0.comparison_asset_id].compactMap { $0 } })
        var paths = assets.filter { identifiers.contains($0.id) }.sorted { $0.id < $1.id }
            .map { "\($0.id)|\($0.path)|\($0.rights)" }
        paths.append(project.audio_path)
        for path in paths {
            bytes.append(Data(path.utf8))
        }
        for path in assets.filter({ identifiers.contains($0.id) }).map(\.path) + [project.audio_path] where !path.isEmpty {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            bytes.append(Data("\(attributes?[.size] ?? "missing")|\(attributes?[.modificationDate] ?? "missing")".utf8))
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func scriptSignature(_ script: String) -> String {
        SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func validateApprovedAudio(_ project: VideoProject) throws {
        guard !project.audio_content_signature.isEmpty,
              project.audio_script_signature == scriptSignature(project.script),
              (try? digest(URL(fileURLWithPath: project.audio_path))) == project.audio_content_signature else {
            throw NSError(domain: "口播制作", code: 9, userInfo: [NSLocalizedDescriptionKey: "音轨内容已变化，或旧音轨尚无确认哈希。请重新导入与当前稿件一致的配音，再合成。"])
        }
    }

    static func mediaPlan(project: VideoProject, assets: [VideoAsset], workflow: VideoWorkflow?,
                          audioDuration: Double? = nil) throws -> [String: Any] {
        if !project.script.isEmpty && project.scenes.map({ $0.narration ?? "" }).joined() != project.script {
            throw NSError(domain: "口播制作", code: 8, userInfo: [NSLocalizedDescriptionKey: "稿件与逐段字幕不一致。请在“调整镜头”修改每段口播并同步为本期稿，再生成。"])
        }
        guard !project.scenes.isEmpty, project.scenes.count <= 12,
              project.scenes.allSatisfy({ $0.duration_seconds.isFinite && $0.duration_seconds > 0 }) else {
            throw NSError(domain: "口播制作", code: 2, userInfo: [NSLocalizedDescriptionKey: "先生成有效镜头安排，最多 12 段。"])
        }
        guard ["recording", "montage", "screenshot", "comparison", "whiteboard"].contains(project.visual_mode),
              workflow?.canGenerate != false else {
            throw NSError(domain: "口播制作", code: 3, userInfo: [NSLocalizedDescriptionKey: "所选流程尚未接通本应用制作引擎。"])
        }
        let readiness = ProductionReadiness(project: project, assets: assets, workflow: workflow)
        guard readiness.missingScenes.isEmpty else {
            throw NSError(domain: "口播制作", code: 4, userInfo: [NSLocalizedDescriptionKey: readiness.next + (project.visual_mode == "comparison" ? "每段左右需要两份不同的授权素材。" : "")])
        }
        var durations = project.scenes.map(\.duration_seconds)
        if let total = audioDuration {
            guard total.isFinite && total > 0 else { throw NSError(domain: "口播制作", code: 5, userInfo: [NSLocalizedDescriptionKey: "配音文件无法读取。"] ) }
            let anchors = project.scenes.compactMap(\.sync_start_seconds)
            if !anchors.isEmpty {
                guard anchors.count == project.scenes.count, abs(anchors[0]) < 0.001,
                      anchors.allSatisfy({ $0.isFinite && $0 >= 0 }), (anchors.last ?? total) < total,
                      zip(anchors, anchors.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else {
                    throw NSError(domain: "口播制作", code: 6, userInfo: [NSLocalizedDescriptionKey: "画面起点需要全部填写，第一段从 0 开始，随后递增且不超过音轨时长。"])
                }
                durations = zip(anchors, Array(anchors.dropFirst()) + [total]).map { $0.1 - $0.0 }
            } else {
                durations = durations.map { $0 / durations.reduce(0, +) * total }
            }
        }
        var consumed: [String: Double] = [:]
        func source(_ asset: VideoAsset, explicitStart: Double?, crop: [Double]?) -> [String: Any] {
            let image = VideoWorkflow.isImage(asset.path)
            let start = explicitStart ?? (image ? 0 : consumed[asset.id, default: 0])
            var row: [String: Any] = ["asset_id": asset.id, "path": asset.path, "start": start, "rights": asset.rights]
            if let crop { row["crop"] = crop }
            return row
        }
        var clips: [[String: Any]] = []
        for (index, scene) in project.scenes.enumerated() {
            if project.visual_mode == "whiteboard" {
                guard !scene.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      scene.title.count <= 18, scene.body.count <= 32, scene.highlight.count <= 24,
                      scene.items.count <= 4, scene.items.allSatisfy({ $0.count <= 12 }) else {
                    throw NSError(domain: "口播制作", code: 4, userInfo: [NSLocalizedDescriptionKey: "白板请用短句：标题最多18字、说明32字、结论24字；最多4个节点，每个12字。"])
                }
                clips.append(["scene_step": scene.step, "duration": durations[index],
                              "caption": scene.narration ?? "", "title": scene.title,
                              "body": scene.body, "highlight": scene.highlight,
                              "items": scene.items, "layout": scene.layout,
                              "kicker": scene.kicker ?? "关系讲解"])
                continue
            }
            let asset = assets.first { $0.id == scene.asset_id }!
            var row = source(asset, explicitStart: scene.source_start_seconds, crop: scene.source_crop)
            row["duration"] = durations[index]; row["caption"] = scene.narration ?? ""
            row["scene_step"] = scene.step; row["evidence_note"] = scene.body
            if let focus = scene.focus { row["focus"] = focus }
            if !VideoWorkflow.isImage(asset.path) { consumed[asset.id] = (row["start"] as! Double) + durations[index] }
            if let comparison = assets.first(where: { $0.id == scene.comparison_asset_id }),
               ["comparison", "screenshot"].contains(project.visual_mode) {
                var right = source(comparison, explicitStart: scene.comparison_start_seconds, crop: scene.comparison_crop)
                right["label"] = scene.right_label ?? "右侧"
                row["comparison"] = right; row["label"] = scene.left_label ?? "左侧"
                if !VideoWorkflow.isImage(comparison.path) { consumed[comparison.id] = (right["start"] as! Double) + durations[index] }
            }
            clips.append(row)
        }
        let suggested = workflow?.frame_recommendation ?? "platform"
        let horizontal = project.frame_format == "horizontal" || (project.frame_format == "auto" &&
            (suggested == "horizontal" || (suggested == "platform" && ["B站", "YouTube", "先做样片"].contains(project.platform))))
        return ["mode": project.visual_mode, "workflow_id": project.workflow_id, "production_goal": project.production_goal,
                "width": horizontal ? 1920 : 1080, "height": horizontal ? 1080 : 1920,
                "fps": project.visual_mode == "whiteboard" ? 30 : (project.production_goal == "batch" ? 15 : 30), "clips": clips]
    }

    static func render(project: VideoProject, assets: [VideoAsset], resourceFolder: URL = resources, outputRoot: URL = WorkbenchStore.work) throws -> URL {
        if !project.audio_path.isEmpty { try validateApprovedAudio(project) }
        let lease = try MediaResourceLease(destination: outputRoot)
        defer { lease.release() }
        let workflow = WorkflowLibrary.selected(for: project, in: try WorkflowLibrary.read(folder: resourceFolder))
        if !project.workflow_id.isEmpty && workflow == nil { throw NSError(domain: "口播制作", code: 30, userInfo: [NSLocalizedDescriptionKey: "当前流程资源缺失，请重新选择制作流程。"] ) }
        let base = outputRoot.appendingPathComponent("项目/\(project.id)/版本", isDirectory: true)
        let version = "v\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6))"
        let work = base.appendingPathComponent(version, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let audio = project.audio_path.isEmpty ? nil : URL(fileURLWithPath: project.audio_path)
        let audioSeconds = try audio.map { try duration($0, folder: work) }
        let plan = try mediaPlan(project: project, assets: assets, workflow: workflow, audioDuration: audioSeconds)
        let input = work.appendingPathComponent("镜头计划.json")
        try JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys]).write(to: input, options: .atomic)
        let output = work.appendingPathComponent(audio == nil ? "无声画面待审.mp4" : "画面中间稿.mp4")
        try run(python, ["-S", resourceFolder.appendingPathComponent(project.visual_mode == "whiteboard" ? "render_whiteboard.py" : "render_media.py").path, input.path,
                         "--output", output.path, "--ffmpeg", ffmpeg.path, "--ffprobe", ffprobe.path],
                at: work, log: work.appendingPathComponent("画面生成记录.txt"), timeout: 600,
                environment: ["PYTHONPATH": packages, "OMP_NUM_THREADS": "2"])
        var final = output
        if let audio {
            try validateApprovedAudio(project)
            final = work.appendingPathComponent("本版视频待审.mp4")
            try run(ffmpeg, ["-y", "-v", "error", "-threads", "2", "-i", output.path, "-i", audio.path,
                             "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                             "-shortest", "-movflags", "+faststart", final.path],
                    at: work, log: work.appendingPathComponent("配音合成记录.txt"), timeout: 120)
            try validateApprovedAudio(project)
            guard abs((try duration(final, folder: work)) - (audioSeconds ?? 0)) < 0.3 else {
                throw NSError(domain: "口播制作", code: 7, userInfo: [NSLocalizedDescriptionKey: "声画时长不一致，请检查音轨和镜头起点。"])
            }
        }
        let srt = work.appendingPathComponent("字幕.srt")
        try FileManager.default.copyItem(at: output.deletingPathExtension().appendingPathExtension("srt"), to: srt)
        try project.script.write(to: work.appendingPathComponent("口播稿.txt"), atomically: true, encoding: .utf8)
        try run(ffmpeg, ["-y", "-v", "error", "-threads", "2", "-i", final.path, "-frames:v", "1",
                         "-update", "1", work.appendingPathComponent("封面首帧.jpg").path],
                at: work, log: work.appendingPathComponent("封面生成记录.txt"), timeout: 30)
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: output.deletingPathExtension().appendingPathExtension("json"))) as? [String: Any] ?? [:]
        let complete = audio != nil && !project.script.isEmpty && !project.script.contains("【待补")
        manifest["version"] = version; manifest["title"] = project.title; manifest["workflow_id"] = project.workflow_id
        manifest["production_goal"] = project.production_goal; manifest["output"] = final.path
        manifest["input_signature"] = renderSignature(project: project, assets: assets)
        var audioRecord: [String: String] = [:]
        if let audio { audioRecord = ["path": audio.path, "sha256": try digest(audio)] }
        manifest["audio"] = audioRecord
        manifest["components_complete"] = complete
        manifest["review"] = "待用户完整视听审片；组件齐备不等于发布通过"
        manifest["missing"] = audio == nil ? ["本期配音"] : (complete ? [] : ["完整确认稿件"])
        manifest["subtitle_timing"] = "片内估算；人工校核声画逐句同步仍待完成"
        guard JSONSerialization.isValidJSONObject(manifest) else {
            throw NSError(domain: "口播制作", code: 15, userInfo: [NSLocalizedDescriptionKey: "审片清单格式无效，视频已保留，但未标记成功。"])
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: work.appendingPathComponent("素材与时码manifest.json"), options: .atomic)
        let note = "\(complete ? "组件齐备，待完整审片" : "画面候选，发布包未齐")\n版本：\(version)\n视频：\(final.lastPathComponent)\n字幕时间为片内估算，需试听逐句检查。封面是首帧，还可按平台精修。素材保留在manifest原路径，授权范围和来源时码已登记。\n"
        try note.write(to: work.appendingPathComponent("审片说明.txt"), atomically: true, encoding: .utf8)
        return final
    }

    struct GeneratedDraft: Decodable {
        var title: String
        var audience: String
        var problem: String
        var product: String
        var scenes: [DraftScene]
        var script: String { scenes.map { $0.narration }.joined() }
    }
    struct DraftScene: Decodable {
        var title: String; var body: String; var highlight: String; var narration: String
        var layout: String?; var items: [String]?
    }

    static func generateDraft(project: VideoProject, benchmark: VideoBenchmark?, resourceFolder: URL = resources) throws -> GeneratedDraft {
        let work = WorkbenchStore.work.appendingPathComponent("项目/\(project.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let output = work.appendingPathComponent("Luna初稿.json")
        let schema = resourceFolder.appendingPathComponent(project.visual_mode == "whiteboard" ? "whiteboard-draft.schema.json" : "draft.schema.json")
        let workflow = WorkflowLibrary.selected(for: project, in: try WorkflowLibrary.read(folder: resourceFolder))
        guard workflow?.canGenerate != false else { throw NSError(domain: "口播制作", code: 30, userInfo: [NSLocalizedDescriptionKey: "这条流程仍需外部工具，请选择已接通路线。"] ) }
        let goal = project.production_goal == "batch" ? "公司批量快产：先兑现一个具体收获，结构简洁、复用已授权素材，不牺牲事实" : "精品精修：用于B站/抖音，重点展示具体处境、过程、可核对结果，预留人工精修和审片；不保证超过优秀作品"
        let prompt = """
        你是中文口播文案编辑。根据用户的一句话想法，给这期视频取一个12字以内、具体好找的标题；再推断可能的目标观众、他们的具体问题、产品或办法，写一条约90至150字的工具类口播初稿，并拆为3到5个真实镜头段落。每段 narration 是口播稿连续的一部分，按顺序拼起来就是完整稿子；\(project.visual_mode == "whiteboard" ? "body 写清关系、因果或流程，以简短标题配关系图；白板是解释示意，不能当作产品已经实现的证据。" : "body 描述应录下或找到的真实动作与结果，不写成白板、标题卡或显示在视频里的解说说明。")每句话都要交代观众遇到的问题、具体动作或实际结果，删掉重复解释和空话。推断不等于事实；文案不能把尚未验证的功能、效果、数据或案例写成事实，缺的真实证据用【待补：具体证据】标记。AI 文案生成需联网调用 Codex，不可声称整个工具或流程完全离线。避免套话和照抄对标，文案要自然口语，短语内部不能断开。输出 title、audience、problem、product、scenes，全部符合 JSON schema。\n
        白板流程额外要求：只根据本期文字关系选择 flow、loop、compare、statement 或 hero；items 是最多4个真实关系节点，每个最多12字，loop 必须真有回返关系；其他流程无需输出这些字段。白板标题最多18字、body说明32字、highlight结论24字，不把口播全文堆进画布。\n本期生产目的：\(goal)\n所选流程：\(workflow?.title ?? project.visual_mode)\n必须采用的叙事结构：\(workflow?.script_structure.joined(separator: " → ") ?? "场景 → 具体动作 → 真实结果")\n画面引擎：\(project.visual_mode)，截图流程只能安排真实截图；对比流程每段需要两份独立来源的真实素材。不要编造素材、案例或对比结果。\n用户这一期的想法：\(project.idea)\n当前项目名称：\(project.title)\n已有材料（如有）：\(project.script)\n发布平台：\(project.platform)\n对标备注（若只有链接且没有内容，禁止猜测视频结构）：\(benchmark.flatMap { $0.structure.isEmpty ? nil : $0.structure } ?? "未提供视频内容")
        """
        let args = ["exec", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check", "-s", "read-only", "-m", "gpt-6-luna",
                    "-c", "model_reasoning_effort=\"low\"", "--output-schema", schema.path,
                    "-o", output.path, "-"]
        try run(codex, args, at: work, log: work.appendingPathComponent("文案生成记录.txt"), input: prompt, timeout: 180,
                environment: ["CODEX_HOME": "/Users/macmini/Library/Application Support/镜头工位/Codex"])
        return try JSONDecoder().decode(GeneratedDraft.self, from: Data(contentsOf: output))
    }

    static func synthesize(project: VideoProject, voice: VoiceProfile) throws -> URL {
        let lease = try MediaResourceLease(requiresLocalModel: true)
        defer { lease.release() }
        guard let profile = voice.profile else {
            throw NSError(domain: "口播制作", code: 10, userInfo: [NSLocalizedDescriptionKey: "这款音色还没有可直接生成的档案；可以导入现成配音。"])
        }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/memory_pressure")
        check.arguments = ["-Q"]
        let pipe = Pipe()
        check.standardOutput = pipe
        try check.run()
        check.waitUntilExit()
        let report = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let percentage = report.split(separator: "\n").first { $0.contains("memory free percentage") }
            .flatMap { line -> Int? in
                guard let value = line.split(separator: ":").last else { return nil }
                return Int(value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: ""))
            }
        guard let percentage, percentage >= 50 else {
            throw NSError(domain: "口播制作", code: 14, userInfo: [NSLocalizedDescriptionKey: "当前可用内存不足 50%，为了不影响你工作，已停止本地配音。稍后关掉占资源的应用再试，也可以导入已有配音。"])
        }
        guard FileManager.default.fileExists(atPath: profile) else {
            throw NSError(domain: "口播制作", code: 10, userInfo: [NSLocalizedDescriptionKey: "音色档案文件当前无法读取；请核对外接盘。"])
        }
        let script = project.script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty, script.count <= 400 else {
            throw NSError(domain: "口播制作", code: 11, userInfo: [NSLocalizedDescriptionKey: "先确认口播稿，单次配音最长 400 字。"])
        }
        let work = WorkbenchStore.work.appendingPathComponent("项目/\(project.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let source = work.appendingPathComponent("本期口播稿.txt")
        try script.write(to: source, atomically: true, encoding: .utf8)
        let isChinese = script.range(of: "[\\p{Han}]", options: .regularExpression) != nil
        let terms = readingTerms(script)
        guard !isChinese || !terms.isEmpty else {
            throw NSError(domain: "口播制作", code: 12, userInfo: [NSLocalizedDescriptionKey: "无法识别稿中的中文短语，请先检查文案。"])
        }
        let plan = work.appendingPathComponent("本期口播稿-读法.json")
        let hash = SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
        if isChinese {
            let entries = terms.map { ["term": $0, "instruction": "连读，不在词中停顿；按上下文自然表达"] }
            try JSONSerialization.data(withJSONObject: ["text_sha256": hash, "phrases": entries], options: [.prettyPrinted, .sortedKeys])
                .write(to: plan, options: .atomic)
        }
        let log = work.appendingPathComponent("配音生成记录.txt")
        var args = ["/Users/macmini/Developer/narration-voice/narrate.py", "--text-file", source.path,
                    "--profile", profile, "--output-dir", work.path]
        if isChinese { args += ["--reading-plan", plan.path] }
        try run(URL(fileURLWithPath: "/usr/bin/python3"), args,
                at: work, log: log, timeout: 900,
                environment: ["OMP_NUM_THREADS": "2", "OPENBLAS_NUM_THREADS": "2", "VECLIB_MAXIMUM_THREADS": "2"])
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        guard let line = lines.last(where: { $0.hasPrefix("{") }),
              let result = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let path = result["audio_path"] as? String,
              FileManager.default.fileExists(atPath: path) else {
            throw NSError(domain: "口播制作", code: 13, userInfo: [NSLocalizedDescriptionKey: "配音命令没有返回音频文件，请看运行记录。"])
        }
        return URL(fileURLWithPath: path)
    }

    private static func readingTerms(_ script: String) -> [String] {
        var terms: [String] = []
        for known in ["拼豆", "一人公司", "任务地图", "公司经验库", "口播视频", "Codex", "AI"] where script.contains(known) {
            terms.append(known)
        }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = script
        tokenizer.setLanguage(.simplifiedChinese)
        tokenizer.enumerateTokens(in: script.startIndex..<script.endIndex) { range, _ in
            let word = String(script[range])
            if word.count >= 2, word.count <= 8,
               word.range(of: "[\\p{Han}]", options: .regularExpression) != nil,
               !terms.contains(word) { terms.append(word) }
            return terms.count < 18
        }
        return Array(terms.prefix(18))
    }
}
