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
    /// 分享的视频 id（有了就能直接播，不用去网页点）
    var itemId: String? = nil
    /// 群聊里的发言人（单聊为空）
    var sender: String? = nil
    /// 表情回复：谁用哪个表情回了这条
    var reactions: [Reaction]? = nil
    struct Reaction: Equatable, Codable { let img: String; let name: String }
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
    const fk = el => Object.keys(el).find(k => k.startsWith('__reactFiber'));
    // 网页的输入框是 editor-kit，往 DOM 里填字它不认；要拿到它的编辑器实例调 setText
    const getEditor = () => { const root = document.querySelector('.messageEditorimChatEditorContainer'); if (!root) return null; let f = root[fk(root)];
      for (let i = 0; i < 6 && f; i++) { if (f.memoizedProps && f.memoizedProps.onInitEditor) { let h = f.memoizedState; while (h) { const c = h.memoizedState && h.memoizedState.current; if (c && typeof c.setText === 'function') return c; h = h.next; } } f = f.return; } return null; };
    // 每条消息框对应的结构化数据（React 里的 message.parsedContent：视频 id、标题、封面）
    const msgOf = b => { let f = b[fk(b)]; for (let i = 0; i < 14 && f; i++) { const m = f.memoizedProps && f.memoizedProps.message; if (m && m.parsedContent !== undefined) return m; f = f.return; }
      let stack = [b[fk(b)]], n = 0; while (stack.length && n < 300) { const x = stack.pop(); if (!x) continue; n++; const m = x.memoizedProps && x.memoizedProps.message; if (m && m.parsedContent !== undefined) return m; if (x.child) stack.push(x.child); if (x.sibling) stack.push(x.sibling); } return null; };
    const idxOf = b => { let e = b; for (let i = 0; i < 3 && e; i++) { const v = e.getAttribute && e.getAttribute('data-index'); if (v != null) return parseInt(v, 10); e = e.parentElement; } return -1; };
    const boxesNewestFirst = () => { const l = document.querySelector('.messageMessageListlist'); return l ? [...l.querySelectorAll('.messageMessageBoxmessageBox')] : []; };
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

    /// 诊断：把当前聊天列表的 DOM 结构摘出来（每个消息框的 class 链、子节点 class、文字、React 数据的键）
    static let domProbe = helpers + #"""
    const list = document.querySelector('.messageMessageListlist');
    if (!list) return JSON.stringify({ ok: false, why: 'no-list', title: txt(document.querySelector('.StackLayoutStackChatHeadertitle')) });
    const cls = e => (e.className || '').toString().split(' ').filter(Boolean).slice(0, 3).join('.');
    const outline = (e, depth) => { if (!e || depth > 5) return null; const kids = [...e.children].slice(0, 8).map(k => outline(k, depth + 1)).filter(Boolean); return { c: cls(e), t: (e.children.length === 0 ? txt(e).slice(0, 30) : ''), k: kids.length ? kids : undefined }; };
    const boxes = [...list.children].slice(0, 6);
    const out = boxes.map(b => { const m = msgOf(b); return { c: cls(b), idx: idxOf(b), keys: m ? Object.keys(m).slice(0, 25) : null, type: m && (m.type || m.msgType || m.messageType), pc: m && m.parsedContent ? JSON.stringify(m.parsedContent).slice(0, 200) : null, ext: m && m.ext ? JSON.stringify(m.ext).slice(0, 160) : null, o: outline(b, 0) }; });
    const classes = [...new Set([...list.querySelectorAll('*')].flatMap(e => (e.className || '').toString().split(' ')).filter(c => /emoji|Emoji|react|React|reply|Reply|quote|Quote|refer|Refer/.test(c)))].slice(0, 40);
    const emojiEls = [...list.querySelectorAll('[class*=moji], [class*=eact]')].slice(0, 6).map(e => ({ c: (e.className||'').toString().slice(0, 80), t: txt(e).slice(0, 40), img: e.querySelector('img') ? (e.querySelector('img').src || '').slice(0, 80) : '' }));
    return JSON.stringify({ ok: true, title: txt(document.querySelector('.StackLayoutStackChatHeadertitle')), n: list.children.length, boxCls: boxesNewestFirst().length, classes, emojiEls, out });
    """#

    /// 当前会话的聊天记录（从上到下 = 从旧到新）
    static let messages = helpers + #"""
    const list = document.querySelector('.messageMessageListlist');
    if (!list) return JSON.stringify({ title: '', msgs: [] });
    // 网页列表是倒着排的（最新在最上、data-index 0），这里按 data-index 从大到小 = 从旧到新
    const boxes = boxesNewestFirst().map(b => ({ b, i: idxOf(b) })).sort((x, y) => y.i - x.i).map(x => x.b);
    const flat = [];
    boxes.forEach((b, k) => {
      const i = idxOf(b) >= 0 ? idxOf(b) : k;
      const pm = msgOf(b); const pc = (pm && pm.parsedContent) || {};
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
      let itemId = pc.itemId ? String(pc.itemId) : '';
      const mtype = pm ? (pm.type || pm.msgType || pm.messageType || 0) : 0;
      const coverOf = o => (o && o.url_list && o.url_list[0]) || '';
      // b47：先读 React 数据（群聊的 DOM 结构和单聊不一样，按 class 找正文会落空、气泡全白）；DOM 只做兜底
      if (mtype === 7 && pc.text) { kind = 'text'; text = String(pc.text); if (pc.related_share_video && pc.related_share_video.itemId) itemId = String(pc.related_share_video.itemId); }
      else if (mtype === 8 || sh) { kind = 'share'; author = (sh && txt(sh.querySelector('.MessageItemShareAwemeauthorName'))) || pc.content_name || ''; cover = (sh && pick(sh)) || coverOf(pc.cover_url) || coverOf(pc.content_thumb) || ''; text = (pc.content_title || '').slice(0, 60) || '分享了一个视频'; }
      else if (mtype === 17 || au) { kind = 'audio'; text = (au && txt(au.querySelector('.MessageItemAudioduration'))) || (pc.duration ? Math.round(pc.duration / 1000) + '"' : '') || '语音'; }
      else if (t) { kind = 'text'; text = t.innerText; }
      else if (vid) { kind = 'video'; cover = pick(vid); text = '视频'; }
      else if (cs) { kind = 'comment'; text = txt(cs).slice(0, 200); }
      else if (/暂不支持/.test(b.innerText)) { kind = 'unsupported'; text = '暂不支持的消息类型，请到抖音手机端查看'; }
      else { const raw = txt(b).replace(/^已读\s*/, ''); if (raw && !time) text = raw.slice(0, 200); }
      // 群聊：发言人名在气泡上方的 titleWrapper 里
      const sender = txt(b.querySelector('.MessageBoxMessageTitletitleWrapper')).slice(0, 30);
      // 表情回复（抖音在气泡底下画一排：表情图 + 谁回的）
      const reactions = [...b.querySelectorAll('.ContentBottomEmojiReplyemojiReplyPanelItem')].slice(0, 12).map(it => { const im = it.querySelector('img'); return { img: im ? (im.currentSrc || im.src || '') : '', name: txt(it.querySelector('.ContentBottomEmojiReplyname')).slice(0, 20) }; }).filter(r => r.img);
      const tt = time ? txt(time) : '';
      const key = 100000 - i;   // 让 id 随时间递增
      if (tt) flat.push({ id: key * 2, box: i, kind: 'time', fromMe: false, text: tt, author: '', cover: '', avatar: '', itemId: '', sender: '', reactions: [] });
      if (text || cover) flat.push({ id: key * 2 + 1, box: i, kind, fromMe, text, author, cover, avatar: av ? (av.currentSrc || av.src || '') : '', itemId, sender, reactions });
    });
    return JSON.stringify({ title: txt(document.querySelector('.StackLayoutStackChatHeadertitle')), msgs: flat });
    """#

    /// 发送：填字 → 点右下角发送钮（网页就是这么发的）→ 不行再回车
    static let send = helpers + #"""
    const editor = getEditor();
    const ed = document.querySelector('div[contenteditable=true].messageEditorinputArea');
    if (!editor || !ed) return JSON.stringify({ ok: false, why: 'no-editor' });
    const top0 = boxesNewestFirst().find(x => idxOf(x) === 0); const before = top0 ? txt(top0) : '';
    editor.focus(); editor.setText(text);
    await sleep(200);
    const btn = document.querySelector('.messageMsgInputpublishBtn');
    if (!btn) return JSON.stringify({ ok: false, why: 'no-send-btn' });
    fire(btn);
    let sent = false;
    for (let i = 0; i < 15; i++) { await sleep(150); const t0 = boxesNewestFirst().find(x => idxOf(x) === 0); if (t0 && txt(t0) !== before && !txt(ed).replace(/\u200b/g, '').trim()) { sent = true; break; } }
    if (!sent) sent = !txt(ed).replace(/\u200b/g, '').trim();
    return JSON.stringify({ ok: sent });
    """#

    /// 在第 box 个消息框上唤出网页的右键菜单（回复 / 分享 / 多选 / 下载 / 撤回 / 删除 + 快捷表情）
    static let menuHelpers = helpers + #"""
    const boxAt = i => boxesNewestFirst().find(b => idxOf(b) === i) || boxesNewestFirst()[i];
    const ctx = el => { const r = el.getBoundingClientRect(); const o = { bubbles: true, cancelable: true, clientX: r.x + 10, clientY: r.y + 10, button: 2, buttons: 2, pointerId: 1 };
      for (const t of ['pointerdown', 'mousedown']) el.dispatchEvent(new (t.startsWith('pointer') ? PointerEvent : MouseEvent)(t, o));
      el.dispatchEvent(new MouseEvent('contextmenu', o));
      for (const t of ['pointerup', 'mouseup']) el.dispatchEvent(new (t.startsWith('pointer') ? PointerEvent : MouseEvent)(t, o)); };
    const openMenu = async i => { const b = boxAt(i); if (!b) return null; const c = b.querySelector('.MessageBoxContentactiveClickArea') || b.querySelector('.messageMessageBoxcontentBox') || b;
      ctx(c); for (let k = 0; k < 10; k++) { await sleep(80); if (document.querySelector('.MessageOperatePopBodycontainer')) break; }
      return document.querySelector('.MessageOperatePopBodycontainer'); };
    const closeMenu = () => document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    const confirmDialog = async () => { for (let k = 0; k < 10; k++) { await sleep(120);
      const btn = [...document.querySelectorAll('button, div[role=button], span')].find(e => e.childElementCount <= 1 && /^(确定|确认|撤回|删除)$/.test(txt(e)) && e.closest('[class*=modal], [class*=Modal], [class*=dialog], [class*=Dialog], [class*=confirm], [class*=Confirm]'));
      if (btn) { fire(btn); return true; } } return false; };
    """#

    /// 读菜单：有哪些动作、有哪些快捷表情
    static let menuInfo = menuHelpers + #"""
    const m = await openMenu(box);
    if (!m) return JSON.stringify({ ok: false });
    const items = [...m.querySelectorAll('.MessageOperatePopBodydesc')].map(txt);
    const emojis = [...m.querySelectorAll('.PopBodyEmojiQuickReplyemojiCell')].map(x => { const i = x.querySelector('img'); return (i && (i.alt || i.title)) || txt(x) || ''; });
    closeMenu();
    return JSON.stringify({ ok: true, items, emojis });
    """#

    /// 执行菜单动作（action = 回复 / 撤回 / 删除 …），撤回删除会自动点确认
    static let menuAction = menuHelpers + #"""
    const m = await openMenu(box);
    if (!m) return JSON.stringify({ ok: false, why: 'no-menu' });
    const it = [...m.querySelectorAll('.MessageOperatePopBodybuttonItem')].find(x => txt(x.querySelector('.MessageOperatePopBodydesc')) === action);
    if (!it) { closeMenu(); return JSON.stringify({ ok: false, why: 'no-item' }); }
    fire(it);
    let confirmed = false;
    if (action === '撤回' || action === '删除') confirmed = await confirmDialog();
    await sleep(300);
    return JSON.stringify({ ok: true, confirmed, reference: txt(document.querySelector('.MsgInputReferencewrapper')) });
    """#

    /// 快捷表情回复：点菜单里第 idx 个表情
    static let quickEmoji = menuHelpers + #"""
    const m = await openMenu(box);
    if (!m) return JSON.stringify({ ok: false, why: 'no-menu' });
    const cells = [...m.querySelectorAll('.PopBodyEmojiQuickReplyemojiCell')];
    const key = x => { const i = x.querySelector('img'); return (i && (i.alt || i.title)) || txt(x) || ''; };
    const emojis = cells.map(key);
    // b52：按表情名字找，不按位置——抖音的快捷表情会按最近用过的重新排序，按位置点会点成别的表情
    const cell = name ? cells.find(x => key(x) === name) : cells[idx];
    if (!cell) { closeMenu(); return JSON.stringify({ ok: false, why: 'no-emoji', emojis }); }
    fire(cell);
    await sleep(500);
    closeMenu();
    return JSON.stringify({ ok: true, emojis });
    """#

    /// 把第 box 条消息转发给朋友：菜单「分享」→「选择朋友」面板里找到那个人 → 点他旁边的「发送」
    static let forward = menuHelpers + #"""
    const m = await openMenu(box);
    if (!m) return JSON.stringify({ ok: false, why: 'no-menu' });
    const it = [...m.querySelectorAll('.MessageOperatePopBodybuttonItem')].find(x => txt(x.querySelector('.MessageOperatePopBodydesc')) === '分享');
    if (!it) { closeMenu(); return JSON.stringify({ ok: false, why: 'no-share' }); }
    fire(it);
    // 「选择朋友」是一个 semi-modal 弹窗，不在消息面板里
    let modal = null;
    for (let i = 0; i < 20; i++) { await sleep(150); modal = [...document.querySelectorAll('.semi-modal-content')].find(m => /选择朋友/.test(m.innerText || '')); if (modal) break; }
    if (!modal) return JSON.stringify({ ok: false, why: 'no-picker' });
    const rows = [...modal.querySelectorAll('.ShareMessageFriendPickerModalconversationItem')];
    // 行文字形如「iebbiyz 3 发送」：按开头匹配名字
    const row = rows.find(r => txt(r).startsWith(name + ' ') || txt(r) === name) || rows.find(r => txt(r).startsWith(name));
    const closeModal2 = () => { const c = modal.querySelector('.ShareMessageFriendPickerModalheaderClose') || modal.querySelector('[class*=headerClose]'); if (c) fire(c); };
    if (!row) { closeModal2(); return JSON.stringify({ ok: false, why: 'no-friend', n: rows.length }); }
    const sendBtn = row.querySelector('.ShareMessageFriendPickerModalsendButton');
    const label0 = txt(sendBtn);
    fire(sendBtn);
    let changed = false;
    for (let k = 0; k < 15; k++) { await sleep(150); const t1 = document.body.contains(sendBtn) ? txt(sendBtn) : ''; if (t1 !== label0) { changed = true; break; } }
    await sleep(400);
    closeModal2();
    await sleep(300);
    closeMenu();
    return JSON.stringify({ ok: true, changed });
    """#

    /// 把网页的聊天列表往上滚一段，让它渲染出更早的消息（列表是 column-reverse，往上 = scrollTop 变负）
    static let loadOlder = helpers + #"""
    const list = document.querySelector('.messageMessageListlist');
    if (!list) return JSON.stringify({ ok: false });
    const n0 = boxesNewestFirst().length;
    list.scrollTop = list.scrollTop - 2500; list.dispatchEvent(new Event('scroll', { bubbles: true }));
    for (let i = 0; i < 12; i++) { await sleep(150); if (boxesNewestFirst().length > n0) break; }
    await sleep(300);
    return JSON.stringify({ ok: true, n: boxesNewestFirst().length, grew: boxesNewestFirst().length > n0 });
    """#


    /// 把一个视频以卡片形式分享给朋友。前提：后台网页已经**整页跳到** /jingxuan?modal_id=视频号
    ///（b38 用"改地址 + 假 popstate"在刚加载的页面上抖音根本不响应，每次都报没打开；真加载 3 秒弹窗就开）。
    /// 弹窗 → 悬停分享按钮出面板 → 「最近分享」里有这个人就点他旁边的「分享」；没有就点「分享给朋友」进完整列表找
    /// 诊断：后台网页此刻的状态（分享失败时写进日志和提示，不再猜）
    static let pageState = #"""
    const sb = document.querySelector('[data-e2e=video-player-share]');
    return JSON.stringify({ href: location.href, ready: document.readyState, title: document.title.slice(0, 30), w: innerWidth, h: innerHeight,
      vis: document.visibilityState, share: !!sb, shareW: sb ? Math.round(sb.getBoundingClientRect().width) : -1,
      im: !!document.querySelector('.imContainer'), videos: document.querySelectorAll('video').length,
      text: (document.body && document.body.innerText || '').replace(/\s+/g, ' ').slice(0, 80) });
    """#

    /// 探针：分享面板没出来时，列出页面上可见的、带"分享/发送/朋友"字样或 share 类名的元素（看抖音在这个环境里到底渲染了什么）
    static let shareProbe = helpers + #"""
    const vis = el => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
    const share = document.querySelector('[data-e2e=video-player-share]');
    const chain = []; let e = share; for (let i = 0; i < 6 && e; i++) { chain.push((e.tagName + '.' + (e.className || '').toString().slice(0, 40)) + ' h=' + (e.onmouseenter ? 1 : 0) + ' c=' + (e.onclick ? 1 : 0)); e = e.parentElement; }
    const hits = [...document.querySelectorAll('*')].filter(x => vis(x) && x.childElementCount <= 2 && /分享|发送|朋友|复制链接/.test(txt(x)) && txt(x).length < 20 && !x.closest('.imContainer')).slice(0, 25).map(x => x.tagName + '.' + (x.className || '').toString().slice(0, 30) + ':' + txt(x).slice(0, 12));
    const handlers = []; e = share; for (let i = 0; i < 8 && e; i++) { let f = e[fk(e)]; const names = new Set(); for (let k = 0; k < 4 && f; k++) { Object.keys(f.memoizedProps || {}).filter(n => /^on[A-Z]/.test(n)).forEach(n => names.add(n)); f = f.return; } if (names.size) handlers.push(i + ':' + [...names].join(',')); e = e.parentElement; }
    const shareCls = [...document.querySelectorAll('[class*=share], [class*=Share]')].filter(vis).slice(0, 15).map(x => x.tagName + '.' + (x.className || '').toString().slice(0, 50));
    const popups = [...document.querySelectorAll('[class*=popover], [class*=Popover], [class*=modal], [class*=Modal], [role=tooltip]')].filter(vis).slice(0, 10).map(x => x.tagName + '.' + (x.className || '').toString().slice(0, 50) + ':' + txt(x).slice(0, 30));
    return JSON.stringify({ chain, handlers, hits, shareCls, popups, touch: 'ontouchstart' in window, hover: matchMedia('(hover: hover)').matches, pointer: matchMedia('(pointer: fine)').matches, ua: navigator.userAgent.slice(0, 60) });
    """#

    static let shareOnPage = helpers + #"""
    const hov = el => { const r = el.getBoundingClientRect(); for (const t of ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'mousemove']) el.dispatchEvent(new (t.startsWith('pointer') ? PointerEvent : MouseEvent)(t, { bubbles: true, clientX: r.x + r.width / 2, clientY: r.y + r.height / 2, pointerId: 1 })); };
    const panelBtns = () => [...document.querySelectorAll('*')].filter(x => x.childElementCount <= 1 && txt(x) === '分享' && x.getBoundingClientRect().width > 0 && x.getBoundingClientRect().width < 400 && !x.closest('.imContainer'));   // 隐藏页视口 2400 宽，按钮尺寸翻倍，120 会把它滤掉
    const waitChange = async (btn) => { const l0 = txt(btn); fire(btn); for (let k = 0; k < 15; k++) { await sleep(150); const t1 = document.body.contains(btn) ? txt(btn) : ''; if (t1 !== l0) return true; } return false; };
    let share = null;
    for (let i = 0; i < 50; i++) { share = document.querySelector('[data-e2e=video-player-share]'); if (share && share.getBoundingClientRect().width > 0) break; await sleep(200); }
    document.querySelectorAll('video').forEach(v => { try { v.pause(); } catch (e) {} });
    if (!share) return JSON.stringify({ ok: false, why: 'no-modal' });
    // 模拟器实测：整页跳转后抖音会把上次开着的消息面板也恢复出来，盖在视频弹窗上，分享面板就悬停不出来（no-panel）。
    // 先把消息面板收起来（点一下消息入口），发完再由 restoreAfterShare 重新打开
    await sleep(1200);   // 抖音会在加载后一拍才把消息面板恢复出来，等它出完再处理
    const imOpen = () => { const c = document.querySelector('.imContainer'); return !!c && c.getBoundingClientRect().width > 0; };
    if (imOpen()) { const ie = document.querySelector('[data-e2e=im-entry]'); if (ie) { fire(ie); await sleep(700); } }
    if (imOpen()) { const x = document.querySelector('.imContainer [class*=close], .imContainer [class*=Close]'); if (x) { fire(x); await sleep(500); } }
    let e = share;
    for (let i = 0; i < 3 && e && !panelBtns().length; i++) { hov(e); await sleep(400); e = e.parentElement; }
    let via = 'hover';
    if (!panelBtns().length) {
      // iOS WebKit 里 matchMedia('(hover: hover)') 是 false，合成的鼠标事件抖音可能不理：直接去 React 树里找挂在分享按钮祖先上的 onMouseEnter / onClick 调一下
      const fakeEv = el => ({ currentTarget: el, target: el, preventDefault() {}, stopPropagation() {}, persist() {}, nativeEvent: {}, type: 'synthetic' });
      e = share;
      outer: for (let i = 0; i < 8 && e; i++) {
        let f = e[fk(e)];
        for (let k = 0; k < 4 && f; k++) {
          const pr = f.memoizedProps || {};
          for (const name of ['onMouseEnter', 'onPointerEnter', 'onMouseOver', 'onClick']) {
            if (typeof pr[name] === 'function') {
              try { pr[name](fakeEv(e)); } catch (err) {}
              // 面板是异步渲染的，模拟器实测 500ms 还没出来、探针跑的时候才出来：这里等到 3 秒
              for (let w = 0; w < 15 && !panelBtns().length; w++) await sleep(200);
              if (panelBtns().length) { via = 'fiber:' + name + '@' + i; break outer; }
            }
          }
          f = f.return;
        }
        e = e.parentElement;
      }
    }
    if (!panelBtns().length) return JSON.stringify({ ok: false, why: 'no-panel' });
    // 每个「分享」按钮往上找最近的一行（文字短、第一行就是名字）；名字必须和目标**完全相等**才点，
    // 绝不点别人的（之前"往上爬到带头像的容器"在 2 倍视口下会爬过头，拿到整个面板的文字）
    const rowOf = b => { let e = b.parentElement; for (let i = 0; i < 6 && e; i++) { const t = txt(e); if (t.length > 0 && t.length < 60 && t !== '分享') return t; e = e.parentElement; } return ''; };
    const rows = panelBtns().map(b => ({ b, t: rowOf(b) }));
    const hit = rows.find(x => x.t.split('\n')[0].trim() === name);
    if (hit) { const changed = await waitChange(hit.b); await sleep(400); return JSON.stringify({ ok: true, changed, via: 'recent/' + via }); }
    // 不在「最近分享」里：点面板里「分享给朋友」这一项本身（不是某个人旁边的分享钮），打开完整的选择朋友弹窗
    const more = [...document.querySelectorAll('*')].find(x => x.childElementCount <= 2 && txt(x) === '分享给朋友' && x.getBoundingClientRect().width > 0 && !x.closest('.imContainer'));
    if (!more) return JSON.stringify({ ok: false, why: 'no-friend', n: rows.length, names: rows.map(x => x.t.split('\n')[0]).slice(0, 8).join('|') });
    fire(more);
    let modal = null;
    for (let i = 0; i < 20; i++) { await sleep(150); modal = [...document.querySelectorAll('.semi-modal-content')].find(m => /选择朋友/.test(m.innerText || '')); if (modal) break; }
    if (!modal) return JSON.stringify({ ok: false, why: 'no-picker' });
    const prow = [...modal.querySelectorAll('.ShareMessageFriendPickerModalconversationItem')];
    const row = prow.find(r => txt(r).startsWith(name + ' ') || txt(r) === name) || prow.find(r => txt(r).startsWith(name));
    const closePicker = () => { const c = modal.querySelector('.ShareMessageFriendPickerModalheaderClose') || modal.querySelector('[class*=headerClose]'); if (c) fire(c); };
    if (!row) { closePicker(); return JSON.stringify({ ok: false, why: 'no-friend', n: prow.length }); }
    const changed = await waitChange(row.querySelector('.ShareMessageFriendPickerModalsendButton'));
    await sleep(400); closePicker();
    return JSON.stringify({ ok: true, changed, via: 'picker' });
    """#

    /// 取消回复
    static let replyCancel = helpers + #"""
    const c = document.querySelector('.MsgInputReferenceclose'); fire(c);
    await sleep(200);
    return JSON.stringify({ ok: !document.querySelector('.MsgInputReferencewrapper') });
    """#

    /// 点开第 box 个消息框里的视频卡片，网页会弹出播放窗并把视频 id 写进地址栏；读到 id 就关掉
    static let openCard = helpers + #"""
    const b = boxesNewestFirst().find(x => idxOf(x) === box) || boxesNewestFirst()[box];
    if (!b) return JSON.stringify({ ok: false, why: 'no-box' });
    const pm0 = msgOf(b); if (pm0 && pm0.parsedContent && pm0.parsedContent.itemId) return JSON.stringify({ ok: true, id: String(pm0.parsedContent.itemId) });
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

    /// 整页跳到某个地址并等它加载完（最多 20 秒；加载失败也放行，让后面的脚本自己报错）
    func navigate(_ url: URL) async {
        ready = false
        web.load(URLRequest(url: url))
        for _ in 0..<80 where !ready { try? await Task.sleep(nanoseconds: 250_000_000) }
        markReady()
    }

    private func markReady() {
        ready = true
        waiters.forEach { $0.resume() }; waiters.removeAll()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.markReady() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { markReady() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { markReady() }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let s = action.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "blob", "data"].contains(s) ? .allow : .cancel)
    }

    func waitReady() async { if ready { return }; await withCheckedContinuation { waiters.append($0) } }

    /// 原样返回脚本的字符串结果（诊断用）
    func evalRaw(_ js: String, _ args: [String: Any] = [:]) async throws -> String {
        await waitReady()
        let r = try await web.callAsyncJavaScript(js, arguments: args, contentWorld: .page)
        return (r as? String) ?? "nil"
    }

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
    /// 我自己的头像（从我发的消息里取）
    @Published var myAvatar: String?
    /// 发送失败的原因（给界面提示用）
    @Published var lastSendError: String?
    var listVisible = false
    var chatVisible = false

    let web = DYIMWeb()
    private var bridge: DouyinBridge?
    private var panelReady = false
    /// 正在分享视频（后台网页跳到了视频页）：列表 / 聊天轮询先停，别去点消息入口把弹窗弄没
    private var sharing = false
    private var listTask: Task<Void, Never>?
    private var chatTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var started = false

    private struct ListResp: Decodable { let login: Bool; let list: [Row]
        struct Row: Decodable { let index: Int; let name: String; let last: String; let time: String; let pinned: Bool; let avatar: String; let unread: Int } }
    private struct MsgResp: Decodable { let title: String; let msgs: [Row]
        struct Row: Decodable { let id: Int; let box: Int; let kind: String; let fromMe: Bool; let text: String; let author: String; let cover: String; let avatar: String; let itemId: String?; let sender: String?; let reactions: [DYIMMessage.Reaction]? } }
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
        // b50：没登录时网页消息面板认不出「未登录」→ 一直转圈。先看 cookie 里有没有 sessionid，没有就直接显示「还没登录抖音」
        guard await DYSession.loggedIn() else { loggedIn = false; return }
        guard !sharing, await ensurePanel() else { return }
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

    /// 已经弹过横幅的「人 + 内容」，同一条不再弹（时间文字从"刚刚"变"1分钟前"不算新消息）
    private var bannered: Set<String> = []

    private func detectNew(old: [DYIMConversation], new: [DYIMConversation]) {
        guard !old.isEmpty else { return }
        let prev = Dictionary(old.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for c in new {
            guard let p = prev[c.name] else { continue }
            let key = c.name + "|" + c.last
            guard !bannered.contains(key) else { continue }
            let more = c.unread > p.unread
            let changed = c.last != p.last && c.name != openName
            if more || (changed && !chatVisible) {
                bannered.insert(key)
                if bannered.count > 200 { bannered.removeAll() }
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
                let gap: UInt64 = listVisible ? 3 : (chatVisible ? 8 : 30)
                try? await Task.sleep(nanoseconds: gap * 1_000_000_000)
            }
        }
    }

    /// 诊断：打开某个会话后把 DOM 结构写进日志（DOUDUO_IMPROBE=会话名）
    func probe(_ name: String) async {
        guard await ensurePanel() else { DYLiveModel.log("DDIMPROBE no panel"); return }
        let c = conversations.first(where: { $0.name == name })
        _ = try? await web.eval(DYIMJS.open, ["name": name, "index": c?.index ?? -1], as: OKResp.self)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        let r = (try? await web.evalRaw(DYIMJS.domProbe)) ?? "nil"
        DYLiveModel.log("DDIMPROBE \(name) \(r)")
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
        guard !sharing else { return }
        do {
            let r = try await web.eval(DYIMJS.messages, as: MsgResp.self)
            // 群聊的网页标题带人数后缀「沪上抖音分情(7)」，去掉再比（b47 之前这里不相等就整页不更新 → 群聊全空）
            let shown = r.title.replacingOccurrences(of: #"\(\d+\)\s*$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            guard let name = openName, r.title.isEmpty || shown == name || r.title == name else { return }
            let fresh = r.msgs.map { DYIMMessage(id: $0.id, box: $0.box, kind: DYIMMessage.Kind(rawValue: $0.kind) ?? .other, fromMe: $0.fromMe, text: $0.text,
                                                 author: $0.author.isEmpty ? nil : $0.author, cover: $0.cover.isEmpty ? nil : $0.cover, avatar: $0.avatar.isEmpty ? nil : $0.avatar,
                                                 itemId: ($0.itemId ?? "").isEmpty ? nil : $0.itemId,
                                                 sender: ($0.sender ?? "").isEmpty ? nil : $0.sender,
                                                 reactions: ($0.reactions ?? []).isEmpty ? nil : $0.reactions) }
            guard !fresh.isEmpty else { return }
            let stable = Self.stabilize(fresh)
            if let mine = stable.last(where: { $0.fromMe && $0.avatar != nil }) { myAvatar = mine.avatar }
            if stable != messages { messages = stable; DYIMCache.save(name, stable) }
        } catch { self.error = error.localizedDescription }
    }

    /// 消息编号按内容算（同样内容第几次出现也算进去），不随网页里的位置变；否则来一条新消息整列都重建、滚动位置被拉回底部
    private static func stabilize(_ msgs: [DYIMMessage]) -> [DYIMMessage] {
        var seen: [String: Int] = [:]
        return msgs.map { m in
            let base = "\(m.kind.rawValue)|\(m.fromMe)|\(m.text)|\(m.cover ?? "")|\(m.itemId ?? "")"
            let n = seen[base, default: 0]; seen[base] = n + 1
            var h = Hasher(); h.combine(base); h.combine(n)
            return DYIMMessage(id: h.finalize(), box: m.box, kind: m.kind, fromMe: m.fromMe, text: m.text, author: m.author, cover: m.cover, avatar: m.avatar, itemId: m.itemId, sender: m.sender, reactions: m.reactions)
        }
    }

    /// 往上拉到顶：让网页渲染更早的消息，再读一遍
    func loadOlder() async -> Bool {
        guard let r = try? await web.eval(DYIMJS.loadOlder, as: ActionResp.self), r.ok else { return false }
        await refreshMessages()
        return true
    }


    func send(_ text: String) async -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        do {
            let r = try await web.eval(DYIMJS.send, ["text": t], as: OKResp.self)
            if r.ok { replyingTo = nil; await refreshMessages() }
            return r.ok
        } catch { return false }
    }

    private struct MenuInfo: Decodable { let ok: Bool; let items: [String]?; let emojis: [String]? }
    private struct ActionResp: Decodable { let ok: Bool; let confirmed: Bool?; let reference: String?; let why: String?; var emojis: [String]? = nil }
    struct PageState: Decodable, CustomStringConvertible {
        let href: String; let ready: String; let title: String; let w: Int; let h: Int; let vis: String
        let share: Bool; let shareW: Int; let im: Bool; let videos: Int; let text: String
        var description: String { "href=\(href) ready=\(ready) title=\(title) \(w)x\(h) vis=\(vis) share=\(share)/\(shareW) im=\(im) videos=\(videos) text=\(text)" }
    }
    @Published var replyingTo: String?     // 正在回复的那条的摘要（网页的引用栏文字）
    @Published var quickEmojis: [String] = ["[微笑]", "[色]", "[发呆]", "[酷拽]", "[抠鼻]"]

    /// 长按某条消息：问网页这条能做什么
    func menu(for m: DYIMMessage) async -> [String] {
        guard let r = try? await web.eval(DYIMJS.menuInfo, ["box": m.box], as: MenuInfo.self), r.ok else { return [] }
        if let e = r.emojis, !e.isEmpty { quickEmojis = e }
        return r.items ?? []
    }

    /// 回复 / 撤回 / 删除（撤回删除网页会弹确认，脚本自动点确定）
    func act(_ action: String, on m: DYIMMessage) async -> Bool {
        guard let r = try? await web.eval(DYIMJS.menuAction, ["box": m.box, "action": action], as: ActionResp.self), r.ok else { return false }
        if action == "回复" { replyingTo = (r.reference ?? "").replacingOccurrences(of: "\n", with: " ") }
        else { await refreshMessages() }
        return true
    }

    func cancelReply() async {
        _ = try? await web.eval(DYIMJS.replyCancel, as: ActionResp.self)
        replyingTo = nil
    }

    func quickEmoji(_ idx: Int, name: String, on m: DYIMMessage) async -> Bool {
        let r = try? await web.eval(DYIMJS.quickEmoji, ["box": m.box, "idx": idx, "name": name], as: ActionResp.self)
        if let e = r?.emojis, !e.isEmpty { quickEmojis = e }   // 下次弹出的这排和网页当前顺序一致
        guard let r, r.ok else { return false }
        await refreshMessages()
        return true
    }

    /// 发给朋友：打开那个人的会话，把内容当消息发出去（失败原因记在 lastSendError）
    func sendTo(_ c: DYIMConversation, text: String) async -> Bool {
        lastSendError = nil
        guard await ensurePanel() else { lastSendError = loggedIn ? "消息面板还没准备好，等几秒再试" : "抖音未登录"; return false }
        guard let r = try? await web.eval(DYIMJS.open, ["name": c.name, "index": c.index], as: OKResp.self), r.ok else { lastSendError = "没找到 \(c.name) 的会话"; return false }
        let ok = await send(text)
        if !ok { lastSendError = "网页没发出去，再试一次" }
        if let name = openName, name != c.name {
            // 回到用户原来开着的会话
            _ = try? await web.eval(DYIMJS.open, ["name": name, "index": -1], as: OKResp.self)
        }
        return ok
    }

    /// 视频详情缓存（聊天里上下滑看所有分享的视频用）
    private var detailCache: [String: DYAweme] = [:]

    func details(_ ids: [String]) async -> [DYAweme] {
        var out: [DYAweme] = []
        for id in ids { if let a = await detail(id) { out.append(a) } }
        return out
    }

    func detail(_ id: String) async -> DYAweme? {
        if let a = detailCache[id] { return a }
        guard let bridge, let a = try? await bridge.detail(id) else { return nil }
        detailCache[id] = a
        return a
    }

    /// 点聊天里的视频卡片：消息里直接带着视频 id（从网页的 React 数据读的），取详情交给原生播放器
    func openCard(_ m: DYIMMessage) async -> DYAweme? {
        if let id = m.itemId { return await detail(id) }
        do {
            let r = try await web.eval(DYIMJS.openCard, ["box": m.box], as: OKResp.self)
            guard r.ok, let id = r.id, !id.isEmpty else { return nil }
            return await detail(id)
        } catch { return nil }
    }

    /// 视频页「分享」：把视频以卡片形式发给朋友。后台网页整页跳到视频弹窗地址（只改地址抖音不认），
    /// 面板里点人；发完跳回精选页，把消息面板和开着的聊天接回来
    func shareVideo(_ id: String, to c: DYIMConversation) async -> Bool {
        lastSendError = nil
        guard loggedIn else { lastSendError = "抖音未登录"; return false }
        guard !sharing else { lastSendError = "上一条还在发，稍等"; return false }
        sharing = true
        let t0 = Date()
        await web.navigate(URL(string: "https://www.douyin.com/jingxuan?modal_id=\(id)")!)
        panelReady = false
        let st0 = (try? await web.eval(DYIMJS.pageState, as: PageState.self))
        DYLiveModel.log("DDSHARE loaded \(String(format: "%.1f", Date().timeIntervalSince(t0)))s state=\(st0.map { "\($0)" } ?? "nil")")
        let r = try? await web.eval(DYIMJS.shareOnPage, ["name": c.name], as: ActionResp.self)
        let st1 = (r?.ok == true) ? nil : (try? await web.eval(DYIMJS.pageState, as: PageState.self))
        if r?.ok != true, let probe = try? await web.evalRaw(DYIMJS.shareProbe) { DYLiveModel.log("DDSHARE probe \(probe)") }
        DYLiveModel.log("DDSHARE result=\(r.map { "\($0.ok) \($0.why ?? "")" } ?? "nil") \(String(format: "%.1f", Date().timeIntervalSince(t0)))s state=\(st1.map { "\($0)" } ?? "-")")
        Task { await restoreAfterShare() }
        guard let r else { lastSendError = "网页没响应，等几秒再试"; return false }
        if !r.ok {
            switch r.why ?? "" {
            case "no-friend": lastSendError = "网页的朋友列表里没找到 \(c.name)"
            case "no-panel": lastSendError = "网页分享面板没打开，再试一次"
            case "no-modal": lastSendError = "网页没打开这个视频（\(st1.map { "\($0.ready) \($0.w)x\($0.h) \($0.vis) \($0.title)" } ?? "?")）"
            case "no-picker": lastSendError = "网页的选择朋友弹窗没打开，再试一次"
            default: lastSendError = "没发出去"
            }
        }
        return r.ok
    }

    /// 分享完：后台网页回精选页，重开消息面板；聊天开着就把那个人重新点开
    private func restoreAfterShare() async {
        await web.navigate(URL(string: "https://www.douyin.com/jingxuan")!)
        panelReady = false
        sharing = false
        guard await ensurePanel() else { return }
        if let n = openName, let c = conversations.first(where: { $0.name == n }) {
            _ = try? await web.eval(DYIMJS.open, ["name": c.name, "index": c.index], as: OKResp.self)
        }
    }

    /// 把这条消息（视频）转发给朋友：走网页自己的「分享 → 选择朋友 → 发送」
    func forward(_ m: DYIMMessage, to c: DYIMConversation) async -> Bool {
        guard let r = try? await web.eval(DYIMJS.forward, ["box": m.box, "name": c.name], as: ActionResp.self) else { return false }
        return r.ok
    }
}

