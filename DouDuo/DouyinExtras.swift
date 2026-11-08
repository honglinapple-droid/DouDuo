// DouDuo 扩展功能：搜索 / 我的（喜欢·收藏·历史·稍后再看）/ 关注 / 作者主页 / 弹幕 / 楼中楼 / 保存到相册
// 全部接口都走隐藏签名页（DouyinBridge.call），和推荐流同一套签名，不逆向。
import SwiftUI
import WebKit
import Combine
import AVFoundation
import Photos

// MARK: - 数据

extension DYAweme.Author: Identifiable { public var id: String { secUid ?? name } }

struct DYDanmaku: Identifiable, Decodable, Equatable {
    let id: String
    let text: String
    let offset: Double      // 秒
}

struct DYUser: Decodable, Equatable {
    let name: String
    let avatar: String?
    let signature: String
    let secUid: String
    let followers: Int
    let following: Int
    let likes: Int
    let works: Int
    let ip: String?
    /// b50：0 没关注 / 1 已关注 / 2 互相关注（作者主页「关注」按钮用；接口没给就是 nil）
    var followStatus: Int? = nil
}

struct DYSug: Identifiable, Decodable, Equatable {
    var id: String { word }
    let word: String
}

enum DYListKind: String, CaseIterable, Identifiable {
    case like, collect, history, later
    var id: String { rawValue }
    var title: String {
        switch self {
        case .like: "喜欢"
        case .collect: "收藏"
        case .history: "历史"
        case .later: "稍后再看"
        }
    }
}

private struct DYListPage: Decodable { let status: Int; let items: [DYAweme]; let cursor: String; let hasMore: Bool; let code: Int?; let msg: String? }
private struct DYDanmakuPage: Decodable { let status: Int; let items: [DYDanmaku] }
private struct DYReplyPage: Decodable { let status: Int; let items: [DYComment]; let cursor: Int; let hasMore: Bool; let msg: String? }
private struct DYPublishResp: Decodable { let status: Int; let code: Int?; let msg: String?; let comment: DYComment?; let danmakuID: String? }
private struct DYUserResp: Decodable { let status: Int; let user: DYUser?; let msg: String? }
private struct DYSugResp: Decodable { let status: Int; let items: [DYSug] }

// MARK: - 接口

