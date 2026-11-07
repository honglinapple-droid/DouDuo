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

    /// 拼一批：三路并行 → 去重去看过 → 按模式过滤 → 打分 → 配比上限
    func batch(_ bridge: DouyinBridge, portraitMode: Int, followed: Set<String>, exclude: Set<String>, want: Int) async -> [DYAweme] {
        let p = DYTasteProfile.shared
        // A 相关推荐：拿两条最近的正向种子去问
        let seeds = Array(p.positives.shuffled().prefix(2))
        async let a1 = seeds.indices.contains(0) ? (try? bridge.related(seeds[0])) ?? [] : []
        async let a2 = seeds.indices.contains(1) ? (try? bridge.related(seeds[1])) ?? [] : []
        // B 关注的人
        async let b1 = (try? bridge.followFeed(cursor: "0"))?.items ?? []
        // C 网页推荐流（两页）
        async let c1 = (try? bridge.fetchFeed())?.items ?? []
        async let c2 = (try? bridge.fetchFeed())?.items ?? []
        let (ra1, ra2, rb, rc1, rc2) = await (a1, a2, b1, c1, c2)

        struct Cand { let a: DYAweme; let bonus: Double }
        var cands: [Cand] = []
        var ids = Set<String>()
        let blocked = DYTaste.blockedAuthors
        func add(_ list: [DYAweme], bonus: Double) {
            for a in list {
                guard a.play != nil || !a.images.isEmpty, !ids.contains(a.id), !exclude.contains(a.id), p.seen[a.id] == nil else { continue }
                if let s = a.author.secUid, blocked.contains(s) { continue }
                ids.insert(a.id); cands.append(Cand(a: a, bonus: bonus))
            }
        }
        add(ra1 + ra2, bonus: 0.6); add(rb, bonus: 0.1); add(rc1 + rc2, bonus: 0)
        guard !cands.isEmpty else { return [] }

        func isFollowed(_ a: DYAweme) -> Bool { (a.author.followStatus ?? 0) >= 1 || a.author.secUid.map { followed.contains($0) } == true }
        // 竖屏模式：0 全部 / 1 竖屏优先（横屏只留认识的作者）/ 2 只看竖屏
        cands = cands.filter { c in
            let a = c.a
            if !a.images.isEmpty || a.isPortrait { return true }
            switch portraitMode { case 0: return true; case 1: return isFollowed(a) || p.author[a.author.secUid ?? "", default: 0] > 1; default: return false }
        }
        // 打分 + 一点随机，避免每次一模一样
        let scored = cands.map { c in (c, p.score(c.a) + c.bonus + Double.random(in: -0.15...0.15)) }.sorted { $0.1 > $1.1 }

        // 配比上限：已关注 ≤ 20%，单一分类 ≤ 30%，横屏 ≤ 20%，留 10% 探索
        let n = max(4, want)
        let capFollow = max(1, Int(Double(n) * 0.2)), capTag = max(1, Int(Double(n) * 0.3)), capLand = max(1, Int(Double(n) * 0.2))
        var out: [DYAweme] = [], nFollow = 0, nLand = 0, tagCount: [String: Int] = [:]
        var leftovers: [DYAweme] = []
        for (c, _) in scored {
            let a = c.a
            if out.count >= n - 1 { leftovers.append(a); continue }
            let f = isFollowed(a), land = a.images.isEmpty && !a.isPortrait
            let main = a.tags?.first ?? ""
            if f && nFollow >= capFollow { leftovers.append(a); continue }
            if land && nLand >= capLand { leftovers.append(a); continue }
            if !main.isEmpty && tagCount[main, default: 0] >= capTag { leftovers.append(a); continue }
            out.append(a); if f { nFollow += 1 }; if land { nLand += 1 }; if !main.isEmpty { tagCount[main, default: 0] += 1 }
        }
        // 探索位：从剩下的里随机来一条
        if let x = leftovers.shuffled().first, out.count < n { out.append(x) }
        DYLiveModel.log("DDREC batch cands=\(cands.count) out=\(out.count) follow=\(nFollow) land=\(nLand) seeds=\(seeds.count) A=\(ra1.count + ra2.count) B=\(rb.count) C=\(rc1.count + rc2.count)")
        return out
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
