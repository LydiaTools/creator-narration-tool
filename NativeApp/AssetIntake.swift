import Foundation
import Darwin

extension WorkbenchStore {
    func receiveSelectedAssets() {
        guard mounted(), !isBusy, !isLoading else { return }
        let incoming = Self.work.appendingPathComponent("待取用素材.json")
        guard FileManager.default.fileExists(atPath: incoming.path) else { return }
        do {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: incoming)) as? [String: Any] ?? [:]
            let rows = object["assets"] as? [[String: Any]] ?? []
            guard (1...2).contains(rows.count) else { throw IntakeError.invalidSelection }
            var additions: [VideoAsset] = []
            for row in rows {
                guard let id = row["material_id"] as? String, let path = row["path"] as? String,
                      let hash = row["sha256"] as? String,
                      URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(Self.volume.path + "/"),
                      try WorkbenchEngine.digest(URL(fileURLWithPath: path)) == hash else { throw IntakeError.invalidSelection }
                if !catalog.assets.contains(where: { $0.id == id }) {
                    additions.append(VideoAsset(id: id, title: row["display_name"] as? String ?? id,
                        path: path, tags: (row["tags"] as? [String] ?? []).joined(separator: ","),
                        rights: row["rights_note"] as? String ?? "用户声明：本批素材可商用",
                        project_id: selectedID, created_at: DateFormatter.workbench.string(from: Date())))
                }
            }
            catalog.assets.insert(contentsOf: additions, at: 0)
            guard save() else { return }
            let archive = Self.work.appendingPathComponent("选材记录", isDirectory: true)
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: incoming, to: archive.appendingPathComponent(UUID().uuidString + ".json"))
            message = "已接收 \(rows.count) 件选材；原件仍在外盘，可用于本期镜头"
        } catch { message = "选材未接收：\(error.localizedDescription)" }
    }
}

private enum IntakeError: LocalizedError {
    case invalidSelection
    var errorDescription: String? { "选材清单、原件路径或哈希不符，未导入" }
}

struct MediaResourceLease {
    let handle: Int32
    init(destination: URL? = nil, requiresLocalModel: Bool = false) throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/出海视频")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent("heavy.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw LeaseError.unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw LeaseError.busy }
        do {
            let values = try FileManager.default.attributesOfFileSystem(forPath: FileManager.default.homeDirectoryForCurrentUser.path)
            let minimum: Int64 = (requiresLocalModel ? 20 : 1) * 1024 * 1024 * 1024
            guard let free = values[.systemFreeSize] as? NSNumber, free.int64Value >= minimum else { throw LeaseError.lowDisk }
            if let destination {
                var mount = statfs()
                guard statfs(WorkbenchStore.volume.path, &mount) == 0 else { throw LeaseError.externalDisk }
                let mountedAt = withUnsafePointer(to: &mount.f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
                }
                guard mountedAt == WorkbenchStore.volume.path,
                      destination.resolvingSymlinksInPath().path.hasPrefix(WorkbenchStore.volume.path + "/") else { throw LeaseError.externalDisk }
                let external = try FileManager.default.attributesOfFileSystem(forPath: destination.path)
                guard let remaining = external[.systemFreeSize] as? NSNumber,
                      remaining.int64Value >= 2 * 1024 * 1024 * 1024 else { throw LeaseError.externalDisk }
            }
        } catch { flock(fd, LOCK_UN); close(fd); throw error }
        handle = fd
    }
    func release() { flock(handle, LOCK_UN); close(handle) }
    private enum LeaseError: LocalizedError {
        case unavailable, busy, lowDisk, externalDisk
        var errorDescription: String? {
            switch self {
            case .unavailable: "无法建立任务锁，未启动制作"
            case .busy: "已有视频制作任务运行，请等它完成后再继续"
            case .lowDisk: "运行所需内盘空间不足：固定剪辑至少 1 GiB，本地配音模型至少 20 GiB；已停止启动"
            case .externalDisk: "视频外盘未正确挂载，或剩余不足 2 GiB；已停止启动"
            }
        }
    }
}
