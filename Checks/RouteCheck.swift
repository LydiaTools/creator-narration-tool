import Foundation

// Runs the same native workflow used by the app without opening a window.
@main struct RouteCheck {
    @MainActor static func main() throws {
        guard (4...5).contains(CommandLine.arguments.count) else {
            throw NSError(domain: "RouteCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "用法：route-check render|draft 项目ID 应用资源目录"])
        }
        let catalog = try JSONDecoder().decode(WorkbenchCatalog.self, from: Data(contentsOf: WorkbenchStore.dataURL))
        let identifier = CommandLine.arguments[2]
        guard var project = catalog.projects.first(where: { $0.id == identifier }) else {
            throw NSError(domain: "RouteCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: "没有找到项目"])
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[3])
        if CommandLine.arguments[1] == "render" {
            print(try WorkbenchEngine.render(project: project, assets: catalog.assets, resourceFolder: folder).path)
        } else if CommandLine.arguments[1] == "draft" {
            if CommandLine.arguments.count == 5 { project.idea = CommandLine.arguments[4] }
            let draft = try WorkbenchEngine.generateDraft(project: project, benchmark: nil, resourceFolder: folder)
            guard (3...5).contains(draft.scenes.count), !draft.script.isEmpty,
                  draft.scenes.allSatisfy({ !$0.narration.isEmpty && !$0.body.isEmpty }) else {
                throw NSError(domain: "RouteCheck", code: 3, userInfo: [NSLocalizedDescriptionKey: "口播和镜头未生成完整"])
            }
            print("title=\(draft.title) scenes=\(draft.scenes.count) characters=\(draft.script.count)")
        } else {
            throw NSError(domain: "RouteCheck", code: 4, userInfo: [NSLocalizedDescriptionKey: "未知操作"])
        }
    }
}