// MARK: - 通用：左边缘右滑 = 返回（只占最左边 24pt 的隐形条，不和列表滚动打架）

/// b50：右滑返回统一改成「跟手」——页面跟着手指往右移，底下的页面露出来，松手过 30%（或甩得够快）就顺势滑出去再关，
/// 否则弹回。原来是滑够距离直接 dismiss，全屏页按系统默认往下收，手往右划页面往左下角掉，很廉价。
/// edgeOnly：视频列表 / 网页里横滑另有用途（快进、网页滚动），只认最左 24pt 起手。
/// 配合每个全屏页的 `.presentationBackground(.clear)`，拖动时才能看见底下的页面。
struct DYFollowSwipeBack: ViewModifier {
    let edgeOnly: Bool
    let action: () -> Void
    @State private var dx: CGFloat = 0
    @State private var axis = 0          // 0 未定 / 1 横（返回）/ 2 其他
    @State private var width: CGFloat = 400

    private var drag: some Gesture {
        DragGesture(minimumDistance: edgeOnly ? 8 : 16, coordinateSpace: .global)
            .onChanged { v in
                if axis == 0 {
                    let fromEdge = !edgeOnly || v.startLocation.x < 28
                    axis = (fromEdge && v.translation.width > 0 && v.translation.width > abs(v.translation.height) * 2) ? 1 : 2
                }
                guard axis == 1 else { return }
                dx = max(0, v.translation.width)
            }
            .onEnded { v in
                let was = axis == 1
                axis = 0
                guard was else { return }
                let t = v.translation.width
                if t > width * 0.3 || (t > 30 && v.predictedEndTranslation.width > width * 0.5) {
                    withAnimation(.easeOut(duration: 0.22)) { dx = width + 30 } completion: {
                        var tr = Transaction(); tr.disablesAnimations = true
                        withTransaction(tr) { action() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { dx = 0 }
                    }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { dx = 0 }
                }
            }
    }

    func body(content: Content) -> some View {
        content
            .background(Color.black.ignoresSafeArea())
            .offset(x: dx)
            .shadow(color: .black.opacity(dx > 0 ? 0.45 : 0), radius: 14, x: -6)
            // b52：要算上左右安全区——外屏右边有约 84pt 摄像头安全区，只用内容宽（382）会让页面滑到 82% 就停住、
            // 在右边留一条，0.2 秒后整页突然消失（用户看到的「闪一下、两个页面重叠」）。整屏宽 + 阴影余量才滑得出去
            .onGeometryChange(for: CGFloat.self) { $0.size.width + $0.safeAreaInsets.leading + $0.safeAreaInsets.trailing } action: { width = max($0, 1) }
            .simultaneousGesture(drag)
            // 所在的全屏页底色透明 → 拖动时能看见底下的页面（不在全屏页里时无效果）
            .presentationBackground(.clear)
    }
}
extension View {
    func swipeBack(_ action: @escaping () -> Void) -> some View { modifier(DYFollowSwipeBack(edgeOnly: false, action: action)) }
    func edgeSwipeBack(_ action: @escaping () -> Void) -> some View { modifier(DYFollowSwipeBack(edgeOnly: true, action: action)) }
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
        // b50：聊天页不再走导航推入，NavigationStack 去掉（它自带不透明底色，右滑时会挡住底下的推荐页）
        ZStack {
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
            .swipeBack { onClose() }
        }
        // b50：聊天页改成从右边滑进来、盖在消息列表上（原来是导航推入，右滑时底下是黑的）。
        // 右滑跟手时能看见下面的消息列表；返回键是往右滑出去。
        .overlay {
            if let c = open {
                DYChatScreen(im: im, bridge: bridge, conversation: c, onBack: { open = nil }, onAuthor: onAuthor)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.9), value: open?.id)
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
                DYEmojiText(text: c.last.isEmpty ? " " : c.last, font: .footnote, color: .white.opacity(0.55), size: 14).lineLimit(1)
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
    @State private var menuFor: DYIMMessage?
    @State private var menuItems: [String] = []
    @State private var forwardMessage: DYIMMessage?
    @State private var loadingOlder = false
    @State private var olderExhausted = false

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
                        // 滑到最上面：让网页把更早的消息渲染出来
                        Color.clear.frame(height: 1).onAppear { loadOlder(proxy) }
                        if loadingOlder { ProgressView().tint(.white).padding(.vertical, 6) }
                        if im.chatLoading && im.messages.isEmpty { ProgressView().tint(.white).padding(.top, 40) }
                        ForEach(im.messages) { m in bubble(m).id(m.id) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 12).padding(.top, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture { focused = false }
                // 只有最新一条变了才滚到底（往上翻历史时不打扰）
                .onChange(of: im.messages.last?.id) { _, _ in if !loadingOlder { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }

            if let ref = im.replyingTo {
                HStack(spacing: 8) {
                    Rectangle().fill(dyRed).frame(width: 3, height: 28)
                    Text(ref.isEmpty ? "回复消息" : ref).font(.footnote).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                    Spacer()
                    Button { Task { await im.cancelReply() } } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.6)).frame(width: 28, height: 28) }
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.top, 6)
            }
            HStack(spacing: 10) {
                if focused {
                    Button { focused = false } label: { Image(systemName: "keyboard.chevron.compact.down").foregroundStyle(.white.opacity(0.7)).frame(width: 34, height: 34) }
                        .buttonStyle(.plain)
                }
                TextField("发送消息", text: $draft, axis: .vertical).lineLimit(1...4)
                    .focused($focused)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.08)))
                    .dyGlass(in: RoundedRectangle(cornerRadius: 18), interactive: false)
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
        .swipeBack { focused = false; onBack() }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast).font(.footnote).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.7))).padding(.top, 54)
            }
        }
        .alert("发送失败，再试一次", isPresented: $failed) { Button("好", role: .cancel) {} }
        .sheet(item: $menuFor) { m in
            DYMessageMenu(message: m, items: menuItems, emojis: im.quickEmojis,
                          onEmoji: { i in
                              let name = i < im.quickEmojis.count ? im.quickEmojis[i] : ""
                              menuFor = nil
                              Task { if !(await im.quickEmoji(i, name: name, on: m)) { show("这个表情没发出去，再长按一次试试") } }
                          },
                          onAction: { a in
                              menuFor = nil
                              switch a {
                              case "转发": forwardMessage = m
                              default: Task { if await im.act(a, on: m) { if a != "回复" { show("已\(a)") } } else { show("没成功") } }
                              }
                          })
            .presentationDetents([.height(m.fromMe ? 300 : 260)])
            .presentationBackground(Color(red: 0.12, green: 0.12, blue: 0.13))
        }
        .sheet(item: $forwardMessage) { fm in
            DYFriendPicker(im: im, title: "转发给朋友") { friend in
                forwardMessage = nil
                Task {
                    let ok = fm.kind == .text ? await im.sendTo(friend, text: fm.text) : await im.forward(fm, to: friend)
                    show(ok ? "已发给 \(friend.name)" : "没发出去")
                }
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(Color(red: 0.12, green: 0.12, blue: 0.13))
        }
        .fullScreenCover(item: $play) { t in
            DYListPlayer(bridge: bridge, title: t.title, items: t.items, start: t.start,
                         loadMore: t.more.isEmpty ? nil : { await im.details(Array(t.more.prefix(4))) }, onAuthor: onAuthor)
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

    private func show(_ s: String) {
        toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if toast == s { toast = nil } }
    }

    private func loadOlder(_ proxy: ScrollViewProxy) {
        guard !loadingOlder, !olderExhausted, !im.messages.isEmpty else { return }
        loadingOlder = true
        let keep = im.messages.first?.id
        let before = im.messages.count
        Task {
            _ = await im.loadOlder()
            if im.messages.count <= before { olderExhausted = true }
            // 保持原来看到的那条还在原位
            if let keep { proxy.scrollTo(keep, anchor: .top) }
            loadingOlder = false
        }
    }



    private func longPress(_ m: DYIMMessage) {
        guard m.kind != .time else { return }
        menuItems = []
        menuFor = m
        Task { let items = await im.menu(for: m); if menuFor == m { menuItems = items } }
    }

    private func openCard(_ m: DYIMMessage) {
        guard opening == nil else { return }
        opening = m.id
        Task {
            guard let a = await im.openCard(m) else { show("这个视频打不开"); opening = nil; return }
            // 这个聊天里所有分享的视频串成一列，从点的这条开始，能上下滑着看
            let vids = im.messages.filter { ($0.kind == .share || $0.kind == .video) && $0.itemId != nil }
            var items: [DYAweme] = [a]
            if let i = vids.firstIndex(where: { $0.id == m.id }) {
                for v in vids.dropFirst(i + 1).prefix(3) { if let x = await im.detail(v.itemId!) { items.append(x) } }
            }
            let rest = vids.compactMap(\.itemId).filter { id in !items.contains { $0.id == id } }
            play = DYListTarget(title: conversation.name, items: items, start: 0, model: nil, more: rest)
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
                VStack(alignment: m.fromMe ? .trailing : .leading, spacing: 4) {
                    // 群聊：发言人名
                    if let s = m.sender, !s.isEmpty, !m.fromMe {
                        Text(s).font(.caption).foregroundStyle(.white.opacity(0.55)).padding(.horizontal, 4)
                    }
                    if m.kind == .share || m.kind == .video {
                        // 视频卡片：长按出菜单、点一下才打开——互斥，松手不会再把视频打开（b45 之前长按松手视频必弹）
                        content(m)
                            .contentShape(Rectangle())
                            .gesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in longPress(m) }
                                .exclusively(before: TapGesture().onEnded { openCard(m) }))
                    } else {
                        content(m)
                            .contentShape(Rectangle())
                            .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in longPress(m) })
                    }
                    // 表情回复：和抖音一样，气泡底下一排小表情 + 谁回的
                    if let rs = m.reactions, !rs.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(rs.enumerated()), id: \.offset) { _, r in
                                HStack(spacing: 3) {
                                    CachedAsyncImage(url: URL(string: r.img)) { img in img.resizable().scaledToFit() } placeholder: { Color.clear }
                                        .frame(width: 18, height: 18)
                                    if !r.name.isEmpty { Text(r.name).font(.caption2).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(.white.opacity(0.1)))
                                .dyGlass()
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
                if m.fromMe { avatar(m.avatar ?? im.myAvatar, size: 36) } else { Spacer(minLength: 50) }
            }
        }
    }

    @ViewBuilder
    private func content(_ m: DYIMMessage) -> some View {
        switch m.kind {
        case .share, .video:
            Group {
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
            DYEmojiText(text: m.text, font: .body, color: .white, size: 22)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(m.fromMe ? dyRed : dyBubble))
        }
    }
}

