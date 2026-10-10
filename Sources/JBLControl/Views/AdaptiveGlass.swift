import SwiftUI

/// Liquid Glass on macOS 26 and later; the classic translucent material on macOS 14–15.
/// `JBLCONTROL_CLASSIC_LOOK=1` forces the macOS 14–15 look on newer systems, for testing.
let usesLiquidGlass: Bool = {
    guard #available(macOS 26, *) else { return false }
    return ProcessInfo.processInfo.environment["JBLCONTROL_CLASSIC_LOOK"] != "1"
}()

enum GlassStyle {
    case regular
    case interactive
    /// Selected state: a solid accent fill.
    case tinted(Color)

    @available(macOS 26, *)
    var glass: Glass {
        switch self {
        case .regular: .regular
        case .interactive: .regular.interactive()
        case .tinted(let color): .regular.tint(color).interactive()
        }
    }
}

extension View {
    @ViewBuilder
    func adaptiveGlass<S: Shape>(_ style: GlassStyle = .regular, in shape: S) -> some View {
        if #available(macOS 26, *), usesLiquidGlass {
            glassEffect(style.glass, in: shape)
        } else {
            background {
                switch style {
                case .tinted(let color):
                    shape.fill(color)
                case .regular, .interactive:
                    shape.fill(.regularMaterial)
                        .overlay(shape.stroke(.primary.opacity(0.08), lineWidth: 0.5))
                }
            }
        }
    }

    /// Lets glass shapes morph between states on macOS 26; no-op earlier.
    @ViewBuilder
    func adaptiveGlassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26, *), usesLiquidGlass {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func adaptiveGlassButtonStyle() -> some View {
        if #available(macOS 26, *), usesLiquidGlass {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// `GlassEffectContainer` on macOS 26 (glass shapes blend into each other); a plain group earlier.
struct AdaptiveGlassContainer<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *), usesLiquidGlass {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