extension DouyinBridge {
    /// 列表通用：喜欢 / 收藏 / 历史 / 稍后再看 / 关注 / 搜索，统一回 (items, cursor, hasMore)
    private func list(_ js: String, _ args: [String: Any]) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool) {
        let d = try await call(js, args: args)
        let p = try JSONDecoder().decode(DYListPage.self, from: d)
        if p.code == 8 || (p.msg ?? "").contains("未登录") { throw DYError.bad("抖音未登录：右上「我的」→ 登录") }
        guard p.status == 200 else { throw DYError.blocked("HTTP \(p.status)") }
        return (p.items, p.cursor, p.hasMore)
    }

    func selfSecUid() async throws -> String {
        if let s = selfSecCache { return s }
        let u = try await selfProfile()
        selfSecCache = u.secUid
        return u.secUid
    }

    func selfProfile() async throws -> DYUser {
        let d = try await call(Self.selfJS, args: [:])
        let r = try JSONDecoder().decode(DYUserResp.self, from: d)
        guard let u = r.user, !u.secUid.isEmpty else { throw DYError.bad(r.msg ?? "抖音未登录") }
        return u
    }

    func userProfile(_ sec: String) async throws -> DYUser {
        let d = try await call(Self.otherJS, args: ["sec": sec])
        let r = try JSONDecoder().decode(DYUserResp.self, from: d)
        guard let u = r.user else { throw DYError.bad(r.msg ?? "读取作者信息失败") }
        return u
    }

    /// b49：作者作品列表（原生主页九宫格用）。和网页版点进作者主页时发的是同一个请求
    func userPosts(_ sec: String, cursor: String) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool) {
        try await serialized { try await self.list(Self.postJS, ["sec": sec, "cursor": cursor]) }
    }

    func myList(_ kind: DYListKind, cursor: String) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool) {
        switch kind {
        case .like:
            let sec = try await selfSecUid()
            return try await list(Self.likeJS, ["sec": sec, "cursor": cursor])
        case .collect: return try await list(Self.collectJS, ["cursor": cursor])
        case .history: return try await list(Self.historyJS, ["cursor": cursor])
        case .later: return try await list(Self.laterJS, ["cursor": cursor])
        }
    }

    func followFeed(cursor: String) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool) {
        try await serialized { try await self.list(Self.followJS, ["cursor": cursor]) }
    }

    /// 搜索：网页接口只给第一页（翻第二页安全 SDK 直接压住不返回，换参数 / search_id 都一样）
    /// → 只拉一次、hasMore 置 false，免得底部一直转圈或报「拦截」
    func search(_ kw: String, offset: String) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool) {
        guard offset == "0" else { return ([], offset, false) }
        let r = try await list(Self.searchJS, ["kw": kw, "cursor": "0"])
        return (r.items, r.cursor, false)
    }

    func suggest(_ kw: String) async -> [DYSug] {
        guard let d = try? await call(Self.sugJS, args: ["kw": kw], attempts: 1),
              let r = try? JSONDecoder().decode(DYSugResp.self, from: d) else { return [] }
        return r.items
    }

    func danmaku(_ id: String, durationMs: Int) async throws -> [DYDanmaku] {
        let d = try await call(Self.danmakuJS, args: ["id": id, "dur": String(max(durationMs, 15000))], attempts: 1)
        let r = try JSONDecoder().decode(DYDanmakuPage.self, from: d)
        return r.items.sorted { $0.offset < $1.offset }
    }

    func fetchReplies(_ id: String, commentID: String, cursor: Int) async throws -> (items: [DYComment], cursor: Int, hasMore: Bool) {
        let d = try await call(Self.replyJS, args: ["id": id, "cid": commentID, "cursor": String(cursor)], attempts: 1)
        let p = try JSONDecoder().decode(DYReplyPage.self, from: d)
        guard p.status == 200 else { throw DYError.blocked(p.msg ?? "HTTP \(p.status)") }
        return (p.items, p.cursor, p.hasMore)
    }

    /// 发评论 / 回复评论（replyID 非空 = 回复那条）
    func publishComment(_ awemeID: String, text: String, replyID: String? = nil) async throws -> DYComment {
        let d = try await call(Self.publishJS, args: ["id": awemeID, "text": text, "reply": replyID ?? "0"], attempts: 1)
        let r = try JSONDecoder().decode(DYPublishResp.self, from: d)
        DYLiveModel.log("DDSEND comment status=\(r.status) code=\(r.code ?? -1) msg=\(r.msg ?? "-")")
        if r.code == 8 { throw DYError.bad("抖音未登录") }
        guard r.status == 200, (r.code ?? 0) == 0, let c = r.comment else {
            throw DYError.bad(r.msg?.isEmpty == false ? r.msg! : "发送失败（HTTP \(r.status) / \(r.code ?? -1)）")
        }
        return c
    }

    func deleteComment(_ cid: String) async -> Bool {
        guard let d = try? await call(Self.deleteCommentJS, args: ["cid": cid], attempts: 1),
              let r = try? JSONDecoder().decode(DYPublishResp.self, from: d) else { return false }
        return r.status == 200 && (r.code ?? 0) == 0
    }

    /// 发视频弹幕（offset 秒 = 出现在视频的哪个时间点）
    func postDanmaku(_ awemeID: String, text: String, offset: Double) async throws -> String {
        let d = try await call(Self.danmakuPostJS, args: ["id": awemeID, "text": text, "offset": String(Int(max(0, offset) * 1000))], attempts: 1)
        let r = try JSONDecoder().decode(DYPublishResp.self, from: d)
        DYLiveModel.log("DDSEND danmaku status=\(r.status) code=\(r.code ?? -1) msg=\(r.msg ?? "-") id=\(r.danmakuID ?? "-")")
        if r.code == 8 { throw DYError.bad("抖音未登录") }
        guard r.status == 200, (r.code ?? 0) == 0 else {
            throw DYError.bad(r.msg?.isEmpty == false ? r.msg! : "发送失败（HTTP \(r.status) / \(r.code ?? -1)）")
        }
        return r.danmakuID ?? UUID().uuidString
    }

    func deleteDanmaku(_ id: String) async -> Bool {
        guard let d = try? await call(Self.danmakuDeleteJS, args: ["did": id], attempts: 1),
              let r = try? JSONDecoder().decode(DYPublishResp.self, from: d) else { return false }
        return r.status == 200 && (r.code ?? 0) == 0
    }

    private static let cmap = #"""
    const cmap = c => c ? ({ id: String(c.cid), text: c.text || '', name: (c.user && c.user.nickname) || '', avatar: c.user && first(c.user.avatar_thumb),
      digg: c.digg_count || 0, time: c.create_time || Math.floor(Date.now() / 1000), replies: 0, ip: c.ip_label || null }) : null;
    """#

    // 网页版同款：params 放 app_name/enter_from，body 放 aweme_id/text（安全 SDK 会自动补签名头）
    static let publishJS = cmap + #"""
    const P = q({ app_name: 'aweme', enter_from: 'video_detail', previous_page: 'video_detail' });
    const body = new URLSearchParams({ aweme_id: id, text: text, text_extra: '[]', comment_send_celltime: '0', comment_video_celltime: '0' });
    if (reply && reply !== '0') { body.set('reply_id', reply); body.set('reply_to_reply_id', '0'); }
    const r = await req('POST', '/aweme/v1/web/comment/publish?' + P, body.toString());
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || (r.s === 200 ? null : (r.t || '').slice(0, 80)), comment: cmap(d.comment), danmakuID: null });
    """#

    static let deleteCommentJS = #"""
    const r = await req('POST', '/aweme/v1/web/comment/delete?' + q({ cid: cid, channel_id: '0', app_name: 'aweme' }), '');
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || null, comment: null, danmakuID: null });
    """#

    static let danmakuPostJS = #"""
    const r = await req('POST', '/aweme/v1/web/danmaku/post_v2/?' + q({ item_id: id, offset_time: offset, text: text, user_id: '', enter_from: 'video_detail', previous_page: 'video_detail' }), '');
    const d = parse(r.t) || {};
    const dm = d.danmaku || d.data || {};
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || (r.s === 200 ? null : (r.t || '').slice(0, 80)), comment: null,
      danmakuID: dm.danmaku_id ? String(dm.danmaku_id) : (d.danmaku_id ? String(d.danmaku_id) : null) });
    """#

    static let danmakuDeleteJS = #"""
    const r = await req('POST', '/aweme/v1/web/danmaku/delete_v2/?' + q({ app_name: 'aweme', format: 'json', user_type: '1', danmaku_id: did }), '');
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || null, comment: null, danmakuID: null });
    """#

    // MARK: JS（requestJS 里有 req / base / parse / first / q / mapA）

    private static let listTail = #"""
    const pack = (r, d, arr, cur, more) => JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || (r.s === 200 ? null : (r.t || '').slice(0, 80)),
      items: (arr || []).filter(a => a && (a.video || a.images) && !a.is_ads).map(mapA), cursor: String(cur ?? 0), hasMore: !!more });
    """#

    private static let userMap = #"""
    const umap = u => u ? ({ name: u.nickname || '', avatar: first(u.avatar_larger) || first(u.avatar_thumb), signature: u.signature || '',
      secUid: u.sec_uid || '', followers: u.follower_count || u.mplatform_followers_count || 0, following: u.following_count || 0,
      likes: u.total_favorited || 0, works: u.aweme_count || 0, ip: u.ip_location || null,
      followStatus: (u.follow_status != null) ? u.follow_status : null }) : null;
    """#

    static let selfJS = userMap + #"""
    const r = await req('GET', '/aweme/v1/web/user/profile/self/?' + q({ publish_video_strategy_type: '2', source: 'channel_pc_web', personal_center_strategy: '1' }));
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, user: umap(d.user), msg: d.status_msg || null });
    """#

    static let otherJS = userMap + #"""
    const r = await req('GET', '/aweme/v1/web/user/profile/other/?' + q({ sec_user_id: sec, publish_video_strategy_type: '2', personal_center_strategy: '1' }));
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, user: umap(d.user), msg: d.status_msg || null });
    """#

    static let likeJS = listTail + #"""
    const r = await req('GET', '/aweme/v1/web/aweme/favorite/?' + q({ sec_user_id: sec, max_cursor: cursor, min_cursor: '0', count: '18', cut_version: '1' }));
    const d = parse(r.t) || {};
    return pack(r, d, d.aweme_list, d.max_cursor, d.has_more);
    """#

    static let postJS = listTail + #"""
    const r = await req('GET', '/aweme/v1/web/aweme/post/?' + q({ sec_user_id: sec, max_cursor: cursor, locate_query: 'false', show_live_replay_strategy: '1',
      need_time_list: cursor === '0' ? '1' : '0', time_list_query: '0', whale_cut_token: '', cut_version: '1', count: '18', publish_video_strategy_type: '2' }));
    const d = parse(r.t) || {};
    return pack(r, d, d.aweme_list, d.max_cursor, d.has_more);
    """#

    static let collectJS = listTail + #"""
    const r = await req('POST', '/aweme/v1/web/aweme/listcollection/?' + q({ cursor: cursor, count: '18' }), 'count=18&cursor=' + cursor);
    const d = parse(r.t) || {};
    return pack(r, d, d.aweme_list, d.cursor, d.has_more);
    """#

    static let historyJS = listTail + #"""
    const r = await req('GET', '/aweme/v1/web/history/read/?' + q({ max_cursor: cursor, count: '20' }));
    const d = parse(r.t) || {};
    return pack(r, d, d.aweme_list, d.max_cursor, d.has_more);
    """#

    static let laterJS = listTail + #"""
    const r = await req('GET', '/aweme/v1/web/watchlater/list/?' + q({ cursor: cursor, count: '20', offset: cursor }));
    const d = parse(r.t) || {};
    const arr = (d.items || []).map(x => x && (x.aweme || x.aweme_info || x)).filter(Boolean);
    return pack(r, d, arr, (d.offset ?? 0), d.has_more);
    """#

    static let followJS = listTail + #"""
    const r = await req('GET', '/aweme/v1/web/follow/feed/?' + q({ cursor: cursor, level: '1', count: '20', pull_type: cursor === '0' ? '0' : '2' }));
    const d = parse(r.t) || {};
    const arr = (d.data || []).map(x => x && (x.aweme || x.aweme_info)).filter(Boolean);
    return pack(r, d, arr, d.cursor, d.has_more);
    """#

    static let searchJS = listTail + #"""
    const r = await req('GET', '/aweme/v1/web/search/item/?' + q({ search_channel: 'aweme_video_web', keyword: kw, search_source: 'normal_search',
      query_correct_type: '1', is_filter_search: '0', from_group_id: '', offset: cursor, count: '24', need_filter_settings: cursor === '0' ? '1' : '0', list_type: 'single' }));
    const d = parse(r.t) || {};
    const arr = (d.data || []).map(x => x && (x.aweme_info || x.aweme)).filter(Boolean);
    return pack(r, d, arr, d.cursor, d.has_more);
    """#

    static let sugJS = #"""
    const r = await req('GET', '/aweme/v1/web/search/sug/?' + q({ keyword: kw, source: 'aweme_video_web', from_group_id: '' }));
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, items: (d.sug_list || []).map(s => ({ word: s.content || '' })).filter(s => s.word) });
    """#

    static let danmakuJS = #"""
    const r = await req('GET', '/aweme/v1/web/danmaku/get_v2/?' + q({ app_name: 'aweme', format: 'json', group_id: id, item_id: id, start_time: '0', end_time: dur, duration: dur }));
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, items: (d.danmaku_list || []).filter(x => x && x.text).map(x => ({ id: String(x.danmaku_id), text: x.text, offset: (x.offset_time || 0) / 1000 })) });
    """#

    static let replyJS = #"""
    let r = await req('GET', '/aweme/v2/web/comment/list/reply/?' + q({ item_id: id, comment_id: cid, cut_version: '1', cursor: cursor, count: '10', item_type: '0' }));
    let d = parse(r.t);
    if (!d || !Array.isArray(d.comments)) {
      r = await req('GET', '/aweme/v1/web/comment/list/reply/?' + q({ item_id: id, comment_id: cid, cut_version: '1', cursor: cursor, count: '10', item_type: '0' }));
      d = parse(r.t);
    }
    if (!d) {
      r = await req('GET', '/aweme/v1/web/comment/list/reply/?' + q({ item_id: id, comment_id: cid, cursor: cursor, count: '10', item_type: '0', whale_cut_token: '', cut_version: '1', rcFT: '' }));
      d = parse(r.t);
    }
    if (!d) return JSON.stringify({ status: r.s === 200 ? 403 : r.s, items: [], cursor: 0, hasMore: false, msg: '抖音没返回回复（网页接口受限）' });
    const items = (d.comments || []).map(c => ({
      id: String(c.cid), text: c.text || '', name: (c.user && c.user.nickname) || '', avatar: c.user && first(c.user.avatar_thumb),
      digg: c.digg_count || 0, time: c.create_time || 0, replies: 0, ip: c.ip_label || null }));
    return JSON.stringify({ status: r.s, items, cursor: d.cursor || 0, hasMore: !!d.has_more, msg: null });
    """#
}

/// 当前在播视频的进度（PlayerPage 周期性写入；发弹幕时取）
@MainActor enum DDNowPlaying {
    static var id = ""
    static var time: Double = 0
}

// MARK: - 弹幕层（视频）

/// 弹幕时钟：播放器每 0.25 秒报一次进度，弹幕按帧插值出「现在」的视频时间，否则位置一跳一跳。
/// 播放器报一次就校准一次（锚点 = 报的时间 + 报的时刻），中间按播放速率往前推。
struct DYDanmakuClock {
    var anchorTime: Double = 0
    var anchorDate = Date()
    var rate: Double = 1
    var playing = false

    func now(_ d: Date) -> Double {
        playing ? anchorTime + d.timeIntervalSince(anchorDate) * rate : anchorTime
    }

    mutating func sync(_ t: Double, playing p: Bool, rate r: Double) {
        let predicted = now(Date())
        // 进度跳了（拖动 / 循环回开头 / 卡顿）或状态变了：直接对齐；否则差不多就别动，避免往回抖
        if !p || !playing || r != rate || abs(predicted - t) > 0.35 {
            anchorTime = t
        } else {
            anchorTime = predicted + (t - predicted) * 0.2   // 小误差慢慢拉回
        }
        anchorDate = Date()
        playing = p
        rate = r
    }
}

/// 抖音同款滚动弹幕：所有弹幕同一速度从右往左飘（同速 → 同一轨道里后面的永远追不上前面的）。
/// 轨道按「前一条尾巴已经完全进屏 + 间距」分配，整条视频一次排好（布局只在弹幕列表 / 屏幕宽变化时重算）；
/// 某个时刻所有轨道都满就丢掉这一条（抖音也是这样）。
/// 位置用 TimelineView(.animation) 逐帧算（跟屏幕刷新率走，ProMotion 上 120Hz），不靠 SwiftUI 补间动画。
struct DYDanmakuLayer: View {
    let items: [DYDanmaku]
    let clock: DYDanmakuClock
    let topInset: CGFloat
    private static let laneHeight: CGFloat = 28
    private static let gap: CGFloat = 28

    fileprivate struct Placed { let d: DYDanmaku; let lane: Int; let width: CGFloat; let dur: Double }

    private var renderItems: [DYDanmaku] {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_DM_STRESS"] == "1" {
            return (0..<600).map { DYDanmaku(id: "stress-\($0)", text: "弹幕流畅度测试 \($0)", offset: Double($0) * 0.15) }
        }
        #endif
        return items
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let lanes = min(10, max(3, Int(g.size.height * 0.4 / Self.laneHeight)))
            let speed = Self.speed(w)
            let placed = DYDanmakuLayout.shared.get(renderItems, w: w, lanes: lanes, speed: speed)
            TimelineView(.animation(minimumInterval: nil, paused: !clock.playing)) { ctx in
                let t = clock.now(ctx.date)
                Canvas(rendersAsynchronously: false) { gc, _ in
                    for p in placed where t >= p.d.offset && t <= p.d.offset + p.dur {
                        let x = w - CGFloat(t - p.d.offset) * speed
                        let y = topInset + 64 + CGFloat(p.lane) * Self.laneHeight
                        guard let sym = gc.resolveSymbol(id: p.d.id) else { continue }
                        gc.draw(sym, at: CGPoint(x: x, y: y), anchor: .topLeading)
                    }
                } symbols: {
                    // 每条弹幕只排版一次（文字 + 阴影），之后每帧只是贴图挪位置，开销很小
                    ForEach(placed, id: \.d.id) { p in
                        Text(p.d.text)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .shadow(color: .black.opacity(0.7), radius: 1.5, y: 1)
                            .lineLimit(1)
                            .fixedSize()
                            .tag(p.d.id)
                    }
                }
            }
            .frame(width: w, height: g.size.height)
        }
        .allowsHitTesting(false)
    }

    /// 屏幕宽 + 一段余量，约 7 秒飘完
    fileprivate static func speed(_ w: CGFloat) -> CGFloat { (w + 200) / 7 }

    /// 宽度估算（偏大一点，宁可多留空）：中文 / 全角 16pt，英文数字 9pt
    fileprivate static func textWidth(_ s: String) -> CGFloat {
        s.unicodeScalars.reduce(0) { $0 + ($1.value < 0x2E80 ? 9 : 16) } + 6
    }

    fileprivate static func layout(_ items: [DYDanmaku], w: CGFloat, lanes: Int, speed: CGFloat) -> [Placed] {
        var free = Array(repeating: -Double.infinity, count: lanes)
        var out: [Placed] = []
        for d in items.sorted(by: { $0.offset < $1.offset }) {
            let tw = textWidth(d.text)
            guard let l = free.indices.first(where: { free[$0] <= d.offset }) else { continue }
            free[l] = d.offset + Double((tw + gap) / speed)
            out.append(Placed(d: d, lane: l, width: tw, dur: Double((w + tw) / speed)))
        }
        return out
    }
}

/// 布局缓存：同一批弹幕 + 同一屏宽只算一次（body 每次刷新不重排）
@MainActor private final class DYDanmakuLayout {
    static let shared = DYDanmakuLayout()
    private var key = ""
    private var cache: [DYDanmakuLayer.Placed] = []
    func get(_ items: [DYDanmaku], w: CGFloat, lanes: Int, speed: CGFloat) -> [DYDanmakuLayer.Placed] {
        let k = "\(items.count)|\(items.first?.id ?? "")|\(items.last?.id ?? "")|\(Int(w))|\(lanes)"
        if k != key { key = k; cache = DYDanmakuLayer.layout(items, w: w, lanes: lanes, speed: speed) }
        return cache
    }
}

// MARK: - 保存到相册

enum DYSaver {
    enum SaveError: LocalizedError {
        case denied, noURL
        var errorDescription: String? {
            switch self {
            case .denied: "没有相册权限：设置 → DouDuo → 照片 → 允许添加"
            case .noURL: "这条没有可下载的地址"
            }
        }
    }

    static func save(_ a: DYAweme) async throws {
        let st = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard st == .authorized || st == .limited else { throw SaveError.denied }
        if !a.images.isEmpty {
            var datas: [Data] = []
            for s in a.images { if let u = URL(string: s) { datas.append(try await download(u)) } }
            try await PHPhotoLibrary.shared().performChanges {
                for d in datas { PHAssetCreationRequest.forAsset().addResource(with: .photo, data: d, options: nil) }
            }
            return
        }
        guard let s = a.play, let u = URL(string: s) else { throw SaveError.noURL }
        let data = try await download(u)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dd-\(a.id).mp4")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file, options: nil)
        }
    }

    private static func download(_ u: URL) async throws -> Data {
        var r = URLRequest(url: u)
        DYMedia.headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
        let (d, resp) = try await URLSession.shared.data(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw DYError.bad("下载失败 HTTP \(h.statusCode)") }
        return d
    }
}

// MARK: - 封面网格（搜索 / 我的 / 作者）

struct DYGrid: View {
    let items: [DYAweme]
    let hasMore: Bool
    let loading: Bool
    let error: String?
    let onLoadMore: () -> Void
    let onOpen: (Int) -> Void
    private let cols = [GridItem(.adaptive(minimum: 140), spacing: 2)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: cols, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, a in
                    Button { onOpen(i) } label: { cell(a) }
                        .buttonStyle(.plain)
                        .onAppear { if i >= items.count - 6 { onLoadMore() } }
                }
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center).padding(24)
            } else if loading {
                ProgressView().tint(.white).padding(24)
            } else if items.isEmpty {
                Text("这里还没有内容").font(.footnote).foregroundStyle(.white.opacity(0.6)).padding(40)
            } else if hasMore {
                Color.clear.frame(height: 40).onAppear(perform: onLoadMore)
            }
        }
    }

    private func cell(_ a: DYAweme) -> some View {
        Color.black.opacity(0.4)
            .aspectRatio(3/4, contentMode: .fit)
            .overlay {
                CachedAsyncImage(url: a.cover.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() }
                    placeholder: { Color.white.opacity(0.06) }
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if !a.images.isEmpty {
                    Image(systemName: "photo.on.rectangle").font(.caption).foregroundStyle(.white).padding(6)
                        .shadow(radius: 2)
                }
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    if !a.desc.isEmpty {
                        Text(a.desc).font(.caption2).lineLimit(2)
                    }
                    Label(DYFormat.count(a.stats.digg), systemImage: "heart").font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 2)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            }
            .contentShape(Rectangle())
    }
}

// MARK: - 列表播放器（从网格点进来，上下滑接着看）

struct DYListPlayer: View {
    let bridge: DouyinBridge
    let title: String
    @State var items: [DYAweme]
    @State private var currentID: String?
    let loadMore: (() async -> [DYAweme])?
    let onAuthor: (DYAweme) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var preloader = DYPreloader()
    @State private var resume: [String: Double] = [:]
    @State private var liked: Set<String> = []
    @State private var collected: Set<String> = []
    @State private var showComments = false
    @State private var wideNow = false
    @State private var author: DYAweme.Author?
    @State private var toast: String?
    @State private var loadingMore = false
    @State private var shareTarget: DYAweme?
    @Environment(\.dyIM) private var im

    init(bridge: DouyinBridge, title: String, items: [DYAweme], start: Int,
         loadMore: (() async -> [DYAweme])? = nil, onAuthor: @escaping (DYAweme) -> Void) {
        self.bridge = bridge; self.title = title
        _items = State(initialValue: items)
        _currentID = State(initialValue: items.indices.contains(start) ? items[start].id : items.first?.id)
        self.loadMore = loadMore; self.onAuthor = onAuthor
        var l = Set<String>(), c = Set<String>()
        for a in items { if a.userDigged == 1 { l.insert(a.id) }; if a.isCollect == 1 { c.insert(a.id) } }
        _liked = State(initialValue: l); _collected = State(initialValue: c)
    }

    private var current: DYAweme? { items.first { $0.id == currentID } }

    var body: some View {
        GeometryReader { geo in
            // 和推荐页一样：Duo 内屏（短边 >= 600）横竖都左右分屏放评论，外屏从底部弹出
            let wide = min(geo.size.width, geo.size.height) >= 600
            HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            DYVideoPage(item: item, isCurrent: item.id == currentID && author == nil, insets: geo.safeAreaInsets,
                                        resume: resume[item.id], liked: liked.contains(item.id), collected: collected.contains(item.id),
                                        onLike: { toggleLike(item.id, force: nil) }, onCollect: { toggleCollect(item.id) },
                                        onDoubleTap: { toggleLike(item.id, force: true) },
                                        onComments: { showComments = true },
                                        onAuthor: { author = item.author },
                                        onSavePosition: { resume[item.id] = $0 }, preloader: preloader,
                                        bridge: bridge, onToast: { show($0) },
                                        onShare: im == nil ? nil : { shareTarget = item })
                                .containerRelativeFrame([.horizontal, .vertical])
                                .id(item.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentID, anchor: .center)
                .scrollIndicators(.hidden)
                .ignoresSafeArea()

                HStack(spacing: 10) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left").font(.headline.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: 40, height: 40).background(Circle().fill(.black.opacity(0.35)))
                    }
                    .accessibilityIdentifier("douyin.list.back")
                    Text(title).font(.headline).foregroundStyle(.white).shadow(radius: 3)
                }
                .padding(.leading, 22).padding(.top, 10)

                if let t = toast {
                    Text(t).font(.footnote.weight(.medium)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(.black.opacity(0.62)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .sheet(isPresented: Binding(get: { showComments && !wide }, set: { v in
                if v { showComments = true } else { DispatchQueue.main.async { if !wideNow { showComments = false } } }
            })) {
                if let cur = current {
                    DYCommentPanel(bridge: bridge, aweme: cur, onClose: { showComments = false }, horizontalDismiss: false)
                        .presentationDetents([.fraction(0.62), .large])
                }
            }
            if wide && showComments, let cur = current {
                DYSideComments(bridge: bridge, aweme: cur, width: min(380, geo.size.width * 0.36), open: $showComments)
                    .id(cur.id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            }
            .onChange(of: wide, initial: true) { _, w in wideNow = w }
        }
        .dyAuthorOverlay($author, bridge: bridge)
        // b50：朋友发来的视频 / 搜索 / 我的 / 作者主页里点开的视频，转发也是「发给朋友」（和推荐页同一个面板）
        .sheet(item: $shareTarget) { a in
            if let im {
                DYFriendPicker(im: im, title: "发送给朋友") { friend in
                    show("发送中…")
                    Task { if await im.shareVideo(a.id, to: friend) { show("已分享给 \(friend.name)") } else { show(im.lastSendError ?? "没发出去") } }
                }
                .presentationDetents([.medium, .large])
                .presentationBackground(Color(red: 0.12, green: 0.12, blue: 0.13))
            }
        }
        .statusBarHidden(true)
        .edgeSwipeBack { dismiss() }
        .onChange(of: currentID) { old, new in
            if new == nil, let old { currentID = old; return }
            guard let i = items.firstIndex(where: { $0.id == new }) else { return }
            preloader.update(items, current: i)
            if i >= items.count - 4, let loadMore, !loadingMore {
                loadingMore = true
                Task {
                    let more = await loadMore()
                    let seen = Set(items.map(\.id))
                    items.append(contentsOf: more.filter { !seen.contains($0.id) })
                    loadingMore = false
                }
            }
        }
        .onAppear { if let i = items.firstIndex(where: { $0.id == currentID }) { preloader.update(items, current: i) } }
        .onDisappear { preloader.clear() }
    }

    private func show(_ s: String) {
        toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if toast == s { toast = nil } }
    }

    private func toggleLike(_ id: String, force: Bool?) {
        let has = liked.contains(id), want = force ?? !has
        guard want != has else { return }
        if want { liked.insert(id) } else { liked.remove(id) }
        Task {
            let r = try? await bridge.digg(id, like: want)
            if case .ok = r { return }
            if want { liked.remove(id) } else { liked.insert(id) }
            show(r.map { if case .notLoggedIn = $0 { return "抖音未登录" } else { return "点赞失败" } } ?? "点赞失败")
        }
    }

    private func toggleCollect(_ id: String) {
        let want = !collected.contains(id)
        if want { collected.insert(id) } else { collected.remove(id) }
        Task {
            let r = try? await bridge.favorite(id, add: want)
            if case .ok = r { show(want ? "已收藏" : "已取消收藏"); return }
            if want { collected.remove(id) } else { collected.insert(id) }
            show("收藏失败")
        }
    }
}

// MARK: - 通用分页列表模型

@MainActor
final class DYPagedModel: ObservableObject {
    @Published var items: [DYAweme] = []
    @Published var loading = false
    @Published var error: String?
    @Published var hasMore = true
    private var cursor = "0"
    private let fetch: (String) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool)

    init(fetch: @escaping (String) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool)) {
        self.fetch = fetch
    }

    func reset() { items = []; cursor = "0"; hasMore = true; error = nil }

    @discardableResult
    func loadMore() async -> [DYAweme] {
        guard !loading, hasMore else { return [] }
        loading = true
        defer { loading = false }
        do {
            let r = try await fetch(cursor)
            let seen = Set(items.map(\.id))
            let fresh = r.items.filter { !seen.contains($0.id) && ($0.play != nil || !$0.images.isEmpty) }
            items.append(contentsOf: fresh)
            hasMore = r.hasMore && !r.items.isEmpty && r.cursor != cursor
            cursor = r.cursor
            error = nil
            return fresh
        } catch {
            self.error = error.localizedDescription
            hasMore = false
            return []
        }
    }
}

struct DYListTarget: Identifiable {
    let id = UUID()
    let title: String
    let items: [DYAweme]
    let start: Int
    let model: DYPagedModel?
    /// 还没取详情的视频 id（聊天串播用，滑到后面再取）
    var more: [String] = []
}

// MARK: - 搜索

struct DYSearchScreen: View {
    let bridge: DouyinBridge
    let onAuthor: (DYAweme) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kw = ""
    @State private var sugs: [DYSug] = []
    @State private var model: DYPagedModel?
    @State private var open: DYListTarget?
    @State private var sugTask: Task<Void, Never>?
    @State private var lastRun = ""
    @FocusState private var focused: Bool
    @AppStorage("douyin_search_history_v1") private var historyRaw = ""

    private var history: [String] { historyRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        screenBody.swipeBack { dismiss() }
    }

    private var screenBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.headline.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("douyin.search.back")
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                    TextField("", text: $kw, prompt: Text("搜索视频").foregroundStyle(.white.opacity(0.45)))
                        .foregroundStyle(.white)
                        .focused($focused)
                        .submitLabel(.search)
                        .onSubmit { run(kw) }
                        .accessibilityIdentifier("douyin.search.field")
                    if !kw.isEmpty {
                        Button { kw = ""; model = nil; focused = true } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                .padding(.horizontal, 12).frame(height: 38)
                .background(Capsule().fill(.white.opacity(0.12)))
                Button("搜索") { run(kw) }.foregroundStyle(.white).font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            if let model {
                DYSearchResults(model: model, onOpen: { i in
                    open = DYListTarget(title: "搜索：\(kw)", items: model.items, start: i, model: model)
                })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !sugs.isEmpty && !kw.isEmpty {
                            ForEach(sugs) { s in
                                Button { kw = s.word; run(s.word) } label: {
                                    HStack {
                                        Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.45))
                                        Text(s.word).foregroundStyle(.white)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } else if !history.isEmpty {
                            HStack {
                                Text("搜索历史").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                Spacer()
                                Button("清空") { historyRaw = "" }.font(.caption).foregroundStyle(.white.opacity(0.6))
                            }
                            .padding(16)
                            FlowTags(tags: history) { w in kw = w; run(w) }
                                .padding(.horizontal, 16)
                        }
                    }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            focused = true
            #if DEBUG
            if let w = ProcessInfo.processInfo.environment["DOUDUO_SEARCHKW"] { run(w) }
            else if ProcessInfo.processInfo.environment["DOUDUO_SEARCHCAT"] == "1" { run("猫") }
            #endif
        }
        .onChange(of: kw) { _, v in
            sugTask?.cancel()
            guard !v.trimmingCharacters(in: .whitespaces).isEmpty else { sugs = []; return }
            if v == lastRun { return }
            if model != nil { model = nil }
            sugTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                let r = await bridge.suggest(v)
                if !Task.isCancelled { sugs = r }
            }
        }
        .fullScreenCover(item: $open) { t in
            DYListPlayer(bridge: bridge, title: t.title, items: t.items, start: t.start,
                         loadMore: t.model.map { m in { await m.loadMore() } }, onAuthor: onAuthor)
        }
        }

    private func run(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        focused = false
        sugs = []
        lastRun = w
        kw = w
        var h = history.filter { $0 != w }
        h.insert(w, at: 0)
        historyRaw = h.prefix(15).joined(separator: "\n")
        let m = DYPagedModel { [bridge] cur in try await bridge.search(w, offset: cur) }
        model = m
        Task { await m.loadMore() }
    }
}

private struct DYSearchResults: View {
    @ObservedObject var model: DYPagedModel
    let onOpen: (Int) -> Void
    var body: some View {
        DYGrid(items: model.items, hasMore: model.hasMore, loading: model.loading, error: model.error,
               onLoadMore: { Task { await model.loadMore() } }, onOpen: onOpen)
    }
}

/// 标签流式排版（搜索历史）
struct FlowTags: View {
    let tags: [String]
    let onTap: (String) -> Void
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(tags, id: \.self) { t in
                Button { onTap(t) } label: {
                    Text(t).font(.subheadline).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 360
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > w, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += sz.width + spacing; row = max(row, sz.height)
        }
        return CGSize(width: w, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; row = max(row, sz.height)
        }
    }
}

// MARK: - 我的

struct DYMineScreen: View {
    let bridge: DouyinBridge
    let onLogin: () -> Void
    let onAuthor: (DYAweme) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var user: DYUser?
    @State private var userErr: String?
    @State private var kind: DYListKind = .like
    @State private var models: [DYListKind: DYPagedModel] = [:]
    @State private var open: DYListTarget?

    var body: some View {
        screenBody.swipeBack { dismiss() }
    }

    private var screenBody: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.headline.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("douyin.mine.back")
                Spacer()
                Button("网页版 / 登录", systemImage: "safari") { onLogin() }
                    .font(.footnote).foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 8)

            header.padding(.horizontal, 16).padding(.bottom, 12)

            HStack(spacing: 22) {
                ForEach(DYListKind.allCases) { k in
                    Button { kind = k } label: {
                        VStack(spacing: 5) {
                            Text(k.title).font(.subheadline.weight(kind == k ? .bold : .medium))
                                .foregroundStyle(.white.opacity(kind == k ? 1 : 0.6))
                            Capsule().fill(.white).frame(width: 18, height: 2.5).opacity(kind == k ? 1 : 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("douyin.mine.\(k.rawValue)")
                }
            }
            .padding(.bottom, 6)

            if let m = models[kind] {
                DYMineList(model: m) { i in
                    open = DYListTarget(title: kind.title, items: m.items, start: i, model: m)
                }
                .id(kind)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .task {
            do { user = try await bridge.selfProfile() } catch { userErr = error.localizedDescription }
        }
        .onAppear { ensure(kind) }
        .onChange(of: kind) { _, k in ensure(k) }
        .fullScreenCover(item: $open) { t in
            DYListPlayer(bridge: bridge, title: t.title, items: t.items, start: t.start,
                         loadMore: t.model.map { m in { await m.loadMore() } }, onAuthor: onAuthor)
        }
        }

    private func ensure(_ k: DYListKind) {
        guard models[k] == nil else { return }
        let m = DYPagedModel { [bridge] cur in try await bridge.myList(k, cursor: cur) }
        models[k] = m
        Task { await m.loadMore() }
    }

    @ViewBuilder
    private var header: some View {
        if let u = user {
            DYUserHeader(user: u)
        } else if let e = userErr {
            VStack(spacing: 10) {
                Text(e.contains("未登录") ? "还没登录抖音" : e).foregroundStyle(.white.opacity(0.8)).font(.subheadline)
                Button("去登录") { onLogin() }.buttonStyle(.borderedProminent).tint(.pink)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
        } else {
            ProgressView().tint(.white).frame(height: 80)
        }
    }
}

private struct DYMineList: View {
    @ObservedObject var model: DYPagedModel
    let onOpen: (Int) -> Void
    var body: some View {
        DYGrid(items: model.items, hasMore: model.hasMore, loading: model.loading, error: model.error,
               onLoadMore: { Task { await model.loadMore() } }, onOpen: onOpen)
    }
}

struct DYUserHeader: View {
    let user: DYUser
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                CachedAsyncImage(url: user.avatar.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() }
                    placeholder: { Color.white.opacity(0.1) }
                    .frame(width: 72, height: 72).clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(user.name).font(.title3.weight(.bold)).foregroundStyle(.white)
                    if let ip = user.ip, !ip.isEmpty {
                        Text(ip).font(.caption).foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            HStack(spacing: 20) {
                stat(user.likes, "获赞"); stat(user.following, "关注"); stat(user.followers, "粉丝"); stat(user.works, "作品")
            }
            if !user.signature.isEmpty {
                Text(user.signature).font(.footnote).foregroundStyle(.white.opacity(0.75)).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func stat(_ n: Int, _ t: String) -> some View {
        HStack(spacing: 4) {
            Text(DYFormat.count(n)).font(.subheadline.weight(.bold)).foregroundStyle(.white)
            Text(t).font(.caption).foregroundStyle(.white.opacity(0.6))
        }
    }
}

// MARK: - 作者主页
// b49：原来是半屏资料卡 + 「查看全部作品」跳网页版。改成和手机抖音一样：从右边滑进来的全屏主页，
// 上面头像 / 简介 / 数据，下面作品九宫格（往下滑自动加载更多），点格子上下刷这个作者的视频；
// 右滑跟手返回（方向锁定，上下刷九宫格不会误退）。

struct DYAuthorScreen: View {
    let bridge: DouyinBridge
    let author: DYAweme.Author
    let onClose: () -> Void
    @State private var user: DYUser?
    @State private var err: String?
    @StateObject private var posts: DYPagedModel
    @State private var open: DYListTarget?
    @State private var dragX: CGFloat = 0
    @State private var axis = 0
    /// b50：关注按钮。nil = 还不知道（接口没回来），按作者卡片带的状态先显示
    @State private var following: Bool?
    @State private var followBusy = false
    @State private var confirmUnfollow = false
    @State private var toast: String?

    init(bridge: DouyinBridge, author: DYAweme.Author, onClose: @escaping () -> Void) {
        self.bridge = bridge; self.author = author; self.onClose = onClose
        let sec = author.secUid ?? ""
        _posts = StateObject(wrappedValue: DYPagedModel { cur in
            guard !sec.isEmpty else { throw DYError.bad("没有作者信息") }
            return try await bridge.userPosts(sec, cursor: cur)
        })
    }

    var body: some View {
        GeometryReader { g in
            screenBody
                .frame(width: g.size.width, height: g.size.height)
                .offset(x: dragX)
                .simultaneousGesture(DragGesture(minimumDistance: 14, coordinateSpace: .global)
                    .onChanged { v in
                        if axis == 0 { axis = abs(v.translation.width) > abs(v.translation.height) * 2.2 ? 1 : 2 }
                        guard axis == 1 else { return }
                        dragX = max(0, v.translation.width)
                    }
                    .onEnded { v in
                        let wasH = axis == 1
                        axis = 0
                        guard wasH else { return }
                        let fast = v.predictedEndTranslation.width - v.translation.width > 160
                        if v.translation.width > g.size.width * 0.3 || (v.translation.width > 40 && fast) {
                            withAnimation(.snappy(duration: 0.22)) { dragX = g.size.width } completion: { onClose() }
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { dragX = 0 }
                        }
                    })
        }
        .fullScreenCover(item: $open) { t in
            DYListPlayer(bridge: bridge, title: t.title, items: t.items, start: t.start,
                         loadMore: t.model.map { m in { await m.loadMore() } }, onAuthor: { _ in })
        }
    }

    private var screenBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { withAnimation(.snappy(duration: 0.28)) { onClose() } } label: {
                    Image(systemName: "chevron.left").font(.headline.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("douyin.author.back")
                Text(user?.name ?? author.name).font(.headline).foregroundStyle(.white).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            Group {
                if let u = user {
                    DYUserHeader(user: u)
                } else if let err {
                    Text(err).foregroundStyle(.white.opacity(0.7)).font(.footnote)
                } else {
                    ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 80)
                }
            }
            .padding(.horizontal, 16)
            if user != nil, author.secUid != nil { followButton.padding(.horizontal, 16) }
            HStack(spacing: 6) {
                Text("作品").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                if let u = user, u.works > 0 {
                    Text(DYFormat.count(u.works)).font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 16)
            DYMineList(model: posts) { i in
                open = DYListTarget(title: user?.name ?? author.name, items: posts.items, start: i, model: posts)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 外屏右边有摄像头安全区（约 84pt），九宫格和视频一样铺满，不然只占左边 80%、只排得下两列
            .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.ignoresSafeArea())
        .overlay {
            if let t = toast {
                Text(t).font(.footnote.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.72)))
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: toast)
        .confirmationDialog("不再关注 \(user?.name ?? author.name)？", isPresented: $confirmUnfollow, titleVisibility: .visible) {
            Button("取消关注", role: .destructive) { setFollow(false) }
            Button("再想想", role: .cancel) {}
        }
        .task {
            guard let s = author.secUid else { err = "没有作者信息"; return }
            if let known = DYFollowState.shared.state[s] { following = known }
            async let p: Void = { _ = await posts.loadMore() }()
            do {
                let u = try await bridge.userProfile(s)
                user = u
                // 没登录时抖音接口的 follow_status 不可信（实测游客也会回 1）→ 只有真登录了才按接口显示「已关注」
                let logged = await DYSession.loggedIn()
                if following == nil {
                    let st = u.followStatus ?? author.followStatus ?? 0
                    // 刚在推荐页点过加号（或取消）的，以这次点的为准；接口有时慢半拍
                    following = DYFollowState.shared.state[s] ?? (logged && (st == 1 || st == 2))
                }
            } catch { err = error.localizedDescription }
            _ = await p
        }
    }

    /// 红色「关注」/ 灰色「已关注」，和抖音主页一样；点已关注先确认再取消，免得手滑
    private var followButton: some View {
        let on = following ?? false
        return Button {
            if on { confirmUnfollow = true } else { setFollow(true) }
        } label: {
            HStack(spacing: 6) {
                if followBusy { ProgressView().controlSize(.small).tint(.white) }
                else { Image(systemName: on ? "checkmark" : "plus").font(.subheadline.weight(.bold)) }
                Text(on ? "已关注" : "关注").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(on ? Color.white.opacity(0.14) : Color(red: 0.996, green: 0.173, blue: 0.333)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(followBusy)
        .animation(.snappy(duration: 0.22), value: on)
        .accessibilityIdentifier("douyin.author.follow")
    }

    private func setFollow(_ want: Bool) {
        guard let sec = author.secUid, !followBusy else { return }
        let before = following
        following = want; followBusy = true
        Task {
            var msg: String
            do {
                switch try await bridge.follow(sec, follow: want) {
                case .ok:
                    msg = want ? "已关注" : "已取消关注"
                    DYFollowState.shared.set(sec, want)
                case .notLoggedIn: following = before; msg = "抖音未登录：菜单 → 网页版 / 登录"
                case .failed(let why): following = before; msg = (want ? "关注失败：" : "取消失败：") + why
                }
            } catch { following = before; msg = (want ? "关注失败：" : "取消失败：") + error.localizedDescription }
            followBusy = false
            say(msg)
        }
    }

    private func say(_ s: String) {
        toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if toast == s { toast = nil } }
    }
}

/// 登录态：看 WebView 里有没有抖音的 sessionid（HttpOnly，网页 JS 读不到，原生这边能读到）
enum DYSession {
    @MainActor static func loggedIn() async -> Bool {
        let cs = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return cs.contains { $0.name == "sessionid" && $0.domain.contains("douyin") && !$0.value.isEmpty }
    }
}

/// b50：这次打开 App 里点过的关注 / 取消关注（推荐页加号、作者主页按钮共用同一份，两边永远对得上）
@MainActor
final class DYFollowState: ObservableObject {
    static let shared = DYFollowState()
    @Published private(set) var state: [String: Bool] = [:]
    func set(_ sec: String, _ on: Bool) {
        state[sec] = on
        NotificationCenter.default.post(name: .dyFollowChanged, object: nil, userInfo: ["sec": sec, "on": on])
    }
}

extension Notification.Name {
    /// 作者主页点了关注 / 取消关注 → 推荐页头像上的「+」同步
    static let dyFollowChanged = Notification.Name("dyFollowChanged")
}

extension View {
    /// 作者主页从右边滑进来（盖在当前页面上，不是弹窗）
    func dyAuthorOverlay(_ author: Binding<DYAweme.Author?>, bridge: DouyinBridge) -> some View {
        overlay {
            if let a = author.wrappedValue {
                DYAuthorScreen(bridge: bridge, author: a, onClose: {
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { author.wrappedValue = nil }
                })
                .transition(.move(edge: .trailing))
                .zIndex(10)
            }
        }
        .animation(.snappy(duration: 0.3), value: author.wrappedValue?.secUid)
    }
}

// MARK: - 关注流

struct DYFollowFeed: View {
    let bridge: DouyinBridge
    let insets: EdgeInsets
    /// 外面每加一就重新拉一遍（顶栏再点一次「关注」）
    var refresh: Int = 0
    let active: Bool
    let onAuthor: (DYAweme) -> Void
    let onLogin: () -> Void
    let onToast: (String) -> Void
    /// 分享给朋友（推荐页传进来，走同一个朋友选择器）
    var onShare: ((DYAweme) -> Void)? = nil
    /// 长按 2 倍速进 / 出（外层藏顶栏）
    var onBoost: ((Bool) -> Void)? = nil
    /// 分屏评论面板开 / 关：报给外层面板宽度（0 = 关），顶栏右侧按钮据此让位，不和叉号重叠
    var onCommentsPanel: ((CGFloat) -> Void)? = nil
    /// 铰链状态（外层传入）：半折叠时评论铺满折痕右边
    var hinge: DYHinge = .none
    @StateObject private var model: DYPagedModelHolder = DYPagedModelHolder()
    @State private var currentID: String?
    @State private var preloader = DYPreloader()
    @State private var resume: [String: Double] = [:]
    @State private var liked: Set<String> = []
    @State private var collected: Set<String> = []
    @State private var showComments = false
    @State private var hingeOpened = false
    @State private var wideNow = false

    var body: some View {
        let m = model.model(bridge)
        GeometryReader { geo in
        // 和推荐页 / 列表播放器一样：Duo 内屏（短边 >= 600）评论左右分屏，外屏从底部弹出（b45 之前这里只有底部弹出）
        let wide = min(geo.size.width, geo.size.height) >= 600
        HStack(spacing: 0) {
        ZStack {
            if m.items.isEmpty {
                VStack(spacing: 12) {
                    if let e = m.error {
                        Text(e).font(.footnote).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                        HStack {
                            Button("重试") { m.reset(); Task { await m.loadMore(); currentID = m.items.first?.id } }
                                .buttonStyle(.borderedProminent)
                            Button("登录") { onLogin() }.buttonStyle(.bordered)
                        }
                    } else if m.loading || m.hasMore {
                        ProgressView().tint(.white)
                        Text("加载关注…").font(.footnote).foregroundStyle(.white.opacity(0.7))
                    } else {
                        Text("关注的人还没有新作品").font(.footnote).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(m.items) { item in
                            DYVideoPage(item: item, isCurrent: active && item.id == currentID, insets: insets,
                                        resume: resume[item.id], liked: liked.contains(item.id) || item.userDigged == 1,
                                        collected: collected.contains(item.id) || item.isCollect == 1,
                                        onLike: { like(item.id, force: nil) }, onCollect: { collect(item.id) },
                                        onDoubleTap: { like(item.id, force: true) }, onComments: { withAnimation(.snappy) { showComments.toggle() } },
                                        onAuthor: { onAuthor(item) }, onSavePosition: { resume[item.id] = $0 },
                                        preloader: preloader, bridge: bridge, onToast: onToast,
                                        followed: true,
                                        onShare: onShare.map { f in { f(item) } },
                                        onBoost: onBoost,
                                        onEdgeBack: { if showComments { withAnimation(.snappy) { showComments = false } } })
                                .containerRelativeFrame([.horizontal, .vertical])
                                .id(item.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentID, anchor: .center)
                .scrollIndicators(.hidden)
                .ignoresSafeArea()
            }
        }
        if wide && showComments, let cur = m.items.first(where: { $0.id == currentID }) {
            DYSideComments(bridge: bridge, aweme: cur, width: geo.dyPanelWidth(hinge: hinge, commentsOpen: showComments),
                           open: $showComments, onClosed: { hingeOpened = false })
                .id(cur.id)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
        }
        .onChange(of: wide, initial: true) { _, w in wideNow = w }
        // b49：小屏切大屏不再把评论区丢掉（见推荐页同处说明）；小屏评论区不认横滑
        .sheet(isPresented: Binding(get: { showComments && !wide }, set: { v in
            if v { showComments = true } else { DispatchQueue.main.async { if !wideNow { showComments = false } } }
        })) {
            if let cur = m.items.first(where: { $0.id == currentID }) {
                DYCommentPanel(bridge: bridge, aweme: cur, onClose: { showComments = false }, horizontalDismiss: false)
                    .presentationDetents([.fraction(0.62), .large])
            }
        }
        .onChange(of: showComments) { _, open in onCommentsPanel?(open && wide ? geo.dyPanelWidth(hinge: hinge, commentsOpen: true) : 0) }
        .onChange(of: wide) { _, w in onCommentsPanel?(showComments && w ? geo.dyPanelWidth(hinge: hinge, commentsOpen: true) : 0) }
        .onChange(of: hinge) { old, new in
            // 半折叠：评论区自动跑出来；展平 / 合上时把自动打开的收回
            // b49：外层已做停稳判定，这里和外层用同一条弹簧，评论区和宽度一次到位
            withAnimation(DYHingeAnim.layout) {
                if new.isHalfOpen, !showComments { showComments = true; hingeOpened = true }
                else if old.isHalfOpen, !new.isHalfOpen, hingeOpened { showComments = false; hingeOpened = false }
            }
            onCommentsPanel?(showComments && wide ? geo.dyPanelWidth(hinge: new, commentsOpen: true) : 0)
        }
        }
        .task {
            if m.items.isEmpty { await m.loadMore() }
            if currentID == nil { currentID = m.items.first?.id }
        }
        .onChange(of: refresh) { _, _ in
            onToast("正在刷新关注…")
            preloader.clear(); m.reset(); currentID = nil
            Task { await m.loadMore(); currentID = m.items.first?.id; onToast(m.items.isEmpty ? (m.error ?? "关注的人还没有新作品") : "关注已刷新") }
        }
        .onChange(of: currentID) { old, new in
            if new == nil, let old, m.items.contains(where: { $0.id == old }) { currentID = old; return }
            guard let i = m.items.firstIndex(where: { $0.id == new }) else { return }
            preloader.update(m.items, current: i)
            if i >= m.items.count - 4 { Task { await m.loadMore() } }
        }
        .onChange(of: active) { _, a in if !a { preloader.clear() } }
        .onDisappear { preloader.clear() }
    }

    private func like(_ id: String, force: Bool?) {
        let has = liked.contains(id), want = force ?? !has
        guard want != has else { return }
        if want { liked.insert(id) } else { liked.remove(id) }
        Task {
            let r = try? await bridge.digg(id, like: want)
            if case .ok = r { return }
            if want { liked.remove(id) } else { liked.insert(id) }
            onToast("点赞失败")
        }
    }

    private func collect(_ id: String) {
        let want = !collected.contains(id)
        if want { collected.insert(id) } else { collected.remove(id) }
        Task {
            let r = try? await bridge.favorite(id, add: want)
            if case .ok = r { onToast(want ? "已收藏" : "已取消收藏"); return }
            if want { collected.remove(id) } else { collected.insert(id) }
            onToast("收藏失败")
        }
    }
}

/// DYPagedModel 需要 bridge 才能建，StateObject 包一层延迟创建
@MainActor
final class DYPagedModelHolder: ObservableObject {
    private var m: DYPagedModel?
    private var sub: Any?
    func model(_ b: DouyinBridge) -> DYPagedModel {
        if let m { return m }
        let n = DYPagedModel { cur in try await b.followFeed(cursor: cur) }
        sub = n.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        m = n
        return n
    }
}


#if DEBUG
/// 真机自检：用 App 里真实的接口函数逐个跑一遍（登录态），结果写 ddlog，不用点界面
@MainActor enum DDSelfTest {
    static func run(_ b: DouyinBridge) async {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        func log(_ s: String) { DYLiveModel.log("DDSELF " + s) }
        await b.debugExportCookies()
        do { let u = try await b.selfProfile(); log("self ok name=\(u.name) likes=\(u.likes) works=\(u.works) sec=\(u.secUid.prefix(10))") }
        catch { log("self FAIL \(error.localizedDescription)") }
        for k in DYListKind.allCases {
            do {
                let r = try await b.myList(k, cursor: "0")
                let playable = r.items.filter { $0.play != nil || !$0.images.isEmpty }.count
                log("\(k.title) ok n=\(r.items.count) playable=\(playable) more=\(r.hasMore) cur=\(r.cursor) first=\(r.items.first?.desc.prefix(16) ?? "-")")
                if r.hasMore {
                    let r2 = try await b.myList(k, cursor: r.cursor)
                    log("\(k.title) page2 n=\(r2.items.count) dup=\(Set(r.items.map(\.id)).intersection(r2.items.map(\.id)).count)")
                }
            } catch { log("\(k.title) FAIL \(error.localizedDescription)") }
        }
        do { let r = try await b.followFeed(cursor: "0"); log("关注 ok n=\(r.items.count) more=\(r.hasMore) first=\(r.items.first?.author.name ?? "-")") }
        catch { log("关注 FAIL \(error.localizedDescription)") }
        do {
            let r = try await b.search("猫", offset: "0")
            log("搜索 ok n=\(r.items.count) more=\(r.hasMore) cur=\(r.cursor) first=\(r.items.first?.desc.prefix(16) ?? "-")")
            if r.hasMore { let r2 = try await b.search("猫", offset: r.cursor); log("搜索 page2 n=\(r2.items.count)") }
        } catch { log("搜索 FAIL \(error.localizedDescription)") }
        let sug = await b.suggest("猫"); log("联想 n=\(sug.count) first=\(sug.first?.word ?? "-")")
        log("done")
    }
}
#endif
