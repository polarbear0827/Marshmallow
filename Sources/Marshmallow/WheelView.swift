import SwiftUI
import QuickLookThumbnailing

/// Geometry shared by drawing and hit testing (points).
enum WheelGeometry {
    static let outerRadius: CGFloat = 125.5   // disc edge
    static let ringOuter: CGFloat = 119.5     // segment outer edge
    static let ringInner: CGFloat = 48.5      // segment inner edge
    static let centerRadius: CGFloat = 42     // center hole
    static let gap: CGFloat = 6
    static let corner: CGFloat = 12
    static let size: CGFloat = 372            // panel size (room for shadow & labels)
    static var padding: CGFloat { size / 2 - outerRadius }

    /// Angle (degrees, clockwise from +x in a y-down space) at which segment `i` is centered.
    static func centerAngle(_ i: Int, count: Int) -> Double {
        -90 + Double(i) * 360 / Double(count)
    }

    /// Hit test using a point relative to the wheel center in y-down coordinates.
    static func segment(at p: CGPoint, count: Int) -> Int? {
        let r = hypot(p.x, p.y)
        guard count > 0, r >= ringInner - 4, r <= outerRadius + 10 else { return nil }
        var deg = atan2(p.y, p.x) * 180 / .pi + 90
        if deg < 0 { deg += 360 }
        let step = 360 / Double(count)
        return Int((deg + step / 2) / step) % count
    }

    /// Annular sector with rounded corners and constant-width gaps.
    static func segmentPath(index: Int, count: Int, center c: CGPoint) -> CGPath {
        let cr = corner
        let rOut = ringOuter - cr
        let rIn = ringInner + cr
        let half = 180 / Double(count)
        let mid = centerAngle(index, count: count)
        let inset = gap / 2 + cr
        let dOut = asin(min(1, inset / rOut)) * 180 / .pi
        let dIn = asin(min(1, inset / rIn)) * 180 / .pi
        func rad(_ d: Double) -> CGFloat { CGFloat(d * .pi / 180) }
        let core = CGMutablePath()
        core.addArc(center: c, radius: rOut, startAngle: rad(mid - half + dOut), endAngle: rad(mid + half - dOut), clockwise: false)
        core.addArc(center: c, radius: rIn, startAngle: rad(mid + half - dIn), endAngle: rad(mid - half + dIn), clockwise: true)
        core.closeSubpath()
        // Growing the shrunken core by `cr` with round joins rounds every corner.
        let grown = core.copy(strokingWithWidth: cr * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        return core.union(grown)
    }
}

enum WheelPhase: Equatable {
    case choosing
    case working(String)
    case done(title: String, detail: String)
    case failed(String)
}

final class WheelModel: ObservableObject {
    @Published var mode: WheelMode = .convert
    @Published var items: [WheelItem] = []
    @Published var files: [URL] = []
    @Published var hovered: Int?
    @Published var phase: WheelPhase = .choosing
    @Published var thumbnail: NSImage?
    @Published var results: [URL] = []
    @Published var progress: Double?

    var subtitle: String {
        guard let f = files.first else { return "" }
        return files.count > 1 ? "\(files.count) 個檔案" : f.fileSizeString
    }

    func loadThumbnail(for url: URL) {
        thumbnail = NSWorkspace.shared.icon(forFile: url.path)
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 160, height: 160),
                                               scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let rep else { return }
            DispatchQueue.main.async { self?.thumbnail = rep.nsImage }
        }
    }
}

// MARK: - Shapes

struct SegmentShape: Shape {
    let index: Int
    let count: Int
    func path(in rect: CGRect) -> Path {
        Path(WheelGeometry.segmentPath(index: index, count: count, center: CGPoint(x: rect.midX, y: rect.midY)))
    }
}

/// The disc with the center hole punched out.
struct RingShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addArc(center: c, radius: WheelGeometry.outerRadius, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
        p.closeSubpath()
        p.addArc(center: c, radius: WheelGeometry.centerRadius, startAngle: .degrees(360), endAngle: .zero, clockwise: true)
        p.closeSubpath()
        return p
    }
}

// MARK: - Wheel view

struct WheelView: View {
    @ObservedObject var model: WheelModel
    static let accent = Color(red: 1.0, green: 0.45, blue: 0.62)

    var body: some View {
        ZStack {
            if #available(macOS 26, *) {
                GlassWheel(model: model)
            } else {
                LegacyWheel(model: model)
            }
            CenterView(model: model)
        }
        .frame(width: WheelGeometry.size, height: WheelGeometry.size)
    }
}

