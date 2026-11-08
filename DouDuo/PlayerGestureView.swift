import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// b54：单击识别器，记下按下 / 抬起的时间和位置、触点大小。用来把「不像单击」的触摸过滤掉（防误触暂停）
final class DYTapRecognizer: UITapGestureRecognizer {
    private(set) var downTime: TimeInterval = 0
    private(set) var upTime: TimeInterval = 0
    private(set) var downLoc: CGPoint = .zero
    private(set) var upLoc: CGPoint = .zero
    private(set) var radius: CGFloat = 0
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = touches.first {
            downTime = t.timestamp; downLoc = t.location(in: nil); upTime = downTime; upLoc = downLoc
            radius = t.majorRadius
        }
        super.touchesBegan(touches, with: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = touches.first {
            upTime = t.timestamp; upLoc = t.location(in: nil)
            radius = max(radius, t.majorRadius)
        }
        super.touchesEnded(touches, with: event)
    }
}

// MARK: - UIKit 手势宿主：Pan 起手定方向（横=快进/竖=漏给 ScrollView 切视频）+ 单击/双击/长按
// 纯 SwiftUI 的 .gesture/.simultaneousGesture 会吞掉整段手势序列导致竖滑分页失效；
// 下沉 UIKit 用一个 UIPanGestureRecognizer，在 shouldBegin 里按起手速度方向仲裁：
//   · 横向主导 → 本次手势归 seek（我们接管）
//   · 纵向主导 → return false，手势漏给外层 ScrollView 分页切视频
// 起手那一帧定轴，整段锁死，中途不改（=你说的"一发力就定方向"）。
struct PlayerGestureView: UIViewRepresentable {
    var onSingleTap: () -> Void
    var onDoubleTap: (CGFloat, CGFloat) -> Void          // (触点x, 宽度)
    var onLongPress: (Bool) -> Void                       // pressing
    var onSeekBegan: () -> Void
    var onSeekChanged: (CGFloat, CGFloat) -> Void         // (横向位移, 宽度)
    var onSeekEnded: () -> Void
    var onEdgeChanged: (CGFloat) -> Void = { _ in }        // 左缘右滑过程中：位移跟手
    var onEdgeEnded: (CGFloat, CGFloat, CGFloat) -> Void = { _, _, _ in }  // 松手：(位移, 横向速度, 屏宽)
    /// 竖向优先（抖音短视频：上下滑切视频是主操作，只有明显横向才算快进）；影库保持横向偏置
    var verticalFirst = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true
        let c = context.coordinator
        c.view = v

