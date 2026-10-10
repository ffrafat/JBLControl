import JBLControlKit
import SwiftUI

/// The custom equalizer. Shown only while Custom is selected (or on models without presets):
/// JBL's presets are fixed tunings, so there's nothing to edit or chart for them.
struct EqualizerView: View {
    @Environment(SpeakerManager.self) private var speaker

    private var specs: [EQBandSpec] { speaker.model?.customBands ?? [] }

    /// Display range in dB: a little headroom past the widest band.
    private var range: ClosedRange<Double> {
        let edge = Double(specs.map { max(abs($0.range.lowerBound), abs($0.range.upperBound)) }.max() ?? 6)
        return -(edge + 1)...(edge + 1)
    }

    /// The combined response, on models whose custom EQ is the 7-band parametric one.
    private var curveBands: [EQBand]? {
        guard let family = speaker.model?.family,
              [.legacyParametric, .protocol4Parametric, .protocol4Quantized].contains(family) else { return nil }
        return zip(EQLayouts.parametricShape, speaker.customGains).map { band, gain in
            var b = band
            b.gain = gain
            return b
        }
    }

    private func value(at index: Int) -> Double {
        speaker.customGains.indices.contains(index) ? Double(speaker.customGains[index]) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Equalizer", systemImage: "slider.vertical.3")
                    .font(.headline)
                Spacer()
                if speaker.canWrite {
                    Button("Reset", systemImage: "arrow.counterclockwise") {
                        withAnimation(.smooth) { speaker.resetCustom() }
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.medium))
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }

            ZStack {
                if let curveBands {
                    ResponseCurve(bands: curveBands, frequencies: specs.map(\.frequency), range: range)
                        .stroke(Theme.accent.opacity(0.55),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                HStack(spacing: 0) {
                    ForEach(specs.indices, id: \.self) { i in
                        BandColumn(index: i, spec: specs[i], value: value(at: i), range: range,
                                   editable: speaker.canWrite)
                    }
                }
            }
            .frame(height: 150)
            .overlay(alignment: .bottom) { experimentalPrompt.padding(.bottom, 8) }

            HStack(spacing: 0) {
                ForEach(specs.indices, id: \.self) { i in
                    Text(specs[i].label).frame(maxWidth: .infinity)
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    /// Models not yet confirmed on hardware need an explicit opt-in before EQ writes.
    @ViewBuilder private var experimentalPrompt: some View {
        if speaker.eq != nil, !speaker.canWrite, let model = speaker.model {
            Button("Enable experimental EQ for \(model.shortName)") {
                speaker.allowExperimentalWrites = true
            }
            .help("EQ changes on this model use JBL's protocol but haven't been tested on hardware yet.")
            .font(.caption.weight(.medium))
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }
}

/// Combined filter response drawn across the bar area. Bars are evenly spaced, so x follows
/// band index; between bands the frequency is interpolated logarithmically.
struct ResponseCurve: Shape {
    var bands: [EQBand]
    var frequencies: [Float]
    var range: ClosedRange<Double>

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard frequencies.count > 1 else { return path }
        let n = frequencies.count
        let logs = frequencies.map { log2(Double($0)) }
        let steps = 120
        for i in 0...steps {
            // Half a column beyond each end.
            let position = -0.5 + Double(n) * Double(i) / Double(steps)
            let lower = min(max(Int(floor(position)), 0), n - 2)
            let t = position - Double(lower)
            let f = pow(2, logs[lower] + (logs[lower + 1] - logs[lower]) * t)
            let column = rect.width / CGFloat(n)
            let point = CGPoint(
                x: column / 2 + CGFloat(position) * column,
                y: BandColumn.y(EQResponse.gain(at: f, bands: bands), range: range, height: rect.height)
            )
            i == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}

struct BandColumn: View {
    @Environment(SpeakerManager.self) private var speaker
    let index: Int
    let spec: EQBandSpec
    let value: Double
    let range: ClosedRange<Double>
    let editable: Bool

    @State private var dragging = false
    @State private var hovering = false

    static func y(_ g: Double, range: ClosedRange<Double>, height: CGFloat) -> CGFloat {
        let clamped = min(max(g, range.lowerBound), range.upperBound)
        return height * (1 - (clamped - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let zeroY = Self.y(0, range: range, height: h)
            let valueY = Self.y(value, range: range, height: h)

            ZStack(alignment: .top) {
                Capsule()
                    .fill(.primary.opacity(0.08))
                    .frame(width: 8)
                    .frame(maxHeight: .infinity)

                Capsule()
                    .fill(LinearGradient(
                        colors: [Theme.start, Theme.end],
                        startPoint: value >= 0 ? .top : .bottom, endPoint: value >= 0 ? .bottom : .top
                    ))
                    .frame(width: 8, height: max(abs(zeroY - valueY), 2))
                    .offset(y: min(zeroY, valueY))
                    .opacity(editable ? 1 : 0.45)

                if editable {
                    Circle()
                        .fill(.white)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .scaleEffect(dragging ? 1.2 : hovering ? 1.08 : 1)
                        .offset(y: valueY - 9)

                    if dragging || hovering {
                        Text(String(format: spec.step < 1 ? "%+.1f" : "%+.0f", value))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .glassEffect(.regular, in: .capsule)
                            .offset(y: max(valueY - 34, -6))
                            .transition(.opacity)
                    }
                }
            }
            .frame(width: geo.size.width)
            .contentShape(.rect)
            .onHover { hovering = $0 && editable }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard editable else { return }
                        dragging = true
                        let g = range.upperBound - Double(drag.location.y / h) * (range.upperBound - range.lowerBound)
                        speaker.setCustomGain(Float(g), band: index)
                    }
                    .onEnded { _ in dragging = false }
            )
            .animation(.smooth(duration: 0.18), value: value)
            .animation(.smooth(duration: 0.15), value: dragging)
        }
    }
}