/// 长按消息弹出的菜单（照抖音：一排快捷表情 + 回复 / 转发 / 撤回 / 删除）
struct DYMessageMenu: View {
    let message: DYIMMessage
    let items: [String]
    let emojis: [String]
    let onEmoji: (Int) -> Void
    let onAction: (String) -> Void

    private var actions: [String] {
        var out = ["回复", "转发"]
        if message.fromMe { out.append("撤回") }
        out.append("删除")
        // 网页说没有的就不显示（比如对方的消息没有撤回）
        return out.filter { $0 == "转发" || items.isEmpty || items.contains($0) }
    }

    var body: some View {
        VStack(spacing: 14) {
            Capsule().fill(.white.opacity(0.25)).frame(width: 36, height: 4).padding(.top, 8)
            HStack(spacing: 14) {
                ForEach(Array(emojis.prefix(6).enumerated()), id: \.offset) { i, e in
                    Button { onEmoji(i) } label: {
                        Group {
                            if let img = DYEmojiStore.shared.image(e, size: 32) { Image(uiImage: img) }
                            else { Text(DYEmoji.glyph(e)).font(.system(size: 30)) }
                        }
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
            VStack(spacing: 0) {
                ForEach(actions, id: \.self) { a in
                    Button { onAction(a) } label: {
                        HStack {
                            Image(systemName: a == "回复" ? "arrowshape.turn.up.left" : a == "转发" ? "arrowshape.turn.up.right" : a == "撤回" ? "arrow.uturn.backward" : "trash")
                                .frame(width: 24)
                            Text(a)
                            Spacer()
                        }
                        .font(.body).foregroundStyle(a == "删除" || a == "撤回" ? Color(red: 1, green: 0.35, blue: 0.35) : .white)
                        .padding(.horizontal, 20).frame(height: 46).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if a != actions.last { Divider().overlay(.white.opacity(0.08)).padding(.leading, 56) }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// 抖音的 [微笑] 这类表情代码 → 对应的表情符号（显示用；发出去的是抖音自己的表情）
enum DYEmoji {
    static let map: [String: String] = ["[微笑]": "🙂", "[色]": "😍", "[发呆]": "😳", "[酷拽]": "😎", "[抠鼻]": "🤔", "[捂脸]": "🤦", "[大笑]": "😆", "[流泪]": "😭", "[呲牙]": "😁", "[偷笑]": "🤭", "[可爱]": "😊", "[害羞]": "☺️", "[抓狂]": "😫", "[点赞]": "👍", "[比心]": "🫶", "[666]": "6️⃣", "[泣不成声]": "😢", "[震惊]": "😱", "[爱心]": "❤️", "[鼓掌]": "👏"]
    static func glyph(_ code: String) -> String { map[code] ?? code.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "") }
}

/// 选一个朋友（转发 / 分享视频用）
struct DYFriendPicker: View {
    @ObservedObject var im: DYIMModel
    let title: String
    let onPick: (DYIMConversation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var rows: [DYIMConversation] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? im.conversations : im.conversations.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") { dismiss() }.foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(title).font(.headline).foregroundStyle(.white)
                Spacer()
                Color.clear.frame(width: 40, height: 1)  // b50：只给宽度会把标题行撑满整个面板高度（标题掉到中间）
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                TextField("搜索朋友", text: $query).foregroundStyle(.white).textInputAutocapitalization(.never)
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
            .padding(.horizontal, 16).padding(.bottom, 8)
            if rows.isEmpty {
                Text(im.conversations.isEmpty ? "还没读到朋友列表，先打开一次「消息」" : "没找到").font(.footnote).foregroundStyle(.white.opacity(0.6)).padding(.top, 30)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { c in
                            Button { dismiss(); onPick(c) } label: {
                                HStack(spacing: 12) {
                                    avatar(c.avatar, size: 44)
                                    Text(c.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                                    Spacer()
                                    Text("发送").font(.footnote.weight(.semibold)).foregroundStyle(.white)
                                        .padding(.horizontal, 14).frame(height: 30).background(Capsule().fill(dyRed))
                                }
                                .padding(.horizontal, 16).padding(.vertical, 8).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .onAppear { im.start(); if im.conversations.isEmpty { Task { await im.refreshList() } } }
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
