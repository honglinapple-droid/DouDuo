// 本地推荐器：抖音网页版的推荐池子和手机版不是一个池子，这里让 App 自己当推荐器——
// 用你账号里现成的口味（观看历史、点赞、收藏，按最近优先加权）做种子，三路并行拉候选
//（相关推荐 / 关注 / 网页推荐流），本地打分排序，配比上限，边看边学。全部存手机本地，隔离模式下不上报。
import Foundation

// MARK: - 口味档案

@MainActor
final class DYTasteProfile {
    static let shared = DYTasteProfile()

    private(set) var tag: [String: Double] = [:]       // 分类标签 → 权重
    private(set) var author: [String: Double] = [:]    // 作者 sec_uid → 权重
    private(set) var hashtag: [String: Double] = [:]   // #话题 → 权重
    private(set) var seen: [String: Double] = [:]      // 看过的视频 id → 时间戳
    private(set) var positives: [String] = []          // 最近正向（看完 / 赞 / 收藏）的视频 id，当"相关推荐"的种子
    private(set) var seededAt: Double = 0
    private var dirty = false

    private struct Store: Codable { var tag: [String: Double]; var author: [String: Double]; var hashtag: [String: Double]; var seen: [String: Double]; var positives: [String]; var seededAt: Double }
    private static let key = "douyin_taste_profile_v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: Self.key), let s = try? JSONDecoder().decode(Store.self, from: d) {
            tag = s.tag; author = s.author; hashtag = s.hashtag; seen = s.seen; positives = s.positives; seededAt = s.seededAt
        }
    }

    func save() {
        guard dirty else { return }
        dirty = false
        let s = Store(tag: tag, author: author, hashtag: hashtag, seen: seen, positives: positives, seededAt: seededAt)
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: Self.key)
    }

    static func hashtags(_ desc: String) -> [String] {
        var out: [String] = []
        for part in desc.split(separator: "#").dropFirst() {
            let t = part.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? ""
            if !t.isEmpty && t.count <= 20 { out.append(t) }
        }
        return out
    }

    /// 给一条视频的各项特征加减权重
    private func bump(_ a: DYAweme, _ delta: Double) {
        for t in a.tags ?? [] { tag[t, default: 0] = clamp(tag[t, default: 0] + delta) }
        if let s = a.author.secUid { author[s, default: 0] = clamp(author[s, default: 0] + delta * 1.5) }
        for h in Self.hashtags(a.desc) { hashtag[h, default: 0] = clamp(hashtag[h, default: 0] + delta * 0.7) }
        dirty = true
    }
    private func clamp(_ v: Double) -> Double { max(-10, min(10, v)) }

    /// 用账号里现成的口味做种子：历史 / 点赞 / 收藏，越靠前（越近）权重越大
    func seed(history: [DYAweme], likes: [DYAweme], collects: [DYAweme]) {
        func recency(_ i: Int) -> Double { i < 30 ? 3 : (i < 100 ? 1 : 0.3) }
        for (i, a) in history.enumerated() { bump(a, 0.25 * recency(i)) }
        for (i, a) in likes.enumerated() { bump(a, 0.6 * recency(i)) }
        for (i, a) in collects.enumerated() { bump(a, 0.7 * recency(i)) }
        positives = Array((likes.prefix(20) + history.prefix(20)).map(\.id)).uniqued()
        seededAt = Date().timeIntervalSince1970
        // 种子里的视频算看过，不再推
        for a in history.prefix(200) { seen[a.id] = seededAt }
        prune()
        dirty = true
        save()
    }

    enum Event { case watched(fraction: Double, seconds: Double), liked, collected, disliked }

    /// 边看边学
    func record(_ a: DYAweme, _ e: Event) {
        // 轻微衰减：旧的口味慢慢让位
        decayCounter += 1
        if decayCounter % 20 == 0 { decay() }
        switch e {
        case .watched(let f, let sec):
            if sec < 3 && f < 0.2 { bump(a, -0.6) }                // 3 秒内划走
            else if f >= 0.6 { bump(a, 0.8); addPositive(a.id) }   // 看完 / 看了大半
            else if f >= 0.3 { bump(a, 0.2) }
            else { bump(a, -0.15) }
        case .liked: bump(a, 2.0); addPositive(a.id)
        case .collected: bump(a, 2.5); addPositive(a.id)
        case .disliked:
            if let s = a.author.secUid { author[s] = -10 }
            for t in a.tags ?? [] { tag[t, default: 0] = clamp(tag[t, default: 0] - 1) }
        }
        seen[a.id] = Date().timeIntervalSince1970
        prune()
        dirty = true
        save()
    }
    private var decayCounter = 0
    private func decay() {
        for (k, v) in tag { tag[k] = v * 0.97 }
        for (k, v) in hashtag { hashtag[k] = v * 0.97 }
        for (k, v) in author where v > -10 { author[k] = v * 0.98 }
    }
    private func addPositive(_ id: String) {
        positives.removeAll { $0 == id }
        positives.insert(id, at: 0)
        if positives.count > 40 { positives.removeLast(positives.count - 40) }
    }
    func markSeen(_ ids: [String]) { let t = Date().timeIntervalSince1970; for id in ids { seen[id] = t }; dirty = true }
    private func prune() {
        if seen.count > 4000 { let cut = seen.sorted { $0.value < $1.value }.prefix(seen.count - 3000); for (k, _) in cut { seen[k] = nil } }
        if tag.count > 800 { for (k, v) in tag where abs(v) < 0.05 { tag[k] = nil } }
        if hashtag.count > 2000 { for (k, v) in hashtag where abs(v) < 0.1 { hashtag[k] = nil } }
        if author.count > 2000 { for (k, v) in author where abs(v) < 0.1 { author[k] = nil } }
    }

    /// 一条候选视频有多像你的口味
    func score(_ a: DYAweme) -> Double {
        var s = 0.0
        let tags = a.tags ?? []
        if !tags.isEmpty { s += tags.reduce(0) { $0 + tag[$1, default: 0] } / Double(tags.count) }
        if let sec = a.author.secUid { s += author[sec, default: 0] * 0.6 }
        let hs = Self.hashtags(a.desc)
        if !hs.isEmpty { s += hs.reduce(0) { $0 + hashtag[$1, default: 0] } / Double(hs.count) * 0.5 }
        if a.duration > 600 { s -= 1.0 } else if a.duration > 180 { s -= 0.3 }
        if let t = a.createTime, t > 0, Date().timeIntervalSince1970 - t < 7 * 86400 { s += 0.3 }
        if a.isPortrait || !a.images.isEmpty { s += 0.2 }
        return s
    }

    var topTags: [String] { tag.sorted { $0.value > $1.value }.prefix(8).map(\.key) }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] { var s = Set<Element>(); return filter { s.insert($0).inserted } }
}

