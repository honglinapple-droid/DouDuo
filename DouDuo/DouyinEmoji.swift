// 抖音自带表情：评论 / 私信里的 [捂脸] 这类代码 → 抖音的表情图片（接口 /aweme/v1/web/emoji/list，371 个）
import SwiftUI
import UIKit

@MainActor
final class DYEmojiStore: ObservableObject {
    static let shared = DYEmojiStore()
    /// 代码 → 图片地址
    @Published private(set) var map: [String: String] = {
        (UserDefaults.standard.data(forKey: "douyin_emoji_map_v1")).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }()
    /// 已下载并缩到行内大小的图
    @Published private(set) var images: [String: UIImage] = [:]
    private var loading: Set<String> = []
    private var fetched = false

    private struct Resp: Decodable { let map: [String: String] }

    /// 启动后拉一次表情表（有缓存就先用缓存，后台更新）
    func load(_ bridge: DouyinBridge) {
        guard !fetched else { return }
        fetched = true
        Task {
            guard let d = try? await bridge.call(DouyinBridge.emojiListJS, args: [:], attempts: 2),
                  let r = try? JSONDecoder().decode(Resp.self, from: d), !r.map.isEmpty else { return }
            map = r.map
            UserDefaults.standard.set(try? JSONEncoder().encode(r.map), forKey: "douyin_emoji_map_v1")
        }
    }

    static let token = try! NSRegularExpression(pattern: "\\[[^\\[\\]]{1,10}\\]")

    /// 文字里有没有表情代码
    static func hasEmoji(_ s: String) -> Bool { s.contains("[") && token.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    /// 取图：有就返回，没有就后台下载（下载完会触发界面刷新）
    func image(_ code: String, size: CGFloat) -> UIImage? {
        if let i = images[code] { return i }
        guard let u = map[code].flatMap(URL.init(string:)), !loading.contains(code) else { return nil }
        loading.insert(code)
        Task {
            if let raw = await ImageCache.shared.load(u) {
                let r = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
                let img = r.image { _ in raw.draw(in: CGRect(x: 0, y: 0, width: size, height: size)) }
                images[code] = img.withRenderingMode(.alwaysOriginal)
            }
            loading.remove(code)
        }
        return nil
    }
}

/// 带抖音表情的文字：[捂脸] 这类代码显示成图，其余照常显示
struct DYEmojiText: View {
    let text: String
    var font: Font = .body
    var color: Color = .primary
    var size: CGFloat = 20
    @ObservedObject private var store = DYEmojiStore.shared

    var body: some View {
        build().font(font).foregroundStyle(color)
    }

    private func build() -> Text {
        guard DYEmojiStore.hasEmoji(text) else { return Text(text) }
        var out = Text("")
        var last = text.startIndex
        let ns = text as NSString
        for m in DYEmojiStore.token.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let r = Range(m.range, in: text) else { continue }
            if last < r.lowerBound { out = out + Text(text[last..<r.lowerBound]) }
            let code = String(text[r])
            if let img = store.image(code, size: size) {
                out = out + Text(Image(uiImage: img)).baselineOffset(-4)
            } else {
                out = out + Text(code)
            }
            last = r.upperBound
        }
        if last < text.endIndex { out = out + Text(text[last...]) }
        return out
    }
}

extension DouyinBridge {
    static let emojiListJS = #"""
    const r = await req('GET', '/aweme/v1/web/emoji/list?' + q({ need_all: 'true' }));
    const d = parse(r.t) || {};
    const map = {};
    for (const e of (d.emoji_list || [])) { const u = first(e.emoji_url); if (e.display_name && u) map[e.display_name] = u; }
    return JSON.stringify({ map });
    """#
}