/// Segment label (format name, or icon + caption for tools/actions).
struct SegmentLabel: View {
    let item: WheelItem
    let index: Int
    let count: Int
    var body: some View {
        let a = WheelGeometry.centerAngle(index, count: count) * .pi / 180
        let r = (WheelGeometry.ringInner + WheelGeometry.ringOuter) / 2 + 2
        VStack(spacing: 3) {
            if let s = item.symbol {
                Image(systemName: s).font(.system(size: 14, weight: .semibold))
            }
            Text(item.title)
                .font(.system(size: item.symbol == nil ? 14 : 8.5, weight: .bold))
                .tracking(item.symbol == nil ? 0.3 : 0.2)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .frame(width: 62)
        .offset(x: cos(a) * r, y: sin(a) * r)
    }
}

@available(macOS 26, *)
struct GlassWheel: View {
    @ObservedObject var model: WheelModel

    var body: some View {
        let size = WheelGeometry.size
        let n = model.items.count
        ZStack {
            // Disc
            Color.clear
                .frame(width: size, height: size)
                .glassEffect(.regular, in: RingShape())
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)

            // Segments
            ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                let hovered = model.hovered == i && model.phase == .choosing
                if hovered {
                    // Solid highlight, like a pressed key.
                    ZStack {
                        SegmentShape(index: i, count: n)
                            .fill(WheelView.accent.gradient)
                            .shadow(color: WheelView.accent.opacity(0.45), radius: 8, y: 2)
                        SegmentLabel(item: item, index: i, count: n)
                            .foregroundStyle(.white)
                    }
                    .frame(width: size, height: size)
                } else {
                    ZStack {
                        SegmentLabel(item: item, index: i, count: n)
                            .foregroundStyle(.primary)
                    }
                    .frame(width: size, height: size)
                    .glassEffect(.regular, in: SegmentShape(index: i, count: n))
                }
            }
        }
    }
}

/// Fallback for macOS 14/15: frosted blur (provided by AppKit) + translucent segments.
struct LegacyWheel: View {
    @ObservedObject var model: WheelModel

    var body: some View {
        let n = model.items.count
        ZStack {
            Circle()
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.15)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                .frame(width: WheelGeometry.outerRadius * 2, height: WheelGeometry.outerRadius * 2)
            ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                let hovered = model.hovered == i && model.phase == .choosing
                SegmentShape(index: i, count: n)
                    .fill(hovered ? WheelView.accent : Color.white.opacity(0.62))
                    .shadow(color: .black.opacity(hovered ? 0.2 : 0.05), radius: hovered ? 6 : 1.5, y: 1)
                SegmentLabel(item: item, index: i, count: n)
                    .foregroundStyle(hovered ? Color.white : Color.black.opacity(0.82))
            }
        }
    }
}

// MARK: - Center

struct CenterView: View {
    @ObservedObject var model: WheelModel

    var body: some View {
        let d = WheelGeometry.centerRadius * 2
        ZStack {
            // While choosing, the hole stays transparent so the original file icon
            // underneath shows through; afterwards it shows the result preview.
            if model.phase != .choosing, let img = model.thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: d - 6, height: d - 6)
                    .clipShape(Circle())
                    .opacity(model.phase == .choosing ? 1 : 0.4)
            }
            switch model.phase {
            case .choosing:
                pill(model.subtitle)
            case .working:
                WorkingIndicator(progress: model.progress)
            case .done(_, let detail):
                VStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white, Color.green)
                    if !detail.isEmpty { pill(detail) }
                }
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white, Color.red)
            }
        }
        .frame(width: d, height: d)
        .overlay(alignment: .bottom) { caption }
    }

    @ViewBuilder
    private var caption: some View {
        if case .failed(let msg) = model.phase {
            Text(msg)
                .font(.system(size: 11, weight: .medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.92)))
                .foregroundStyle(.white)
                .frame(width: 240)
                .fixedSize(horizontal: false, vertical: true)
                .offset(y: 120)
        } else if case .done(let title, _) = model.phase {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor))
                .foregroundStyle(.white)
                .frame(maxWidth: 220)
                .fixedSize()
                .offset(y: 16)
        }
    }

    @ViewBuilder
    private func pill(_ text: String) -> some View {
        let label = Text(text)
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .padding(.horizontal, 12).padding(.vertical, 6)
        if #available(macOS 26, *) {
            label.glassEffect(.regular, in: Capsule())
        } else {
            label
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(.white.opacity(0.6), lineWidth: 0.6))
        }
    }
}

/// Progress ring with percentage (spinner when progress is unknown).
/// Clicking the wheel center cancels the job.
struct WorkingIndicator: View {
    let progress: Double?
    var body: some View {
        ZStack {
            if let p = progress {
                Circle().stroke(Color.white.opacity(0.35), lineWidth: 5)
                Circle().trim(from: 0, to: p)
                    .stroke(WheelView.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(p * 100))%")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 62, height: 62)
        .help("點一下取消")
    }
}