// MARK: - 推荐器

@MainActor
final class DYRecommender {
    static let shared = DYRecommender()
    private var seeding = false
    private var relatedCursor = 0

    /// 登录后拉一次口味种子（历史两页、点赞两页、收藏一页）；一天内不重复
    func seedIfNeeded(_ bridge: DouyinBridge) async {
        let p = DYTasteProfile.shared
        guard !seeding, Date().timeIntervalSince1970 - p.seededAt > 86400 else { return }
        seeding = true
        defer { seeding = false }
        async let h1 = (try? bridge.myList(.history, cursor: "0"))
        async let l1 = (try? bridge.myList(.like, cursor: "0"))
        async let c1 = (try? bridge.myList(.collect, cursor: "0"))
        let (h, l, c) = await (h1, l1, c1)
        var history = h?.items ?? [], likes = l?.items ?? [], collects = c?.items ?? []
        if let h, h.hasMore, let h2 = try? await bridge.myList(.history, cursor: h.cursor) { history += h2.items }
        if let l, l.hasMore, let l2 = try? await bridge.myList(.like, cursor: l.cursor) { likes += l2.items }
        guard !(history.isEmpty && likes.isEmpty && collects.isEmpty) else { return }
        p.seed(history: history, likes: likes, collects: collects)
        DYLiveModel.log("DDREC seeded h=\(history.count) l=\(likes.count) c=\(collects.count) top=\(p.topTags)")
    }

    // 旁路备用池：相关推荐 / 关注 两路在后台慢慢拉，拉到打好分放这里，主线每塞一页就从这儿插几条
    private var pool: [(a: DYAweme, score: Double)] = []
    private var refilling = false
    private var followCursor = "0"

