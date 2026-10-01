import SwiftUI
import AVKit
import ImageIO

/// The player follows the selected file, and releases playback when leaving a page.
struct WorkbenchPlayer: NSViewRepresentable {
    let player: AVPlayer
    var audioOnly = false
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        view.setAccessibilityLabel(audioOnly ? "配音试听播放器" : "视频预览播放器")
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player?.pause()
            view.player = player
        }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

struct WorkbenchMedia: View {
    let path: String
    var audioOnly = false
    var height: CGFloat = 300
    var body: some View {
        if !FileManager.default.fileExists(atPath: path) {
            Label("原件不可用，请连接外盘或重新导入", systemImage: "exclamationmark.triangle")
                .font(.system(size: 13)).frame(maxWidth: .infinity, minHeight: audioOnly ? 70 : height)
        } else if VideoWorkflow.isImage(path) {
            WorkbenchThumbnail(path: path).frame(height: height)
        } else {
            PlaybackPanel(path: path, audioOnly: audioOnly, height: height).id(path)
        }
    }
}

@MainActor private final class PlaybackState: ObservableObject {
    let player: AVPlayer
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var playing = false
    @Published var ready = false
    @Published var failure = ""
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?
    init(path: String) {
        player = AVPlayer(url: URL(fileURLWithPath: path))
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                let seconds = self.player.currentItem?.duration.seconds ?? 0
                if seconds.isFinite { self.duration = max(0, seconds) }
            }
        }
        statusObserver = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let failed = item.status == .failed
            let ready = item.status == .readyToPlay
            let duration = item.duration.seconds
            let message = item.error?.localizedDescription ?? "无法读取媒体，请检查原件"
            DispatchQueue.main.async {
                self?.failure = failed ? message : ""
                self?.ready = ready
                if duration.isFinite { self?.duration = max(0, duration) }
            }
        }
        rateObserver = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.rate != 0
            DispatchQueue.main.async { self?.playing = playing }
        }
    }
    func toggle() {
        if playing { player.pause() }
        else {
            if duration > 0 && position >= duration - 0.1 { player.seek(to: .zero) }
            player.play()
        }
    }
    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        player.pause()
    }
}

private struct PlaybackPanel: View {
    let path: String
    let audioOnly: Bool
    let height: CGFloat
    @StateObject private var playback: PlaybackState
    init(path: String, audioOnly: Bool, height: CGFloat) {
        self.path = path; self.audioOnly = audioOnly; self.height = height
        _playback = StateObject(wrappedValue: PlaybackState(path: path))
    }
    private func time(_ value: Double) -> String { String(format: "%02d:%02d", Int(max(0, value)) / 60, Int(max(0, value)) % 60) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !audioOnly { WorkbenchPlayer(player: playback.player).frame(height: height) }
            HStack(spacing: 10) {
                Button { playback.toggle() } label: {
                    Label(playback.playing ? "暂停" : "播放", systemImage: playback.playing ? "pause.fill" : "play.fill")
                }.buttonStyle(.bordered).disabled(!playback.ready || !playback.failure.isEmpty)
                Slider(value: Binding(get: { playback.position }, set: { value in
                    playback.position = value
                    playback.player.seek(to: CMTime(seconds: value, preferredTimescale: 600))
                }), in: 0...max(0.1, playback.duration)).accessibilityLabel(audioOnly ? "配音进度" : "视频进度")
                Text(time(playback.position) + " / " + time(playback.duration))
                    .font(.system(size: 12)).monospacedDigit().fixedSize()
            }
            if !playback.failure.isEmpty {
                Label(playback.failure, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange)
            } else if !playback.ready {
                ProgressView("正在读取媒体").font(.system(size: 12))
            }
        }.onDisappear { playback.player.pause() }
    }
}

struct WorkbenchThumbnail: View {
    let path: String
    @State private var image: NSImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Label(failed ? "原件不可用" : "读取画面", systemImage: failed ? "exclamationmark.triangle" : "photo")
                .font(.system(size: 12)).foregroundStyle(.secondary) }
        }.clipped().task(id: path) {
            image = nil; failed = false
            let requestedPath = path
            let cgImage: CGImage?
            let url = URL(fileURLWithPath: requestedPath)
            if VideoWorkflow.isImage(requestedPath) {
                cgImage = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap {
                    CGImageSourceCreateThumbnailAtIndex($0, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 640,
                        kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                }
            } else {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.maximumSize = CGSize(width: 640, height: 640)
                generator.appliesPreferredTrackTransform = true
                cgImage = try? await generator.image(at: .zero).image
            }
            guard !Task.isCancelled, requestedPath == path else { return }
            if let cgImage { image = NSImage(cgImage: cgImage, size: .zero) }
            else { failed = true }
        }
    }
}