        let single = DYTapRecognizer(target: c, action: #selector(Coordinator.handleSingle(_:)))
        single.numberOfTapsRequired = 1
        single.delegate = c

        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleDouble(_:)))
        double.numberOfTapsRequired = 2
        double.delegate = c
        single.require(toFail: double)

        let long = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.handleLong(_:)))
        long.minimumPressDuration = 0.5
        long.allowableMovement = 12     // 手指移动超 12pt（横滑/竖滑）→ 长按取消，让位给 pan/分页
        long.delegate = c
        c.long = long

        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = c
        c.pan = pan

        // 屏幕左缘右滑退出（系统级边缘手势，只在最左 ~20pt 触发，不抢中间区域）
        let edge = UIScreenEdgePanGestureRecognizer(target: c, action: #selector(Coordinator.handleEdge(_:)))
        edge.edges = .left
        edge.delegate = c
        c.edge = edge
        pan.require(toFail: edge)

        v.addGestureRecognizer(single)
        v.addGestureRecognizer(double)
        v.addGestureRecognizer(long)
        v.addGestureRecognizer(pan)
        v.addGestureRecognizer(edge)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self   // 刷新闭包，回调读到最新 @State
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.unlockScroll() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PlayerGestureView
        weak var view: UIView?
        weak var pan: UIPanGestureRecognizer?
        weak var edge: UIScreenEdgePanGestureRecognizer?
        weak var long: UILongPressGestureRecognizer?
        /// 长按 2 倍速期间被封住的外层列表（翻页手势停用，松手恢复）
        private weak var lockedScroll: UIScrollView?

        /// 长按 2 倍速进行中
        var longActive: Bool { long.map { $0.state == .began || $0.state == .changed } ?? false }

        /// 防误触：长按认定后，手指漂移不该变成"拖进度"或"切视频"——把外层 ScrollView 的翻页手势暂时停掉
        private func lockScroll() {
            var s = view?.superview
            while let x = s {
                if let sv = x as? UIScrollView { lockedScroll = sv; sv.panGestureRecognizer.isEnabled = false; return }
                s = x.superview
            }
        }
        func unlockScroll() { lockedScroll?.panGestureRecognizer.isEnabled = true; lockedScroll = nil }
        init(_ p: PlayerGestureView) { parent = p }

        @objc func handleSingle(_ g: UITapGestureRecognizer) {
            if let t = g as? DYTapRecognizer, parent.verticalFirst {
                // b54 防误触：按住超过 0.3 秒、或手指移动超过 10pt，都不算单击（手掌、边缘轻擦不再暂停）
                let hold = t.upTime - t.downTime
                let move = hypot(t.upLoc.x - t.downLoc.x, t.upLoc.y - t.downLoc.y)
                if hold > 0.3 || move > 10 {
                    DYLiveModel.log(String(format: "DDPAUSE 忽略单击 按住=%.2fs 移动=%.0fpt 触点=%.0f y=%.0f", hold, move, t.radius, t.downLoc.y))
                    return
                }
                DYLiveModel.log(String(format: "DDPAUSE 单击 按住=%.2fs 移动=%.0fpt 触点=%.0f x=%.0f y=%.0f", hold, move, t.radius, t.downLoc.x, t.downLoc.y))
            }
            parent.onSingleTap()
        }

        /// b54：顶栏（菜单 / 关注 推荐 直播 消息 / 搜索 我的）连同下方约 20pt 缓冲带：点在这里不算点视频
        /// （不暂停、不双击点赞）。只拦点按，不拦滑动，从顶上往下 / 往上滑照常切视频
        private func inTopBand(_ g: UIGestureRecognizer) -> Bool {
            guard parent.verticalFirst, let w = view?.window else { return false }
            let y = g.location(in: nil).y
            // 顶栏：安全区 + 10 + 40 高；再加 20pt 缓冲
            return y < w.safeAreaInsets.top + 10 + 40 + 20
        }

        @objc func handleDouble(_ g: UITapGestureRecognizer) {
            guard let v = view else { return }
            parent.onDoubleTap(g.location(in: v).x, v.bounds.width)
        }

        @objc func handleLong(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began:
                // 进入 2 倍速：震一下（抖音同款触感），并封住翻页——长按期间手指漂移不切视频
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                lockScroll()
                parent.onLongPress(true)
            case .ended, .cancelled, .failed:
                unlockScroll()
                parent.onLongPress(false)
            default: break
            }
        }

        @objc func handleEdge(_ g: UIScreenEdgePanGestureRecognizer) {
            guard let v = view else { return }
            let dx = g.translation(in: v).x
            switch g.state {
            case .began:
                parent.onEdgeChanged(0)
            case .changed:
                parent.onEdgeChanged(max(0, dx))      // 跟手位移上报给容器，画面 1:1 右移
            case .ended, .cancelled, .failed:
                parent.onEdgeEnded(max(0, dx), g.velocity(in: v).x, v.bounds.width)
            default: break
            }
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let v = view else { return }
            switch g.state {
            case .began: parent.onSeekBegan()
            case .changed: parent.onSeekChanged(g.translation(in: v).x, v.bounds.width)
            case .ended, .cancelled, .failed: parent.onSeekEnded()
            default: break
            }
        }

        // 方向仲裁：Pan 起手定轴。横向偏置——除非竖向明显主导才让给 ScrollView 切视频，
        // 否则都判为快进，避免快进时带点下滑分量被误识别成切视频。

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            if g is UIScreenEdgePanGestureRecognizer { return true }   // 边缘退出始终允许
            if g is UITapGestureRecognizer, inTopBand(g) {
                if g is DYTapRecognizer { DYLiveModel.log(String(format: "DDPAUSE 忽略单击 顶栏缓冲带 y=%.0f", g.location(in: nil).y)) }
                return false
            }
            // 长按 2 倍速进行中：横向拖进度不许起手（手指漂移不该变成拖进度）
            if g is UIPanGestureRecognizer, longActive { return false }
            guard let pg = g as? UIPanGestureRecognizer, let v = view else { return true }
            let vel = pg.velocity(in: v)
            // 底部 ~64pt 留给底部进度条手势，避免与全屏横滑重复触发
            let start = pg.location(in: v)
            if start.y > v.bounds.height - 64 { return false }
            // 起手那一帧速度可能是 0（0 >= 0 会被误判成快进，竖滑切不了视频）→ 退回用位移判方向；都为 0 让给分页
            var d = vel
            if abs(d.x) < 1, abs(d.y) < 1 { d = pg.translation(in: v) }
            if abs(d.x) < 0.5, abs(d.y) < 0.5 { return false }
            if parent.verticalFirst {
                // 横向要比竖向大 20% 才算快进，其余一律交给分页切视频
                return abs(d.x) > abs(d.y) * 1.2
            }
            // 竖向速度要比横向大 50% 以上才算"切视频"，否则一律快进（横向偏置，抗误判）
            return abs(d.x) * 1.5 >= abs(d.y)
        }

        // 手势互斥：Pan 已激活（横向快进）→ 独占，不允许 ScrollView 同时响应
        // Pan 被拒绝（竖向）→ 返回 true 让 ScrollView 接管分页
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            if longActive { return false }   // 2 倍速期间独占，别的手势都别进来
            if let pg = pan, pg.state == .began || pg.state == .changed {
                return false   // 正在拖进度，独占
            }
            return true        // Pan 还没开始或已结束，让 ScrollView 自由分页
        }
    }
}

