// 本地视频缓存：推荐流播放时，后台把后面几条完整下载到 Caches/dd-videos/（磁盘上最多留 N 条，默认 50）。
// b44：同时只下 1 条、只下当前后面 5 条以内——之前 2 条并发一路下到 50 条，和正在播的视频、推荐接口抢网络
// b54：超过 15MB 的不整条下（先探大小），大视频在线播放、靠预加载器缓冲开头
// - 下滑到已缓存的条目直接播本地文件，不等网络
// - 下次打开 App 先播「已缓存、还没看过」的，连接抖音放到后台
// - 超过上限先删看过的、再删最早的
import Foundation
import UIKit

/// 浏览会话保存在 Application Support，不随视频缓存清理或系统回收而丢失。
struct DYFeedSession: Codable {
    var items: [DYAweme]
    var currentID: String
    var positions: [String: Double]

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("feed-session.json")
    }
    static func load() -> DYFeedSession? {
        guard let data = try? Data(contentsOf: url),
              let session = try? JSONDecoder().decode(Self.self, from: data),
              session.items.contains(where: { $0.id == session.currentID }) else { return nil }
        return session
    }
    func save() {
        guard items.contains(where: { $0.id == currentID }),
              let data = try? JSONEncoder().encode(self) else { return }
        do { try data.write(to: Self.url, options: .atomic) }
        catch { DYLiveModel.log("DDSESSION 保存失败 \(error.localizedDescription)") }
    }
}

actor DYVideoCache {
    static let shared = DYVideoCache()
    static let countKey = "douyin_cache_count_v1"
    static let defaultCount = 50
    /// 超过这个时长的不整条下载（太大），仍走在线播放 + 内存预缓冲
    static let maxDuration: Double = 300
    /// 磁盘总量上限（条数没到也按这个删，长视频单条能有 100MB）
    static let maxBytes = 2 * 1024 * 1024 * 1024

    struct Entry: Codable {
        var aweme: DYAweme
        var watched: Bool
        var added: Double
        var bytes: Int
    }

    nonisolated static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("dd-videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    nonisolated static var indexURL: URL { dir.appendingPathComponent("index.json") }

    nonisolated static var limit: Int {
        (UserDefaults.standard.object(forKey: countKey) as? Int) ?? defaultCount
    }

    /// 已经下完的本地文件（同步，播放器建 item 时直接用）
    nonisolated static func localURL(_ id: String) -> URL? {
        let f = dir.appendingPathComponent("\(id).mp4")
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    /// 启动时用：缓存好、还没看过的，按加入顺序
    nonisolated static func pendingSnapshot() -> [DYAweme] {
        guard let d = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([Entry].self, from: d) else { return [] }
        return list.filter { !$0.watched && localURL($0.aweme.id) != nil }.map(\.aweme)
    }

    private var entries: [Entry]
    private var queue: [DYAweme] = []
    private var active: Set<String> = []
    private var failed: Set<String> = []
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 300
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
        if let d = try? Data(contentsOf: Self.indexURL), let list = try? JSONDecoder().decode([Entry].self, from: d) {
            entries = list.filter { Self.localURL($0.aweme.id) != nil }
        } else {
            entries = []
        }
    }

    /// 当前位置之后的列表（按顺序），排队下载；已下 / 正在下 / 失败过的跳过
    func enqueue(_ ahead: [DYAweme]) {
        let lim = Self.limit
        guard lim > 0 else { queue = []; return }
        let have = Set(entries.map(\.aweme.id))
        queue = ahead.prefix(min(lim, 5)).filter { a in
            a.images.isEmpty && a.play != nil && a.duration <= Self.maxDuration
                && !have.contains(a.id) && !active.contains(a.id) && !failed.contains(a.id)
        }
        // 图文：图片走图片缓存
        for a in ahead.prefix(min(lim, 5)) where !a.images.isEmpty {
            for s in a.images.prefix(9) { if let u = URL(string: s) { Task { _ = await ImageCache.shared.load(u) } } }
        }
        pump()
    }

    func markWatched(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.aweme.id == id }), !entries[i].watched else { return }
        entries[i].watched = true
        save()
    }

    func usage() -> (count: Int, bytes: Int) {
        (entries.count, entries.reduce(0) { $0 + $1.bytes })
    }

    func clear() -> Int {
        let bytes = entries.reduce(0) { $0 + $1.bytes }
        queue = []
        entries = []
        if let files = try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
        return bytes
    }

    // MARK: 下载

    private func pump() {
        while active.count < 1, !queue.isEmpty {
            let a = queue.removeFirst()
            guard let s = a.play, let u = URL(string: s) else { continue }
            active.insert(a.id)
            Task { await self.download(a, u) }
        }
    }

    /// b54：超过这么大的不整条下载（之前有一条 98MB 下了 51 秒，抢正在看的那条的网速、还常断）。
    /// 大视频交给播放器在线播放：预加载器已经提前把开头几秒缓冲在内存里，照样秒开
    static let maxBytesPerVideo = 15 * 1024 * 1024

    /// 先只要 2 个字节，从回包的 Content-Range 读出整条多大；读不出来返回 nil（照旧下载）
    private func probeSize(_ u: URL) async -> Int? {
        var r = URLRequest(url: u)
        DYMedia.headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
        r.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        r.timeoutInterval = 8
        guard let (_, resp) = try? await session.data(for: r), let h = resp as? HTTPURLResponse else { return nil }
        if let cr = h.value(forHTTPHeaderField: "Content-Range"), let total = cr.split(separator: "/").last.flatMap({ Int($0) }) { return total }
        return h.statusCode == 200 && h.expectedContentLength > 0 ? Int(h.expectedContentLength) : nil
    }

    private func download(_ a: DYAweme, _ u: URL) async {
        var r = URLRequest(url: u)
        DYMedia.headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
        let t0 = Date()
        if let size = await probeSize(u), size > Self.maxBytesPerVideo {
            failed.insert(a.id)   // 记下来，这条不再排队
            DYLiveModel.log("DDCACHE skip 太大 \(a.id) \(size / 1024 / 1024)MB → 在线播放")
            active.remove(a.id)
            pump()
            return
        }
        do {
            let (tmp, resp) = try await session.download(for: r)
            if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw URLError(.badServerResponse) }
            let dst = Self.dir.appendingPathComponent("\(a.id).mp4")
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tmp, to: dst)
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: dst.path)[.size]) as? Int) ?? 0
            guard bytes > 50_000 else { try? FileManager.default.removeItem(at: dst); throw URLError(.zeroByteResource) }
            entries.removeAll { $0.aweme.id == a.id }
            entries.append(Entry(aweme: a, watched: false, added: Date().timeIntervalSince1970, bytes: bytes))
            evict()
            save()
            DYLiveModel.log("DDCACHE ok \(a.id) \(bytes / 1024)KB \(String(format: "%.1f", Date().timeIntervalSince(t0)))s total=\(entries.count)")
        } catch {
            failed.insert(a.id)
            DYLiveModel.log("DDCACHE fail \(a.id) \(error.localizedDescription)")
        }
        active.remove(a.id)
        pump()
    }

    /// 超上限：先删看过的（最早的先删），还超就删最早加进来的
    private func evict() {
        let lim = max(Self.limit, 0)
        while entries.count > lim || (entries.count > 1 && entries.reduce(0, { $0 + $1.bytes }) > Self.maxBytes) {
            let idx = entries.firstIndex(where: \.watched) ?? 0
            let e = entries.remove(at: idx)
            try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent("\(e.aweme.id).mp4"))
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: Self.indexURL, options: .atomic) }
    }
}
