// 原生私信：数据从后台那个登录过的抖音网页（DouyinBridge 的隐藏页）的「消息」面板里读，
// 界面照手机版抖音画。网页版私信走的是长连接，没有可直接调的接口，所以只能读页面 DOM、往输入框里填。
// 页面结构见 docs/私信数据方案.md（2026-11-07 实测）。
import SwiftUI
import WebKit
import Combine

// MARK: - 数据

struct DYIMConversation: Identifiable, Equatable, Hashable {
    let index: Int
    let name: String
    let last: String
    let time: String
    let pinned: Bool
    let avatar: String?
    let unread: Int
    var id: String { "\(index)-\(name)" }
}

struct DYIMMessage: Identifiable, Equatable {
    enum Kind: String { case text, share, video, comment, unsupported, time, other }
    let id: Int
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
    /// 合成一次真实的鼠标点击（网页的会话项不认 el.click()）
    static let helpers = #"""
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const fire = el => { if (!el) return false; const r = el.getBoundingClientRect(); const x = r.x + r.width / 2, y = r.y + r.height / 2;
      for (const t of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) {
        el.dispatchEvent(new (t.startsWith('pointer') ? PointerEvent : MouseEvent)(t, { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0, pointerId: 1, isPrimary: true }));
      } return true; };
    const txt = el => (el && el.innerText || '').trim();
    const items = () => [...document.querySelectorAll('[data-e2e=conversation-item]')];
    const loggedIn = () => !/扫码登录|验证码登录|登录后免费/.test(document.body.innerText);
    """#

    /// 打开消息面板（没开就点顶栏「消息」），等会话项出现
    static let ensureOpen = helpers + #"""
    if (!items().length) {
      const e = document.querySelector('[data-e2e=im-entry]');
      if (!e) return JSON.stringify({ ok: false, login: loggedIn(), why: 'no-entry' });
      fire(e);
      for (let i = 0; i < 40 && !items().length; i++) await sleep(200);
    }
    return JSON.stringify({ ok: items().length > 0, login: loggedIn(), n: items().length });
    """#

    /// 会话列表
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

    /// 打开某个会话（按名字找，找不到按序号），返回聊天标题
    static let open = helpers + #"""
    const all = items();
    let it = all.find(x => txt(x.querySelector('.conversationConversationItemtitle')) === name);
    if (!it && index >= 0 && index < all.length) it = all[index];
    if (!it) return JSON.stringify({ ok: false });
    fire(it);
    for (let i = 0; i < 20; i++) { await sleep(150); if (txt(document.querySelector('.StackLayoutStackChatHeadertitle')) === name) break; }
    return JSON.stringify({ ok: true, title: txt(document.querySelector('.StackLayoutStackChatHeadertitle')) });
    """#

    /// 当前打开的会话的聊天记录（从上到下 = 从旧到新）
    static let messages = helpers + #"""
    const list = document.querySelector('.messageMessageListlist');
    if (!list) return JSON.stringify({ title: '', msgs: [] });
    const msgs = [...list.querySelectorAll('.messageMessageBoxmessageBox')].map((b, i) => {
      const fromMe = /isFromMe/.test(b.className);
      const time = b.querySelector('.MessageBoxTimetimeLayout');
      const t = b.querySelector('.TextMessageTextpureText');
      const sh = b.querySelector('.MessageItemShareAwemecontainer');
      const vid = b.querySelector('.BulletBulletVideocontainer');
      const cs = b.querySelector('.MessageItemCommentSharecontainer');
      const av = b.querySelector('.commonIMAvataravatarContainer img');
      const pick = el => { const im = el && (el.querySelector('img.commonMyImageimgReal') || el.querySelector('img')); return im ? (im.currentSrc || im.src || '') : ''; };
      let kind = 'other', text = '', author = '', cover = '';
      if (t) { kind = 'text'; text = t.innerText; }
      else if (sh) { kind = 'share'; author = txt(sh.querySelector('.MessageItemShareAwemeauthorName')); cover = pick(sh); text = '分享了一个视频'; }
      else if (vid) { kind = 'video'; cover = pick(vid); text = '视频'; }
      else if (cs) { kind = 'comment'; text = txt(cs).slice(0, 200); }
      else if (/暂不支持/.test(b.innerText)) { kind = 'unsupported'; text = '暂不支持的消息类型，请到抖音手机端查看'; }
      else { const raw = txt(b); if (raw) text = raw.slice(0, 200); }
      const tt = time ? txt(time) : '';
      if (kind === 'other' && !text && tt) { kind = 'time'; text = tt; }
      return { id: i, kind, fromMe, text, author, cover, avatar: av ? (av.currentSrc || av.src || '') : '', time: tt };
    });
    // 时间分隔单独成一条，排在该消息前面
    const flat = [];
    msgs.forEach(m => { if (m.kind !== 'time' && m.time) flat.push({ id: m.id * 2, kind: 'time', fromMe: false, text: m.time, author: '', cover: '', avatar: '' });
                        if (m.text || m.cover) flat.push(Object.assign({}, m, { id: m.id * 2 + 1 })); });
    return JSON.stringify({ title: txt(document.querySelector('.StackLayoutStackChatHeadertitle')), msgs: flat });
    """#

    /// 往输入框填字并回车发送；发出去输入框会清空
    static let send = helpers + #"""
    const ed = document.querySelector('div[contenteditable=true].messageEditorinputArea');
    if (!ed) return JSON.stringify({ ok: false, why: 'no-editor' });
    ed.focus();
    document.execCommand('selectAll', false, null); document.execCommand('delete', false, null);
    document.execCommand('insertText', false, text);
    await sleep(150);
    for (const t of ['keydown', 'keypress', 'keyup']) ed.dispatchEvent(new KeyboardEvent(t, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true }));
    for (let i = 0; i < 10; i++) { await sleep(150); if (!txt(ed)) break; }
    const sent = !txt(ed);
    if (!sent) { document.execCommand('selectAll', false, null); document.execCommand('delete', false, null); }
    return JSON.stringify({ ok: sent });
    """#
}

// MARK: - 模型

@MainActor
final class DYIMModel: ObservableObject {
    @Published var conversations: [DYIMConversation] = []
    @Published var messages: [DYIMMessage] = []
    @Published var openName: String?
    @Published var loggedIn = true
    @Published var listLoading = false
    @Published var chatLoading = false
    @Published var error: String?
    @Published var banner: DYIMBanner?
    @Published var unreadTotal = 0
    /// 列表页 / 聊天页是否正显示着（显示时轮询快一点）
    var listVisible = false
    var chatVisible = false

    private var bridge: DouyinBridge?
    /// 点横幅进来要直接打开的会话名
    @Published var pendingOpen: String?
    private var panelReady = false
    private var listTask: Task<Void, Never>?
    private var chatTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var warmed = false

    init() {}
    func attach(_ b: DouyinBridge) { bridge = b }

    private struct ListResp: Decodable { let login: Bool; let list: [Row]
        struct Row: Decodable { let index: Int; let name: String; let last: String; let time: String; let pinned: Bool; let avatar: String; let unread: Int } }
    private struct MsgResp: Decodable { let title: String; let msgs: [Row]
        struct Row: Decodable { let id: Int; let kind: String; let fromMe: Bool; let text: String; let author: String; let cover: String; let avatar: String } }
    private struct OKResp: Decodable { let ok: Bool; let login: Bool?; let title: String?; let why: String? }

    private func eval<T: Decodable>(_ js: String, _ args: [String: Any] = [:], as: T.Type) async throws -> T {
        guard let bridge else { throw DYError.notReady }
        let r = try await bridge.web.callAsyncJavaScript(js, arguments: args, contentWorld: .page)
        guard let s = r as? String, let d = s.data(using: .utf8) else { throw DYError.bad("返回为空") }
        return try JSONDecoder().decode(T.self, from: d)
    }

    /// 启动后在后台把消息面板打开、把列表先读一遍，用户点「消息」时直接有东西
    func warmUp() {
        guard !warmed else { return }
        warmed = true
        startListPolling()
    }

    private func ensurePanel() async -> Bool {
        if panelReady { return true }
        guard let bridge, bridge.ready else { return false }
        do {
            let r = try await eval(DYIMJS.ensureOpen, as: OKResp.self)
            loggedIn = r.login ?? true
            panelReady = r.ok
            return r.ok
        } catch { return false }
    }

    func refreshList() async {
        guard await ensurePanel() else { return }
        do {
            let r = try await eval(DYIMJS.list, as: ListResp.self)
            loggedIn = r.login
            let fresh = r.list.map { DYIMConversation(index: $0.index, name: $0.name, last: $0.last, time: $0.time, pinned: $0.pinned, avatar: $0.avatar.isEmpty ? nil : $0.avatar, unread: $0.unread) }
            detectNew(old: conversations, new: fresh)
            conversations = fresh
            unreadTotal = fresh.reduce(0) { $0 + $1.unread }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    /// 新消息横幅：某个会话未读变多，或最后一条变了且不是我正开着的会话
    private func detectNew(old: [DYIMConversation], new: [DYIMConversation]) {
        guard !old.isEmpty else { return }
        let prev = Dictionary(uniqueKeysWithValues: old.map { ($0.name, $0) })
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
                if listVisible { listLoading = conversations.isEmpty }
                await refreshList()
                listLoading = false
                let gap: UInt64 = listVisible ? 4 : 10
                try? await Task.sleep(nanoseconds: gap * 1_000_000_000)
            }
        }
    }

    func stopAll() { listTask?.cancel(); chatTask?.cancel() }

    func open(_ c: DYIMConversation) {
        openName = c.name
        messages = []
        chatLoading = true
        chatTask?.cancel()
        chatTask = Task {
            guard await ensurePanel() else { chatLoading = false; return }
            _ = try? await eval(DYIMJS.open, ["name": c.name, "index": c.index], as: OKResp.self)
            while !Task.isCancelled {
                await refreshMessages()
                chatLoading = false
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func closeChat() { chatTask?.cancel(); openName = nil; chatVisible = false }

    func refreshMessages() async {
        do {
            let r = try await eval(DYIMJS.messages, as: MsgResp.self)
            guard openName == nil || r.title.isEmpty || r.title == openName else { return }
            let fresh = r.msgs.map { DYIMMessage(id: $0.id, kind: DYIMMessage.Kind(rawValue: $0.kind) ?? .other, fromMe: $0.fromMe, text: $0.text,
                                                 author: $0.author.isEmpty ? nil : $0.author, cover: $0.cover.isEmpty ? nil : $0.cover, avatar: $0.avatar.isEmpty ? nil : $0.avatar) }
            if fresh != messages { messages = fresh }
        } catch { self.error = error.localizedDescription }
    }

    func send(_ text: String) async -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        do {
            let r = try await eval(DYIMJS.send, ["text": t], as: OKResp.self)
            if r.ok { await refreshMessages() }
            return r.ok
        } catch { return false }
    }
}

// MARK: - 界面（照手机版抖音）

private let dyRed = Color(red: 0.996, green: 0.173, blue: 0.333)
private let dyBG = Color(red: 0.086, green: 0.086, blue: 0.094)
private let dyBubble = Color(red: 0.18, green: 0.18, blue: 0.2)

struct DYMessagesScreen: View {
    @ObservedObject var im: DYIMModel
    let onLogin: () -> Void
    @Environment(\.dismiss) private var dismiss
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
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left").font(.headline.weight(.semibold)).foregroundStyle(.white).frame(width: 40, height: 40)
                    }
                    .accessibilityIdentifier("douyin.im.back")
                    Spacer()
                    Text("消息").font(.headline).foregroundStyle(.white)
                    Spacer()
                    Color.clear.frame(width: 40, height: 40)
                }
                .padding(.horizontal, 8)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                    TextField("搜索", text: $query).foregroundStyle(.white).textInputAutocapitalization(.never)
                }
                .padding(.horizontal, 12).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
                .padding(.horizontal, 16).padding(.bottom, 8)

                if !im.loggedIn {
                    VStack(spacing: 12) {
                        Text("还没登录抖音").foregroundStyle(.white)
                        Button("去登录") { onLogin() }.buttonStyle(.borderedProminent).tint(dyRed)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if im.conversations.isEmpty {
                    VStack(spacing: 10) {
                        if im.listLoading || im.error == nil { ProgressView().tint(.white) }
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
                DYChatScreen(im: im, conversation: c)
            }
        }
        .onAppear { im.listVisible = true; im.startListPolling(); openPending() }
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
    let conversation: DYIMConversation
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var sending = false
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.headline.weight(.semibold)).foregroundStyle(.white).frame(width: 40, height: 40)
                }
                Spacer()
                Text(conversation.name).font(.headline).foregroundStyle(.white).lineLimit(1)
                Spacer()
                Color.clear.frame(width: 40, height: 40)
            }
            .padding(.horizontal, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if im.chatLoading && im.messages.isEmpty { ProgressView().tint(.white).padding(.top, 40) }
                        ForEach(im.messages) { m in bubble(m).id(m.id) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 12).padding(.top, 8)
                }
                .onChange(of: im.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo("bottom", anchor: .bottom) } }
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
        .alert("发送失败，再试一次", isPresented: $failed) { Button("好", role: .cancel) {} }
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
            VStack(alignment: .leading, spacing: 0) {
                CachedAsyncImage(url: m.cover.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() } placeholder: { dyBubble }
                    .frame(width: 150, height: 200).clipped()
                    .overlay(Image(systemName: "play.fill").font(.title).foregroundStyle(.white.opacity(0.85)))
                if let a = m.author, !a.isEmpty {
                    Text("@\(a)").font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1).padding(8)
                }
            }
            .background(dyBubble)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