// MARK: - 底部进度条拖动区（UIKit pan）
// 原来用 SwiftUI 的 DragGesture：手势被打断（切后台、来电、被翻页抢走、滑出边缘）时只"取消"不"结束"，
// 播放器一直以为手还按着，预览浮层挂在屏幕上、进度不动，再拖一下才恢复。UIKit 的 pan 取消也会回调。
struct SeekZoneGestureView: UIViewRepresentable {
    var onBegan: () -> Void
    var onChanged: (CGFloat) -> Void      // 横向位移
    var onEnded: () -> Void
    var onCancelled: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handle(_:)))
        pan.delegate = context.coordinator
        v.addGestureRecognizer(pan)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { if coordinator.active { coordinator.active = false; coordinator.parent.onCancelled() } }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SeekZoneGestureView
        var active = false
        init(_ p: SeekZoneGestureView) { parent = p }

        @objc func handle(_ g: UIPanGestureRecognizer) {
            guard let v = g.view else { return }
            switch g.state {
            case .began: active = true; parent.onBegan(); parent.onChanged(g.translation(in: v).x)
            case .changed: parent.onChanged(g.translation(in: v).x)
            case .ended: active = false; parent.onEnded()
            case .cancelled, .failed: active = false; parent.onCancelled()
            default: break
            }
        }
        // 竖向起手（想翻页）就不接，让给外层列表；横向才算拖进度
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pg = g as? UIPanGestureRecognizer, let v = g.view else { return true }
            var d = pg.velocity(in: v)
            if abs(d.x) < 1, abs(d.y) < 1 { d = pg.translation(in: v) }
            if abs(d.x) < 0.5, abs(d.y) < 0.5 { return true }
            return abs(d.x) >= abs(d.y)
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }
    }
}