    /// 就地过滤 + 打分排序 + 配比上限（纯本地，不发请求）。网页流每页一回来就过这一道
    func rank(_ page: [DYAweme], portraitMode: Int, followed: Set<String>, exclude: Set<String>) -> [DYAweme] {
        let p = DYTasteProfile.shared
        let blocked = DYTaste.blockedAuthors
        func isFollowed(_ a: DYAweme) -> Bool { (a.author.followStatus ?? 0) >= 1 || a.author.secUid.map { followed.contains($0) } == true }
        var ids = Set<String>()
        var cands: [DYAweme] = []
        for a in page {
            guard a.play != nil || !a.images.isEmpty, !ids.contains(a.id), !exclude.contains(a.id), p.seen[a.id] == nil else { continue }
            if let sec = a.author.secUid, blocked.contains(sec) { continue }
            if a.images.isEmpty && !a.isPortrait {
                // 竖屏模式：0 全部 / 1 竖屏优先（横屏只留认识的作者）/ 2 只看竖屏
                switch portraitMode { case 0: break; case 1: if !(isFollowed(a) || p.author[a.author.secUid ?? "", default: 0] > 1) { continue }; default: continue }
            }
            ids.insert(a.id); cands.append(a)
        }
        guard !cands.isEmpty else { return [] }
        // 从备用池插几条（最多 3 条，分数高的先）
        var extras: [DYAweme] = []
        pool.sort { $0.score > $1.score }
        while extras.count < 3, let top = pool.first {
            pool.removeFirst()
            guard !ids.contains(top.a.id), !exclude.contains(top.a.id), p.seen[top.a.id] == nil else { continue }
            if top.a.images.isEmpty && !top.a.isPortrait && portraitMode == 2 { continue }
            ids.insert(top.a.id); extras.append(top.a)
        }
        let scored = (cands.map { ($0, p.score($0) + Double.random(in: -0.15...0.15)) } + extras.map { ($0, p.score($0) + 0.6) }).sorted { $0.1 > $1.1 }
        // 配比上限：已关注 ≤ 20%，单一分类 ≤ 30%，横屏 ≤ 20%
        let n = scored.count
        let capFollow = max(1, Int(Double(n) * 0.2)), capTag = max(2, Int(Double(n) * 0.3)), capLand = max(1, Int(Double(n) * 0.2))
        var out: [DYAweme] = [], nFollow = 0, nLand = 0, tagCount: [String: Int] = [:], dropped: [DYAweme] = []
        for (a, _) in scored {
            let f = isFollowed(a), land = a.images.isEmpty && !a.isPortrait, main = a.tags?.first ?? ""
            if f && nFollow >= capFollow { dropped.append(a); continue }
            if land && nLand >= capLand { dropped.append(a); continue }
            if !main.isEmpty && tagCount[main, default: 0] >= capTag { dropped.append(a); continue }
            out.append(a); if f { nFollow += 1 }; if land { nLand += 1 }; if !main.isEmpty { tagCount[main, default: 0] += 1 }
        }
        // 被配比挤掉的别浪费，扔回备用池（分数打折），下次人少了再上
        for a in dropped.prefix(10) { pool.append((a, p.score(a) - 1)) }
        if pool.count > 60 { pool.sort { $0.score > $1.score }; pool.removeLast(pool.count - 60) }
        DYLiveModel.log("DDREC rank in=\(page.count) cands=\(cands.count) extras=\(extras.count) out=\(out.count) follow=\(nFollow) land=\(nLand) pool=\(pool.count)")
        return out
    }

    /// 后台补备用池：相关推荐（拿最近正向的种子问）+ 关注的人。不重试，拉不到就算；主线不等它
    func refillPool(_ bridge: DouyinBridge, loggedIn: Bool) {
        guard !refilling, pool.count < 8 else { return }
        refilling = true
        Task {
            defer { refilling = false }
            let p = DYTasteProfile.shared
            let seeds = Array(p.positives.shuffled().prefix(2))
            async let r1: [DYAweme] = seeds.indices.contains(0) ? ((try? await bridge.related(seeds[0])) ?? []) : []
            async let r2: [DYAweme] = seeds.indices.contains(1) ? ((try? await bridge.related(seeds[1])) ?? []) : []
            async let f1: [DYAweme] = loggedIn ? ((try? await bridge.followFeed(cursor: followCursor))?.items ?? []) : []
            let (a, b, f) = await (r1, r2, f1)
            let blocked = DYTaste.blockedAuthors
            var have = Set(pool.map { $0.a.id })
            for (list, bonus) in [(a + b, 0.6), (f, 0.1)] {
                for x in list where x.play != nil || !x.images.isEmpty {
                    guard !have.contains(x.id), p.seen[x.id] == nil, !(x.author.secUid.map { blocked.contains($0) } ?? false) else { continue }
                    have.insert(x.id); pool.append((x, p.score(x) + bonus))
                }
            }
            DYLiveModel.log("DDREC refill related=\(a.count + b.count) follow=\(f.count) pool=\(pool.count)")
        }
    }

extension DouyinBridge {
    private struct RelatedResp: Decodable { let status: Int; let items: [DYAweme] }
    /// 相关推荐：抖音自己的"和这条相似的"，是能接到的最接近抖音算法的一路
    func related(_ id: String) async throws -> [DYAweme] {
        let d = try await call(Self.relatedJS, args: ["id": id], attempts: 1)
        return try JSONDecoder().decode(RelatedResp.self, from: d).items
    }
    static let relatedJS = #"""
    const r = await req('GET', '/aweme/v1/web/aweme/related/?' + q({ aweme_id: id, count: '20', filterGids: '', awemePcRecRawData: '{}', sub_channel_id: '3', 'Seo-Flag': '0' }));
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, items: (d.aweme_list || []).filter(a => a && (a.video || a.images) && !a.is_ads).map(mapA) });
    """#
}
