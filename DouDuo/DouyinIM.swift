// 原生私信：数据从一个专门的后台登录网页（和签名页分开，互不拖慢）的「消息」面板里读，
// 界面照手机版抖音画。网页版私信走长连接，没有可直接调的接口，所以只能读页面 DOM、往输入框里填。
// 页面结构见 docs/私信数据方案.md（2026-11-07 实测）。
import SwiftUI
import WebKit
import Combine

// MARK: - 数据

struct DYIMConversation: Identifiable, Equatable, Hashable, Codable {
    let index: Int
    let name: String
    let last: String
    let time: String
    let pinned: Bool
    let avatar: String?
    let unread: Int
    var id: String { "\(index)-\(name)" }
}

struct DYIMMessage: Identifiable, Equatable, Codable {
    enum Kind: String, Codable { case text, share, video, audio, comment, unsupported, time, other }
    let id: Int
    /// 对应网页里第几个消息框（点视频卡片要用）
    let box: Int
    let kind: Kind
    let fromMe: Bool
    let text: String
    let author: String?
    let cover: String?
    let avatar: String?
}

struct DYIMBanner: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let text: String
    let avatar: String?
}

// MARK: - 读网页的脚本

private enum DYIMJS {
    static let helpers = #"""
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const fire = el => { if (!el) return false; const r = el.getBoundingClientRect(); const x = r.x + r.width / 2, y = r.y + r.height / 2;
      for (const t of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) {
        el.dispatchEvent(new (t.startsWith('pointer') ? PointerEvent : MouseEvent)(t, { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0, pointerId: 1, isPrimary: true }));
      } return true; };
    const txt = el => (el && el.innerText || '').trim();
    const items = () => [...document.querySelectorAll('[data-e2e=conversation-item]')];
    const loggedIn = () => !/扫码登录|验证码登录|登录后免费/.test(document.body.innerText);
    const closeModal = () => { if (/modal_id=/.test(location.href)) { history.back(); } document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); };
    """#

    static let ensureOpen = helpers + #"""
    closeModal();
    if (!items().length) {
      const e = document.querySelector('[data-e2e=im-entry]');
      if (!e) return JSON.stringify({ ok: false, login: loggedIn(), why: 'no-entry' });
      fire(e);
      for (let i = 0; i < 40 && !items().length; i++) await sleep(200);
    }
    return JSON.stringify({ ok: items().length > 0, login: loggedIn(), n: items().length });
    """#

    static let list = helpers + #"""
    const out = items().map((it, i) => {
      const badge = [...it.querySelectorAll('*')].find(e => /badge|unread|count/i.test((e.className || '').toString()) && /^\d+$/.test(txt(e)));
      const dot = !!it.querySelector('[class*=redDot], [class*=RedDot], [class*=unreadDot]');
      const img = it.querySelector('.commonIMAvataravatarContainer img') || it.querySelector('img');
      return { index: i, name: txt(it.querySelector('.conversationConversationItemtitle')),
               last: txt(it.querySelector('.ConversationItemHinttextBox')),
               time: txt(it.querySelector('.ConversationItemTagNextToTitletimeStr')),
               pinned: /isStickOnTop/.test(it.className), avatar: img ? (img.currentSrc || img.src || '') : '',
               unread: badge ? parseInt(txt(badge), 10) : (dot ? 1 : 0) };
    }).filter(x => x.name);
    return JSON.stringify({ login: loggedIn(), list: out });
    """#

    static let open = helpers + #"""
    closeModal();
    const all = items();
    let it = all.find(x => txt(x.querySelector('.conversationConversationItemtitle')) === name);
    if (!it && index >= 0 && index < all.length) it = all[index];
    if (!it) return JSON.stringify({ ok: false });
    if (txt(document.querySelector('.StackLayoutStackChatHeadertitle')) !== name) fire(it);
    for (let i = 0; i < 20; i++) { await sleep(100); if (txt(document.querySelector('.StackLayoutStackChatHeadertitle')) === name) break; }
    return JSON.stringify({ ok: true, title: txt(document.querySelector('.StackLayoutStackChatHeadertitle')) });
    """#

    /// 当前会话的聊天记录（从上到下 = 从旧到新）
    static let messages = helpers + #"""
    const list = document.querySelector('.messageMessageListlist');
    if (!list) return JSON.stringify({ title: '', msgs: [] });
    const boxes = [...list.querySelectorAll('.messageMessageBoxmessageBox')];
    const flat = [];
    boxes.forEach((b, i) => {
      const fromMe = !!b.querySelector('[class*=isFromMe]') || /isFromMe/.test(b.className);
      const time = b.querySelector('.MessageBoxTimetimeLayout');
      const t = b.querySelector('.TextMessageTextpureText');
      const sh = b.querySelector('.MessageItemShareAwemecontainer');
      const vid = b.querySelector('.BulletBulletVideocontainer');
      const au = b.querySelector('.MessageItemAudioaudioBox');
      const cs = b.querySelector('.MessageItemCommentSharecontainer');
      const av = b.querySelector('.commonIMAvataravatarContainer img');
      const pick = el => { const im = el && (el.querySelector('img.commonMyImageimgReal') || el.querySelector('img')); return im ? (im.currentSrc || im.src || '') : ''; };
      let kind = 'other', text = '', author = '', cover = '';
      if (t) { kind = 'text'; text = t.innerText; }
      else if (sh) { kind = 'share'; author = txt(sh.querySelector('.MessageItemShareAwemeauthorName')); cover = pick(sh); text = '分享了一个视频'; }
      else if (vid) { kind = 'video'; cover = pick(vid); text = '视频'; }
      else if (au) { kind = 'audio'; text = txt(au.querySelector('.MessageItemAudioduration')) || '语音'; }
      else if (cs) { kind = 'comment'; text = txt(cs).slice(0, 200); }
      else if (/暂不支持/.test(b.innerText)) { kind = 'unsupported'; text = '暂不支持的消息类型，请到抖音手机端查看'; }
      else { const raw = txt(b).replace(/^已读\s*/, ''); if (raw && !time) text = raw.slice(0, 200); }
      const tt = time ? txt(time) : '';
      if (tt) flat.push({ id: i * 2, box: i, kind: 'time', fromMe: false, text: tt, author: '', cover: '', avatar: '' });
      if (text || cover) flat.push({ id: i * 2 + 1, box: i, kind, fromMe, text, author, cover, avatar: av ? (av.currentSrc || av.src || '') : '' });
    });
    return JSON.stringify({ title: txt(document.querySelector('.StackLayoutStackChatHeadertitle')), msgs: flat });
    """#

    /// 发送：填字 → 点右下角发送钮（网页就是这么发的）→ 不行再回车
    static let send = helpers + #"""
    const ed = document.querySelector('div[contenteditable=true].messageEditorinputArea');
    if (!ed) return JSON.stringify({ ok: false, why: 'no-editor' });
    ed.focus();
    document.execCommand('selectAll', false, null); document.execCommand('delete', false, null);
    document.execCommand('insertText', false, text);
    await sleep(120);
    const btn = document.querySelector('.messageMsgInputpublishBtn');
    if (btn) fire(btn);
    for (let i = 0; i < 8 && txt(ed); i++) await sleep(120);
    if (txt(ed)) {
      for (const t of ['keydown', 'keypress', 'keyup']) ed.dispatchEvent(new KeyboardEvent(t, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true }));
      for (let i = 0; i < 8 && txt(ed); i++) await sleep(120);
    }
    const sent = !txt(ed);
    if (!sent) { document.execCommand('selectAll', false, null); document.execCommand('delete', false, null); }
    return JSON.stringify({ ok: sent });
    """#

    /// 点开第 box 个消息框里的视频卡片，网页会弹出播放窗并把视频 id 写进地址栏；读到 id 就关掉
    static let openCard = helpers + #"""
    const list = document.querySelector('.messageMessageListlist');
    const boxes = list ? [...list.querySelectorAll('.messageMessageBoxmessageBox')] : [];
    const b = boxes[box];
    if (!b) return JSON.stringify({ ok: false, why: 'no-box' });
    const icon = b.querySelector('.MessageItemShareAwemeplayIcon') || b.querySelector('.BulletBulletVideoplayIcon') || b.querySelector('.MessageItemShareAwemecontainer') || b.querySelector('.BulletBulletVideocontainer');
    if (!icon) return JSON.stringify({ ok: false, why: 'no-card' });
    fire(icon);
    let id = '';
    for (let i = 0; i < 25; i++) { await sleep(120); const m = location.href.match(/modal_id=(\d+)/); if (m) { id = m[1]; break; } }
    document.querySelectorAll('video').forEach(v => { try { v.pause(); } catch (e) {} });
    closeModal();
    return JSON.stringify({ ok: !!id, id });
    """#
}

// MARK: - 专用的后台网页（和签名页分开，读消息不拖慢刷视频）

@MainActor
final class DYIMWeb: NSObject, WKNavigationDelegate {
    let web: WKWebView
    private(set) var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private static let noMediaJS = """
    (() => {
      const P = HTMLMediaElement.prototype;
      const kill = () => document.querySelectorAll('video').forEach(v => { try { v.muted = true; v.pause(); v.removeAttribute('autoplay'); v.preload = 'none'; } catch (e) {} });
      document.addEventListener('DOMContentLoaded', kill);
      new MutationObserver(kill).observe(document.documentElement, { childList: true, subtree: true });
    })();
    """

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()          // 和网页版 / 签名页共用登录态
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        cfg.allowsInlineMediaPlayback = true
        cfg.userContentController.addUserScript(WKUserScript(source: Self.noMediaJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 900), configuration: cfg)
        web.customUserAgent = DouyinWeb.userAgent
        super.init()
        web.navigationDelegate = self
    }

    func load() {
        guard web.url == nil else { return }
        web.load(URLRequest(url: URL(string: "https://www.douyin.com/jingxuan")!))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            ready = true
            waiters.forEach { $0.resume() }; waiters.removeAll()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let s = action.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "blob", "data"].contains(s) ? .allow : .cancel)
    }

    func waitReady() async { if ready { return }; await withCheckedContinuation { waiters.append($0) } }

    func eval<T: Decodable>(_ js: String, _ args: [String: Any] = [:], as: T.Type) async throws -> T {
        await waitReady()
        let r = try await web.callAsyncJavaScript(js, arguments: args, contentWorld: .page)
        guard let s = r as? String, let d = s.data(using: .utf8) else { throw DYError.bad("返回为空") }
        return try JSONDecoder().decode(T.self, from: d)
    }
}

/// 把后台网页挂进视图树（不挂进去 WebKit 会把它的定时器限速）
struct DYIMWebHost: UIViewRepresentable {
    let im: DYIMModel
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        v.isUserInteractionEnabled = false
        v.alpha = 0.01
        v.clipsToBounds = true
        im.web.web.frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        v.addSubview(im.web.web)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - 本地缓存（先显示上次的，再后台更新）

private enum DYIMCache {
    static let listKey = "douyin_im_list_v1"
    static func chatKey(_ name: String) -> String { "douyin_im_chat_v1_" + name }
    static var list: [DYIMConversation] {
        get { (UserDefaults.standard.data(forKey: listKey)).flatMap { try? JSONDecoder().decode([DYIMConversation].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: listKey) }
    }
    static func chat(_ name: String) -> [DYIMMessage] {
        (UserDefaults.standard.data(forKey: chatKey(name))).flatMap { try? JSONDecoder().decode([DYIMMessage].self, from: $0) } ?? []
    }
    static func save(_ name: String, _ msgs: [DYIMMessage]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(msgs.suffix(80))), forKey: chatKey(name))
    }
}

// MARK: - 模型

@MainActor
final class DYIMModel: ObservableObject {
    @Published var conversations: [DYIMConversation] = DYIMCache.list
    @Published var messages: [DYIMMessage] = []
    @Published var openName: String?
    @Published var loggedIn = true
    @Published var listLoading = false
    @Published var chatLoading = false
    @Published var error: String?
    @Published var banner: DYIMBanner?
    @Published var unreadTotal = 0
    @Published var pendingOpen: String?
    var listVisible = false
    var chatVisible = false

    let web = DYIMWeb()
    private var bridge: DouyinBridge?
    private var panelReady = false
    private var listTask: Task<Void, Never>?
    private var chatTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var started = false

    private struct ListResp: Decodable { let login: Bool; let list: [Row]
        struct Row: Decodable { let index: Int; let name: String; let last: String; let time: String; let pinned: Bool; let avatar: String; let unread: Int } }
    private struct MsgResp: Decodable { let title: String; let msgs: [Row]
        struct Row: Decodable { let id: Int; let box: Int; let kind: String; let fromMe: Bool; let text: String; let author: String; let cover: String; let avatar: String } }
    private struct OKResp: Decodable { let ok: Bool; let login: Bool?; let title: String?; let why: String?; let id: String? }

    func attach(_ b: DouyinBridge) { bridge = b }

    /// 启动就把后台网页拉起来、消息面板点开、列表读好；用户点「消息」时直接有
    func start() {
        guard !started else { return }
        started = true
        web.load()
        startListPolling()
    }

    private func ensurePanel() async -> Bool {
        if panelReady { return true }
        do {
            let r = try await web.eval(DYIMJS.ensureOpen, as: OKResp.self)
            loggedIn = r.login ?? true
            panelReady = r.ok
            return r.ok
        } catch { return false }
    }

    func refreshList() async {
        guard await ensurePanel() else { return }
        do {
            let r = try await web.eval(DYIMJS.list, as: ListResp.self)
            loggedIn = r.login
            let fresh = r.list.map { DYIMConversation(index: $0.index, name: $0.name, last: $0.last, time: $0.time, pinned: $0.pinned, avatar: $0.avatar.isEmpty ? nil : $0.avatar, unread: $0.unread) }
            guard !fresh.isEmpty else { return }
            detectNew(old: conversations, new: fresh)
            if fresh != conversations { conversations = fresh; DYIMCache.list = fresh }
            unreadTotal = fresh.reduce(0) { $0 + $1.unread }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func detectNew(old: [DYIMConversation], new: [DYIMConversation]) {
        guard !old.isEmpty else { return }
        let prev = Dictionary(old.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for c in new {
            guard let p = prev[c.name] else { continue }
            let more = c.unread > p.unread
            let changed = (c.last != p.last || c.time != p.time) && c.name != openName
            if more || (changed && !chatVisible) {
                banner = DYIMBanner(name: c.name, text: c.last, avatar: c.avatar)
                bannerTask?.cancel()
                bannerTask = Task { try? await Task.sleep(nanoseconds: 5_000_000_000); if !Task.isCancelled { banner = nil } }
                break
            }
        }
    }

    func startListPolling() {
        listTask?.cancel()
        listTask = Task {
            while !Task.isCancelled {
                if listVisible && conversations.isEmpty { listLoading = true }
                await refreshList()
                listLoading = false
                // 列表页开着 3 秒一刷；聊天页开着 8 秒；都没开 15 秒（够弹横幅，又不拖慢视频）
                let gap: UInt64 = listVisible ? 3 : (chatVisible ? 8 : 15)
                try? await Task.sleep(nanoseconds: gap * 1_000_000_000)
            }
        }
    }

    func open(_ c: DYIMConversation) {
        openName = c.name
        messages = DYIMCache.chat(c.name)      // 先把上次的记录亮出来
        chatLoading = messages.isEmpty
        chatTask?.cancel()
        chatTask = Task {
            guard await ensurePanel() else { chatLoading = false; return }
            _ = try? await web.eval(DYIMJS.open, ["name": c.name, "index": c.index], as: OKResp.self)
            var n = 0
            while !Task.isCancelled {
                await refreshMessages()
                chatLoading = false
                n += 1
                // 刚打开的几秒读快一点，之后 2.5 秒一次
                try? await Task.sleep(nanoseconds: n < 8 ? 600_000_000 : 2_500_000_000)
            }
        }
    }

    func closeChat() { chatTask?.cancel(); openName = nil; chatVisible = false }

    func refreshMessages() async {
        do {
            let r = try await web.eval(DYIMJS.messages, as: MsgResp.self)
            guard let name = openName, r.title.isEmpty || r.title == name else { return }
            let fresh = r.msgs.map { DYIMMessage(id: $0.id, box: $0.box, kind: DYIMMessage.Kind(rawValue: $0.kind) ?? .other, fromMe: $0.fromMe, text: $0.text,
                                                 author: $0.author.isEmpty ? nil : $0.author, cover: $0.cover.isEmpty ? nil : $0.cover, avatar: $0.avatar.isEmpty ? nil : $0.avatar) }
            guard !fresh.isEmpty else { return }
            if fresh != messages { messages = fresh; DYIMCache.save(name, fresh) }
        } catch { self.error = error.localizedDescription }
    }

    func send(_ text: String) async -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        do {
            let r = try await web.eval(DYIMJS.send, ["text": t], as: OKResp.self)
            if r.ok { await refreshMessages() }
            return r.ok
        } catch { return false }
    }

    /// 点聊天里的视频卡片：让网页点开它拿到视频 id，再用签名页取详情，交给原生播放器
    func openCard(_ m: DYIMMessage) async -> DYAweme? {
        guard let bridge else { return nil }
        do {
            let r = try await web.eval(DYIMJS.openCard, ["box": m.box], as: OKResp.self)
            guard r.ok, let id = r.id, !id.isEmpty else { return nil }
            return try await bridge.detail(id)
        } catch { return nil }
    }
}

// MARK: - 界面（照手机版抖音）

private let dyRed = Color(red: 0.996, green: 0.173, blue: 0.333)
private let dyBG = Color(red: 0.086, green: 0.086, blue: 0.094)
private let dyBubble = Color(red: 0.18, green: 0.18, blue: 0.2)

struct DYMessagesScreen: View {
    @ObservedObject var im: DYIMModel
    let bridge: DouyinBridge
    let onClose: () -> Void
    let onLogin: () -> Void
    let onAuthor: (DYAweme) -> Void
    @State private var query = ""
    @State private var open: DYIMConversation?

    private var rows: [DYIMConversation] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? im.conversations : im.conversations.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.last.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "chevron.left").font(.headline.weight(.semibold)).foregroundStyle(.white).frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("douyin.im.back")
                    Spacer()
                    Text("消息").font(.headline).foregroundStyle(.white)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 4)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                    TextField("搜索", text: $query).foregroundStyle(.white).textInputAutocapitalization(.never)
                }
                .padding(.horizontal, 12).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
                .padding(.horizontal, 16).padding(.bottom, 8)

                if !im.loggedIn && im.conversations.isEmpty {
                    VStack(spacing: 12) {
                        Text("还没登录抖音").foregroundStyle(.white)
                        Button("去登录") { onLogin() }.buttonStyle(.borderedProminent).tint(dyRed)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if im.conversations.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text(im.error ?? "正在读取消息…").font(.footnote).foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { c in
                                Button { open = c } label: { row(c) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("douyin.im.item")
                            }
                        }
                    }
                }
            }
            .background(dyBG.ignoresSafeArea())
            .navigationDestination(item: $open) { c in
                DYChatScreen(im: im, bridge: bridge, conversation: c, onBack: { open = nil }, onAuthor: onAuthor)
            }
        }
        .onAppear { im.listVisible = true; im.start(); im.startListPolling(); openPending() }
        .onChange(of: im.conversations) { _, _ in openPending() }
        .onDisappear { im.listVisible = false }
    }

    private func openPending() {
        guard let n = im.pendingOpen, let c = im.conversations.first(where: { $0.name == n }) else { return }
        im.pendingOpen = nil
        open = c
    }

    private func row(_ c: DYIMConversation) -> some View {
        HStack(spacing: 12) {
            avatar(c.avatar, size: 50)
            VStack(alignment: .leading, spacing: 5) {
                Text(c.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                Text(c.last.isEmpty ? " " : c.last).font(.footnote).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(c.time).font(.caption2).foregroundStyle(.white.opacity(0.4))
                if c.unread > 0 {
                    Text(c.unread > 99 ? "99+" : "\(c.unread)").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(dyRed))
                } else {
                    Color.clear.frame(width: 18, height: 18)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(c.pinned ? Color.white.opacity(0.03) : Color.clear)
        .contentShape(Rectangle())
    }
}

struct DYChatScreen: View {
    @ObservedObject var im: DYIMModel
    let bridge: DouyinBridge
    let conversation: DYIMConversation
    let onBack: () -> Void
    let onAuthor: (DYAweme) -> Void
    @State private var draft = ""
    @State private var sending = false
    @State private var failed = false
    @State private var opening: Int?
    @State private var play: DYListTarget?
    @State private var toast: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.headline.weight(.semibold)).foregroundStyle(.white).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text(conversation.name).font(.headline).foregroundStyle(.white).lineLimit(1)
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if im.chatLoading && im.messages.isEmpty { ProgressView().tint(.white).padding(.top, 40) }
                        ForEach(im.messages) { m in bubble(m).id(m.id) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 12).padding(.top, 8)
                }
                .onChange(of: im.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }

            HStack(spacing: 10) {
                TextField("发送消息", text: $draft, axis: .vertical).lineLimit(1...4)
                    .focused($focused)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.08)))
                    .onSubmit { Task { await doSend() } }
                Button { Task { await doSend() } } label: {
                    if sending { ProgressView().tint(.white).frame(width: 60, height: 34) }
                    else { Text("发送").font(.subheadline.weight(.semibold)).foregroundStyle(.white).frame(width: 60, height: 34).background(Capsule().fill(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.white.opacity(0.15) : dyRed)) }
                }
                .disabled(sending || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.white.opacity(0.04))
        }
        .background(dyBG.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            if let toast {
                Text(toast).font(.footnote).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.7))).padding(.top, 54)
            }
        }
        .alert("发送失败，再试一次", isPresented: $failed) { Button("好", role: .cancel) {} }
        .fullScreenCover(item: $play) { t in
            DYListPlayer(bridge: bridge, title: t.title, items: t.items, start: t.start, loadMore: nil, onAuthor: onAuthor)
        }
        .onAppear { im.chatVisible = true; im.open(conversation) }
        .onDisappear { im.closeChat() }
    }

    private func doSend() async {
        let t = draft
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty, !sending else { return }
        sending = true
        let ok = await im.send(t)
        sending = false
        if ok { draft = "" } else { failed = true }
    }

    private func openCard(_ m: DYIMMessage) {
        guard opening == nil else { return }
        opening = m.id
        Task {
            if let a = await im.openCard(m) { play = DYListTarget(title: conversation.name, items: [a], start: 0, model: nil) }
            else { toast = "这个视频打不开"; DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { toast = nil } }
            opening = nil
        }
    }

    @ViewBuilder
    private func bubble(_ m: DYIMMessage) -> some View {
        switch m.kind {
        case .time:
            Text(m.text).font(.caption2).foregroundStyle(.white.opacity(0.4)).frame(maxWidth: .infinity).padding(.vertical, 4)
        default:
            HStack(alignment: .top, spacing: 8) {
                if m.fromMe { Spacer(minLength: 50) } else { avatar(m.avatar ?? conversation.avatar, size: 36) }
                content(m)
                if !m.fromMe { Spacer(minLength: 50) }
            }
        }
    }

    @ViewBuilder
    private func content(_ m: DYIMMessage) -> some View {
        switch m.kind {
        case .share, .video:
            Button { openCard(m) } label: {
                VStack(alignment: .leading, spacing: 0) {
                    CachedAsyncImage(url: m.cover.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() } placeholder: { dyBubble }
                        .frame(width: 150, height: 200).clipped()
                        .overlay {
                            if opening == m.id { ProgressView().tint(.white) }
                            else { Image(systemName: "play.fill").font(.title).foregroundStyle(.white.opacity(0.85)) }
                        }
                    if let a = m.author, !a.isEmpty {
                        Text("@\(a)").font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1).padding(8)
                    }
                }
                .background(dyBubble)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        case .audio:
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(.white)
                Text("语音 \(m.text)").font(.subheadline).foregroundStyle(.white)
                Text("（暂不能听）").font(.caption2).foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(m.fromMe ? dyRed : dyBubble))
        case .unsupported:
            Text(m.text).font(.footnote).foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(dyBubble))
        default:
            Text(m.text).font(.body).foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(m.fromMe ? dyRed : dyBubble))
                .textSelection(.enabled)
        }
    }
}

/// 顶部横幅：朋友来消息时弹出，点了进聊天
struct DYIMBannerView: View {
    let banner: DYIMBanner
    let onTap: () -> Void
    let onClose: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            avatar(banner.avatar, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                Text(banner.text).font(.footnote).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button { onClose() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.6)).frame(width: 28, height: 28) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(red: 0.16, green: 0.16, blue: 0.18)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

@ViewBuilder
private func avatar(_ url: String?, size: CGFloat) -> some View {
    CachedAsyncImage(url: url.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.1) }
        .frame(width: size, height: size)
        .clipShape(Circle())
}
