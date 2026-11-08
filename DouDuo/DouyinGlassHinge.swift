// b47：苹果官方 Liquid Glass（iOS 26+）和 iPhone Duo 铰链（iOS 27.1+）适配。
// 低版本系统原样显示；布局位置不变，只加质感 / 只在半折叠这一种状态下换布局。
import SwiftUI

// MARK: - Liquid Glass

extension View {
    /// 苹果 Liquid Glass 玻璃质感（iOS 26 起 `glassEffect`）。老系统什么都不加。
    @ViewBuilder
    func dyGlass(interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: Capsule())
        } else {
            self
        }
    }

    /// 玻璃质感，自定义形状
    @ViewBuilder
    func dyGlass(in shape: some Shape, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self
        }
    }
}

// MARK: - 铰链（iPhone Duo）

/// 铰链状态（折叠机以外永远是 .none）
enum DYHinge: Equatable {
    case none, closed, partiallyOpen, fullyOpen
    var isHalfOpen: Bool { self == .partiallyOpen }
}

/// 监听铰链：iOS 27.1 起用苹果的 `onHingeChange`，低版本不挂。
/// b49：苹果的说法是「铰链实时数据只适合做特效，换布局要等姿态定下来」。慢慢展开时铰链会依次报
/// 合上 → 半折 → 全开，每报一次就换一次布局会来回跳 → 加「停稳判定」：同一个姿态保持 0.4 秒才算数，
/// 途中路过的姿态一律不理；定下来以后把「新姿态 + 评论区开关」放进同一个动画一次做完。
struct DYHingeObserver: ViewModifier {
    @Binding var hinge: DYHinge
    var onSettle: ((DYHinge, DYHinge) -> Void)?
    @State private var pending: DYHinge?
    @State private var settleTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, ctx in
                let h: DYHinge
                if let x = ctx.hinge {
                    switch x.status {
                    case .partiallyOpen: h = .partiallyOpen
                    case .fullyOpen: h = .fullyOpen
                    case .closed: h = .closed
                    default: h = .none
                    }
                } else { h = .none }
                propose(h)
            }
        } else {
            content
        }
    }

    private func propose(_ h: DYHinge) {
        // 第一次拿到状态（启动时）直接用，不做动画
        if hinge == .none && pending == nil { hinge = h; return }
        pending = h
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let p = pending, p == h else { return }
            pending = nil
            let old = hinge
            guard old != p else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
                hinge = p
                onSettle?(old, p)
            }
        }
    }
}

extension View {
    /// onSettle：姿态停稳后调用（已在动画里），用来同时开 / 关评论区
    func dyHinge(_ hinge: Binding<DYHinge>, onSettle: ((DYHinge, DYHinge) -> Void)? = nil) -> some View {
        modifier(DYHingeObserver(hinge: hinge, onSettle: onSettle))
    }
}

extension GeometryProxy {
    /// 折痕区域（苹果 `reservedRegions(kind: .division)`），只在折着的时候有；本视图坐标系
    func dyFoldFrame() -> CGRect? {
        if #available(iOS 27.1, *) {
            return reservedRegions(kind: .division).first(where: { $0.isActive })?.frame
        }
        return nil
    }

    /// 半折叠时评论面板该多宽：铺满折痕右边；不在半折叠就按原来的 36% 算。
    /// b49：铰链状态有时比折痕位置先到 → 折痕还没报上来时先按屏幕正中间算，评论区一次就出到最终宽度，不再先窄后宽。
    func dyPanelWidth(hinge: DYHinge, commentsOpen: Bool) -> CGFloat {
        if hinge.isHalfOpen, commentsOpen {
            if let f = dyFoldFrame() {
                if f.maxX > size.width * 0.3, f.maxX < size.width * 0.7 { return size.width - f.maxX }
            } else if size.width > size.height {
                return (size.width / 2).rounded()
            }
        }
        return min(380, size.width * 0.36)
    }
}

/// 调试：DOUDUO_MUTE=1 启动时全程静音（模拟器自测用，别吵到人）
enum DYMute {
    static let on: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["DOUDUO_MUTE"] == "1"
        #else
        return false
        #endif
    }()
}
