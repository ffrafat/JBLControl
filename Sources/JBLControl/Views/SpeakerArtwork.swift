import AppKit
import JBLControlKit
import SwiftUI

/// The speaker's photo when one is known for its model and color, otherwise a drawn outline
/// in the speaker's own colors.
struct SpeakerArtwork: View {
    let model: SpeakerModel?
    let colorCode: UInt8?
    @State private var photo: NSImage?

    private var color: SpeakerColor { model?.color(colorCode) ?? .fallback }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(hex: color.gradient.0).opacity(0.55), .clear],
                                     center: .center, startRadius: 4, endRadius: 56))
                .blur(radius: 6)
            if let photo {
                Image(nsImage: photo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .scaleEffect(model?.formFactor == .cylinder ? 1.15 : 0.9)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 6)
            } else {
                SpeakerSilhouette(formFactor: model?.formFactor ?? .cylinder, color: color)
                    .padding(8)
            }
        }
        .task(id: "\(model?.productID ?? 0)-\(colorCode ?? 0)") {
            photo = model.flatMap { PhotoStore.shared.photo(for: $0.productID, color: colorCode ?? 0) }
        }
    }
}

struct SpeakerSilhouette: View {
    let formFactor: FormFactor
    let color: SpeakerColor

    private var body3D: LinearGradient {
        LinearGradient(colors: [Color(hex: color.gradient.0), Color(hex: color.gradient.1)],
                       startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            switch formFactor {
            case .cylinder:
                ZStack {
                    Capsule().fill(body3D)
                        .frame(width: w, height: h * 0.42)
                    // End caps.
                    HStack {
                        Capsule().fill(.black.opacity(0.45)).frame(width: w * 0.07, height: h * 0.44)
                        Spacer()
                        Capsule().fill(.black.opacity(0.45)).frame(width: w * 0.07, height: h * 0.44)
                    }
                    .frame(width: w * 0.98)
                    grille.clipShape(Capsule()).frame(width: w * 0.82, height: h * 0.38)
                    highlight.frame(width: w * 0.8, height: h * 0.42)
                }
                .frame(width: w, height: h)
            case .compact:
                ZStack {
                    RoundedRectangle(cornerRadius: w * 0.16).fill(body3D)
                        .frame(width: w * 0.78, height: h * 0.62)
                    grille.clipShape(RoundedRectangle(cornerRadius: w * 0.12))
                        .frame(width: w * 0.66, height: h * 0.5)
                    Circle().stroke(.black.opacity(0.25), lineWidth: 2)
                        .frame(width: h * 0.3, height: h * 0.3)
                    // Loop strap.
                    Capsule().stroke(Color(hex: color.gradient.1), lineWidth: 4)
                        .frame(width: w * 0.14, height: h * 0.2)
                        .offset(x: w * 0.42, y: -h * 0.24)
                }
                .frame(width: w, height: h)
            case .boombox:
                ZStack {
                    // Handle.
                    Capsule().stroke(Color(hex: color.gradient.1), lineWidth: h * 0.07)
                        .frame(width: w * 0.7, height: h * 0.34)
                        .offset(y: -h * 0.22)
                    RoundedRectangle(cornerRadius: h * 0.16).fill(body3D)
                        .frame(width: w, height: h * 0.5)
                        .offset(y: h * 0.08)
                    grille.clipShape(RoundedRectangle(cornerRadius: h * 0.12))
                        .frame(width: w * 0.9, height: h * 0.4)
                        .offset(y: h * 0.08)
                }
                .frame(width: w, height: h)
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 6, y: 4)
        .accessibilityHidden(true)
    }

    /// Fabric-like mesh.
    private var grille: some View {
        Canvas { ctx, size in
            var path = Path()
            let step: CGFloat = 3
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += step
            }
            ctx.stroke(path, with: .color(.black.opacity(0.12)), lineWidth: 0.6)
        }
    }

    private var highlight: some View {
        Capsule()
            .fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center))
            .blendMode(.screen)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
