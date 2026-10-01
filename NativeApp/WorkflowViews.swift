import SwiftUI
import AppKit

struct WorkflowGallery: View {
    @State private var showAll = false
    let workflows: [VideoWorkflow]
    let project: VideoProject
    let choose: (VideoWorkflow) -> Void

    private var ranked: [VideoWorkflow] {
        workflows.sorted {
            let left = $0.recommendationScore(idea: project.idea, goal: project.production_goal)
            let right = $1.recommendationScore(idea: project.idea, goal: project.production_goal)
            if left != right { return left > right }
            if $0.canGenerate != $1.canGenerate { return $0.canGenerate }
            return $0.id < $1.id
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("先看看怎么做").font(.system(size: 17, weight: .bold))
            Text("看真实效果，再选本期流程。素材和人工精修仍需要准备。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(showAll ? ranked : Array(ranked.prefix(3))) { workflow in
                VStack(alignment: .leading, spacing: 12) {
                    preview(workflow)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(workflow.title).font(.system(size: 16, weight: .semibold))
                            Text(workflow.availability == "ready" ? "已接通" : workflow.availability == "experiment" ? "实验" : "待接入")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Button(project.workflow_id == workflow.id ? "本期已选" : "选这条") { choose(workflow) }
                        }
                        Text(workflow.summary).font(.system(size: 13))
                        Text([workflow.previewLabel, workflow.preview_scope].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        if workflow.recommendationScore(idea: project.idea, goal: project.production_goal) > 1 {
                            Text("按想法关键词推荐：命中“\((workflow.keywords ?? []).filter { project.idea.localizedCaseInsensitiveContains($0) }.joined(separator: "、"))”；仍需核对素材。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("所需材料与成本") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("讲法：" + workflow.script_structure.joined(separator: " → "))
                                if let inputs = workflow.min_inputs { Text("最少准备：" + inputs.joined(separator: "、")) }
                                if let note = workflow.quality_note { Text(note) }
                                Text("画面：" + workflow.costs.editing)
                                Text("稿件：" + workflow.costs.writing)
                                Text("声音：" + workflow.costs.voice)
                                Text("视频模型：" + workflow.costs.video_model)
                                Text("时间与人工：" + workflow.costs.time)
                                if let hint = workflow.voice_hint { Text(hint) }
                                if let reason = workflow.unavailable_reason { Text(reason) }
                                ForEach(workflow.source_paths, id: \.self) { path in
                                    Button(URL(fileURLWithPath: path).lastPathComponent) {
                                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                                    }.buttonStyle(.link)
                                }
                            }.font(.system(size: 12)).padding(.top, 5)
                        }.font(.system(size: 12))
                    }
                }.padding(.vertical, 13)
                Divider()
            }
            if ranked.count > 3 {
                Button(showAll ? "收起其他流程" : "看全部 \(ranked.count) 条流程") { showAll.toggle() }
            }
        }
    }
    private func preview(_ workflow: VideoWorkflow) -> some View {
        VStack(spacing: 7) {
            if project.workflow_id == workflow.id, !workflow.preview_file.isEmpty {
                WorkbenchMedia(path: workflow.preview_file, height: 180)
            } else if let image = NSImage(contentsOfFile: workflow.thumbnail_path) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 160, height: 90)
            } else {
                Text("暂无真实预览").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90).background(Color(nsColor: .controlBackgroundColor))
            }
            if project.workflow_id != workflow.id, !workflow.preview_file.isEmpty, FileManager.default.fileExists(atPath: workflow.preview_file) {
                Button(VideoWorkflow.isImage(workflow.preview_file) ? "看真实图片" : "播放样片") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: workflow.preview_file))
                }.font(.system(size: 12))
            }
        }
    }
}

@MainActor final class ExitGuard: NSObject, NSWindowDelegate {
    static let shared = ExitGuard()
    var saveBeforeExit: (() -> Bool)?
    func windowShouldClose(_ sender: NSWindow) -> Bool { saveBeforeExit?() != false }
}

@MainActor final class AppExitDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ExitGuard.shared.saveBeforeExit?() == false ? .terminateCancel : .terminateNow
    }
}

struct WindowExitHook: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.delegate = ExitGuard.shared
        }
    }
}
