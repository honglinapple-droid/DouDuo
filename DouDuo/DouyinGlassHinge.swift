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

/// 监听铰链：iOS 27.1 起用苹果的 `onHingeChange`，低版本不挂
struct DYHingeObserver: ViewModifier {
    @Binding var hinge: DYHinge
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, ctx in
                guard let h = ctx.hinge else { hinge = .none; return }
                switch h.status {
                case .partiallyOpen: hinge = .partiallyOpen
                case .fullyOpen: hinge = .fullyOpen
                case .closed: hinge = .closed
                default: hinge = .none
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func dyHinge(_ hinge: Binding<DYHinge>) -> some View { modifier(DYHingeObserver(hinge: hinge)) }
}

extension GeometryProxy {
    /// 折痕区域（苹果 `reservedRegions(kind: .division)`），只在折着的时候有；本视图坐标系
    func dyFoldFrame() -> CGRect? {
        if #available(iOS 27.1, *) {
            return reservedRegions(kind: .division).first(where: { $0.isActive })?.frame
        }
        return nil
    }

    /// 半折叠时评论面板该多宽：铺满折痕右边；不在半折叠 / 没有折痕就按原来的 36% 算
    func dyPanelWidth(hinge: DYHinge, commentsOpen: Bool) -> CGFloat {
        if hinge.isHalfOpen, commentsOpen, let f = dyFoldFrame(), f.maxX > size.width * 0.3, f.maxX < size.width * 0.7 {
            return size.width - f.maxX
        }
        return min(380, size.width * 0.36)
    }
}
