import DiskBloomCore
import SwiftUI

struct SunburstView: View {
    let root: DiskNode
    @Binding var selected: DiskNode?
    @Binding var hovered: DiskNode?
    let canExit: Bool
    let onEnter: (DiskNode) -> Void
    let onExit: () -> Void

    private let maximumDepth = 5
    @State private var segments: [SunburstSegment]
    @State private var segmentsByDepth: [[SunburstSegment]]
    @State private var revealProgress = 0.0

    init(
        root: DiskNode,
        selected: Binding<DiskNode?>,
        hovered: Binding<DiskNode?>,
        canExit: Bool,
        onEnter: @escaping (DiskNode) -> Void,
        onExit: @escaping () -> Void
    ) {
        self.root = root
        _selected = selected
        _hovered = hovered
        self.canExit = canExit
        self.onEnter = onEnter
        self.onExit = onExit
        let initialSegments = Self.buildSegments(root: root, maximumDepth: 5)
        _segments = State(initialValue: initialSegments)
        _segmentsByDepth = State(initialValue: Self.groupByDepth(initialSegments, depthCount: 5))
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = RingGeometry(size: proxy.size, ringCount: maximumDepth)
            let activeNode = hovered ?? selected ?? root

            ZStack {
                Canvas { context, _ in
                    drawGuides(context: &context, geometry: geometry)
                    for segment in segments {
                        let progress = revealAmount(for: segment.depth)
                        guard progress > 0.001 else { continue }
                        let path = segmentPath(segment, geometry: geometry, progress: progress)
                        let isSelected = selected?.id == segment.node.id
                        let isHovered = hovered?.id == segment.node.id
                        let baseOpacity = isSelected ? 1.0 : (isHovered ? 0.97 : 0.78 - Double(segment.depth) * 0.06)
                        context.fill(
                            path,
                            with: .color(color(for: segment.node, depth: segment.depth).opacity(baseOpacity * progress))
                        )
                        if isSelected || isHovered {
                            context.stroke(
                                path,
                                with: .color(.white.opacity((isSelected ? 0.9 : 0.58) * progress)),
                                lineWidth: isSelected ? 2.2 : 1.2
                            )
                        }
                    }
                }

                VStack(spacing: 5) {
                    Text(DiskBloomFormat.bytes(activeNode.size))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(BloomTheme.text)
                        .contentTransition(.numericText())
                    Text(activeNode.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(BloomTheme.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: geometry.innerRadius * 1.5)
                    if hovered != nil || selected?.id != root.id {
                        Text(percentText(for: hovered ?? selected))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(BloomTheme.mint)
                    } else if canExit {
                        Label("한 단계 밖으로", systemImage: "arrow.up.left")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(BloomTheme.mint)
                    }
                }
                .scaleEffect(hovered == nil ? 1 : 1.035)
                .animation(.easeOut(duration: 0.14), value: hovered?.id)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let hit = hitTestSegment(location: location, segmentsByDepth: segmentsByDepth, geometry: geometry)
                    if hovered?.id != hit?.id {
                        hovered = hit
                    }
                case .ended:
                    if hovered != nil { hovered = nil }
                }
            }
            .gesture(
                SpatialTapGesture()
                    .onEnded { event in
                        handleTap(location: event.location, geometry: geometry)
                    }
            )
        }
        .onAppear {
            animateReveal()
        }
        .onChange(of: root.id) { _, _ in
            hovered = nil
            let updatedSegments = Self.buildSegments(root: root, maximumDepth: maximumDepth)
            segments = updatedSegments
            segmentsByDepth = Self.groupByDepth(updatedSegments, depthCount: maximumDepth)
            revealProgress = 0
            animateReveal()
        }
        .animation(.easeOut(duration: 0.12), value: selected?.id)
        .accessibilityLabel("디스크 사용량 원형 차트")
        .accessibilityIdentifier("diskbloom.sunburst")
        .accessibilityValue("\(root.name), \(DiskBloomFormat.bytes(root.size))")
        .accessibilityHint("조각을 클릭하면 안으로 이동하고, 가운데를 클릭하면 한 단계 밖으로 이동합니다")
    }

    private func animateReveal() {
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.56, dampingFraction: 0.82, blendDuration: 0.08)) {
                revealProgress = 1
            }
        }
    }

    private func handleTap(location: CGPoint, geometry: RingGeometry) {
        let dx = location.x - geometry.center.x
        let dy = location.y - geometry.center.y
        let radius = hypot(dx, dy)

        if radius < geometry.innerRadius {
            if canExit {
                onExit()
            } else {
                selected = root
            }
            return
        }

        guard let node = hitTestSegment(location: location, segmentsByDepth: segmentsByDepth, geometry: geometry) else {
            return
        }
        if node.isDirectory, node.url != nil, !node.children.isEmpty {
            onEnter(node)
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                selected = node
            }
        }
    }

    private static func buildSegments(root: DiskNode, maximumDepth: Int) -> [SunburstSegment] {
        guard root.size > 0 else { return [] }
        var output: [SunburstSegment] = []

        func walk(_ node: DiskNode, start: Double, end: Double, depth: Int) {
            guard depth < maximumDepth, !node.children.isEmpty else { return }
            let total = max(1, node.children.reduce(Int64(0)) { partial, child in
                let (sum, overflow) = partial.addingReportingOverflow(child.size)
                return overflow ? Int64.max : sum
            })
            var cursor = start
            for child in node.children where child.size > 0 {
                let fraction = Double(child.size) / Double(total)
                let childEnd = min(end, cursor + (end - start) * fraction)
                guard childEnd - cursor > 0.0002 else { continue }
                output.append(SunburstSegment(node: child, depth: depth, start: cursor, end: childEnd))
                walk(child, start: cursor, end: childEnd, depth: depth + 1)
                cursor = childEnd
            }
        }

        walk(root, start: 0, end: Double.pi * 2, depth: 0)
        return output
    }

    private static func groupByDepth(_ segments: [SunburstSegment], depthCount: Int) -> [[SunburstSegment]] {
        var groups = Array(repeating: [SunburstSegment](), count: depthCount)
        for segment in segments where segment.depth >= 0 && segment.depth < depthCount {
            groups[segment.depth].append(segment)
        }
        return groups
    }

    private func drawGuides(context: inout GraphicsContext, geometry: RingGeometry) {
        for ring in 0...geometry.ringCount {
            let radius = geometry.innerRadius + CGFloat(ring) * geometry.ringWidth
            let rect = CGRect(
                x: geometry.center.x - radius,
                y: geometry.center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.035)), lineWidth: 1)
        }
    }

    private func revealAmount(for depth: Int) -> Double {
        let delay = min(0.32, Double(depth) * 0.065)
        return max(0, min(1, (revealProgress - delay) / max(0.01, 1 - delay)))
    }

    private func segmentPath(_ segment: SunburstSegment, geometry: RingGeometry, progress: Double) -> Path {
        let progress = CGFloat(max(0.001, min(1, progress)))
        let targetInner = geometry.innerRadius + CGFloat(segment.depth) * geometry.ringWidth + 2
        let targetOuter = targetInner + geometry.ringWidth - 4
        let inner = geometry.innerRadius + (targetInner - geometry.innerRadius) * progress
        let outer = inner + (targetOuter - targetInner) * progress

        let angularGap = min(0.008, (segment.end - segment.start) * 0.16)
        let targetStart = segment.start - Double.pi / 2 + angularGap
        let targetEnd = segment.end - Double.pi / 2 - angularGap
        let middle = (targetStart + targetEnd) / 2
        let start = middle + (targetStart - middle) * Double(progress)
        let end = middle + (targetEnd - middle) * Double(progress)

        var path = Path()
        path.addArc(
            center: geometry.center,
            radius: outer,
            startAngle: .radians(start),
            endAngle: .radians(end),
            clockwise: false
        )
        path.addArc(
            center: geometry.center,
            radius: inner,
            startAngle: .radians(end),
            endAngle: .radians(start),
            clockwise: true
        )
        path.closeSubpath()
        return path
    }

    private func hitTestSegment(
        location: CGPoint,
        segmentsByDepth: [[SunburstSegment]],
        geometry: RingGeometry
    ) -> DiskNode? {
        let dx = location.x - geometry.center.x
        let dy = location.y - geometry.center.y
        let radius = hypot(dx, dy)
        guard radius >= geometry.innerRadius, radius <= geometry.outerRadius else { return nil }
        let depth = Int((radius - geometry.innerRadius) / geometry.ringWidth)
        guard depth >= 0, depth < maximumDepth, depth < segmentsByDepth.count else { return nil }

        var angle = atan2(dy, dx) + Double.pi / 2
        if angle < 0 { angle += Double.pi * 2 }
        if angle >= Double.pi * 2 { angle -= Double.pi * 2 }
        return segmentsByDepth[depth].first { angle >= $0.start && angle <= $0.end }?.node
    }

    private func color(for node: DiskNode, depth: Int) -> Color {
        var hash: UInt64 = 1469598103934665603
        for byte in node.name.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        let base = BloomTheme.chartPalette[Int(hash % UInt64(BloomTheme.chartPalette.count))]
        return base.opacity(max(0.48, 1 - Double(depth) * 0.075))
    }

    private func percentText(for node: DiskNode?) -> String {
        guard let node, root.size > 0 else { return "" }
        return String(format: "%.1f%%", node.fraction(of: root.size) * 100)
    }
}

private struct SunburstSegment: Identifiable {
    let node: DiskNode
    let depth: Int
    let start: Double
    let end: Double

    var id: String { "\(node.id.uuidString)-\(depth)" }
}

private struct RingGeometry {
    let center: CGPoint
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    let ringWidth: CGFloat
    let ringCount: Int

    init(size: CGSize, ringCount: Int) {
        let extent = max(200, min(size.width, size.height))
        self.center = CGPoint(x: size.width / 2, y: size.height / 2)
        self.innerRadius = extent * 0.15
        self.outerRadius = extent * 0.47
        self.ringCount = ringCount
        self.ringWidth = (outerRadius - innerRadius) / CGFloat(ringCount)
    }
}
