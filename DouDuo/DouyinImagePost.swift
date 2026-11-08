// b54：图文作品（一组图片 + 背景音乐），照手机版抖音：
// - 背景音乐循环播放；静音、单击暂停、划走、切后台都和视频一样处理
// - 每 3 秒自动翻到下一张，手指自己翻过一次就不再自动翻
import SwiftUI
import AVFoundation

struct DYImagePost: View {
    let item: DYAweme
    /// 是不是当前正在看的这条（划走 = false → 停音乐、停自动翻页）
    let isActive: Bool

    @State private var index = 0
    /// 用户自己翻过 → 不再自动翻
    @State private var manual = false
    /// 程序在翻页（不算用户翻）
    @State private var autoTurning = false
    /// 单击暂停（音乐 + 自动翻页一起停）
    @State private var paused = false
    @State private var player: AVPlayer?
    @State private var loopObs: NSObjectProtocol?
    @State private var playbackID = UUID()

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(item.images.enumerated()), id: \.offset) { i, s in
                CachedAsyncImage(url: URL(string: s)) { img in img.resizable().scaledToFit() } placeholder: { ProgressView() }
                    .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .contentShape(Rectangle())
        .onTapGesture {
            paused.toggle()
            DYLiveModel.log("DDPAUSE 图文单击 \(paused ? "→暂停" : "→播放") id=\(item.id.suffix(6))")
            apply()
        }
        .overlay {
            if paused && isActive {
                Image(systemName: "play.fill").font(.system(size: 56)).foregroundStyle(.white.opacity(0.8))
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: index) { _, _ in
            if !autoTurning { manual = true }
        }
        // 自动翻页：当前条、没暂停、用户没自己翻过、不止一张
        .task(id: "\(isActive)-\(paused)-\(manual)") {
            guard isActive, !paused, !manual, item.images.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, !manual, !paused else { return }
                autoTurning = true
                withAnimation(.easeInOut(duration: 0.35)) { index = (index + 1) % item.images.count }
                // 等 onChange 处理完再放开
                DispatchQueue.main.async { autoTurning = false }
            }
        }
        .onChange(of: isActive) { _, active in
            if !active { paused = false }   // 划走再回来从播放状态开始
            apply()
        }
        .onAppear {
            apply()
            DDPlayback.shared.register(playbackID, stop: { player?.pause() }, start: { apply() })
        }
        .onDisappear {
            DDPlayback.shared.unregister(playbackID)
            stopMusic()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            player?.pause()
        }
    }

    /// 按当前状态开 / 停音乐
    private func apply() {
        guard isActive, !paused, DDPlayback.shared.appIsActive else { player?.pause(); return }
        guard let s = item.musicURL, let u = URL(string: s) else { return }
        if player == nil {
            let p = AVPlayer(playerItem: AVPlayerItem(asset: DYMedia.asset(u)))
            p.automaticallyWaitsToMinimizeStalling = true
            player = p
            // 循环
            loopObs = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: p.currentItem, queue: .main) { _ in
                p.seek(to: .zero); p.play()
            }
            DYLiveModel.log("DDIMG 背景音乐起播 id=\(item.id.suffix(6)) muted=\(DYMute.on)")
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player?.isMuted = DYMute.on
        player?.play()
    }

    private func stopMusic() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        if let o = loopObs { NotificationCenter.default.removeObserver(o); loopObs = nil }
    }
}
