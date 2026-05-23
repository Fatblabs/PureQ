//
//  RoutingWorkspace.swift
//  PureQ
//

import SwiftUI

struct RoutingWorkspace: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        VStack(spacing: 0) {
            RoutingToolbar()

            HStack(spacing: 0) {
                EditableRoutingCanvas()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                RoutingInspector()
                    .frame(width: 318)
            }
        }
        .background(Color.pureQBackground)
    }
}

private enum RoutingNodeCardMetrics {
    static let width: CGFloat = 226
    static let height: CGFloat = 142
    static let halfWidth: CGFloat = width / 2
    static let halfHeight: CGFloat = height / 2
}

struct RoutingToolbar: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.availableAudioSources) { source in
                    Button {
                        model.addSourceRoutingNode(sourceID: source.id)
                    } label: {
                        Label(source.title, systemImage: source.systemImage)
                    }
                }
            } label: {
                Label("Source", systemImage: "music.note.list")
            }
            .buttonStyle(RouteToolbarButtonStyle())

            Menu {
                ForEach(RoutingNodeKind.allCases.filter { $0 != .source && $0 != .bus && $0 != .output && $0 != .monitor }) { kind in
                    Button {
                        model.addRoutingNode(kind: kind)
                    } label: {
                        Label(kind.title, systemImage: kind.systemImage)
                    }
                }
            } label: {
                Label("Processor", systemImage: "plus")
            }
            .buttonStyle(RouteToolbarButtonStyle())

            Menu {
                Button {
                    model.addOutputRoutingNode(uid: nil)
                } label: {
                    Label("Unassigned", systemImage: "speaker.wave.2")
                }
                Divider()
                ForEach(model.hardwareOutputDevices) { device in
                    Button(device.name) {
                        model.addOutputRoutingNode(uid: device.uid)
                    }
                }
            } label: {
                Label("Output", systemImage: "speaker.wave.2.fill")
            }
            .buttonStyle(RouteToolbarButtonStyle())

            Button {
                if let id = model.selectedRoutingNodeID {
                    model.disconnectRoutingNode(id: id)
                }
            } label: {
                Image(systemName: "link.slash")
            }
            .buttonStyle(IconButtonStyle(size: 34))
            .disabled(model.selectedRoutingNodeID == nil)
            .help("Disconnect selected node")

            Button {
                model.resetRoutingGraph()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(IconButtonStyle(size: 34))
            .help("Reset routing graph")

            Spacer()

            Label("\(model.routingNodes.count) nodes", systemImage: "square.stack.3d.up")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)

            Label("\(model.routingConnections.count) links", systemImage: "link")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)

        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.pureQPanel)
    }
}

struct EditableRoutingCanvas: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        GeometryReader { proxy in
            let nodeMaxX = model.routingNodes
                .map { $0.position.x + RoutingNodeCardMetrics.halfWidth + 72 }
                .max() ?? 1_180
            let nodeMaxY = model.routingNodes
                .map { $0.position.y + RoutingNodeCardMetrics.halfHeight + 72 }
                .max() ?? 620
            let canvasSize = CGSize(
                width: max(proxy.size.width, 1_180, nodeMaxX),
                height: max(proxy.size.height, 620, nodeMaxY)
            )

            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                ZStack {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.selectedRoutingNodeID = nil
                            model.patchStartNodeID = nil
                        }

                    EditableRoutingWireCanvas(canvasSize: canvasSize)
                        .allowsHitTesting(false)

                    ForEach(model.routingNodes) { node in
                        EditableRoutingNodeCard(node: node, canvasSize: canvasSize)
                            .frame(width: RoutingNodeCardMetrics.width, height: RoutingNodeCardMetrics.height)
                            .position(node.position)
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .background(Color.pureQBackground)
                .coordinateSpace(name: "routingCanvas")
            }
            .background(Color.pureQBackground)
        }
    }
}

struct EditableRoutingWireCanvas: View {
    @EnvironmentObject private var model: EqualizerModel
    let canvasSize: CGSize

    var body: some View {
        Canvas { context, size in
            drawGrid(in: size, context: &context)
            let nodeByID = Dictionary(uniqueKeysWithValues: model.routingNodes.map { ($0.id, $0) })

            for connection in model.routingConnections {
                guard let source = nodeByID[connection.from],
                      let target = nodeByID[connection.to] else {
                    continue
                }
                let endpoints = connectionEndpoints(from: source, to: target)
                drawConnection(
                    from: endpoints.start,
                    to: endpoints.end,
                    color: wireColor(from: source, to: target),
                    context: &context
                )
            }

            if let patchStartID = model.patchStartNodeID,
               let patchNode = model.routingNodes.first(where: { $0.id == patchStartID }) {
                let start = CGPoint(x: patchNode.position.x + RoutingNodeCardMetrics.halfWidth, y: patchNode.position.y)
                let end = CGPoint(x: min(size.width - 34, start.x + 128), y: start.y)
                drawConnection(from: start, to: end, color: Color.pureQAmber, dashed: true, context: &context)
            }
        }
    }

    private func connectionEndpoints(from source: RoutingNode, to target: RoutingNode) -> (start: CGPoint, end: CGPoint) {
        let dx = target.position.x - source.position.x
        let dy = target.position.y - source.position.y

        if abs(dy) > abs(dx), abs(dx) < RoutingNodeCardMetrics.width * 0.85 {
            let verticalDirection: CGFloat = dy >= 0 ? 1 : -1
            return (
                CGPoint(x: source.position.x, y: source.position.y + RoutingNodeCardMetrics.halfHeight * verticalDirection),
                CGPoint(x: target.position.x, y: target.position.y - RoutingNodeCardMetrics.halfHeight * verticalDirection)
            )
        }

        let horizontalDirection: CGFloat = dx >= 0 ? 1 : -1
        return (
            CGPoint(x: source.position.x + RoutingNodeCardMetrics.halfWidth * horizontalDirection, y: source.position.y),
            CGPoint(x: target.position.x - RoutingNodeCardMetrics.halfWidth * horizontalDirection, y: target.position.y)
        )
    }

    private func drawGrid(in size: CGSize, context: inout GraphicsContext) {
        let spacing: CGFloat = 24
        var path = Path()

        stride(from: CGFloat(0), through: size.width, by: spacing).forEach { x in
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }

        stride(from: CGFloat(0), through: size.height, by: spacing).forEach { y in
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }

        context.stroke(path, with: .color(.white.opacity(0.035)), lineWidth: 1)
    }

    private func drawConnection(
        from start: CGPoint,
        to end: CGPoint,
        color: Color,
        dashed: Bool = false,
        context: inout GraphicsContext
    ) {
        var path = Path()
        path.move(to: start)

        if abs(end.y - start.y) > abs(end.x - start.x) {
            let direction: CGFloat = end.y >= start.y ? 1 : -1
            let controlOffset = min(max(abs(end.y - start.y) * 0.42, 72), 170)
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x, y: start.y + (controlOffset * direction)),
                control2: CGPoint(x: end.x, y: end.y - (controlOffset * direction))
            )
        } else {
            let direction: CGFloat = end.x >= start.x ? 1 : -1
            let controlOffset = min(max(abs(end.x - start.x) * 0.42, 96), 210)
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x + (controlOffset * direction), y: start.y),
                control2: CGPoint(x: end.x - (controlOffset * direction), y: end.y)
            )
        }

        context.stroke(
            path,
            with: .color(.black.opacity(0.34)),
            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round, dash: dashed ? [7, 6] : [])
        )
        context.stroke(
            path,
            with: .color(color.opacity(dashed ? 0.88 : 0.72)),
            style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round, dash: dashed ? [7, 6] : [])
        )
    }

    private func wireColor(from source: RoutingNode, to target: RoutingNode) -> Color {
        if target.kind == .output, target.audioOutputUID != nil {
            return Color.pureQGreen
        }
        return .white.opacity(0.50)
    }
}

struct EditableRoutingNodeCard: View {
    @EnvironmentObject private var model: EqualizerModel
    let node: RoutingNode
    let canvasSize: CGSize
    @State private var dragOffset: CGSize?
    @State private var liveDragTranslation: CGSize = .zero

    var body: some View {
        ZStack {
            HStack {
                port
                    .offset(x: -10)
                Spacer()
                port
                    .offset(x: 10)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: nodeIcon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(nodeColor)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.title)
                            .font(.callout.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Text(node.subtitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }

                    Spacer(minLength: 4)

                    Text(node.kind.title)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(nodeColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(nodeColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }

                HStack(spacing: 7) {
                    Button {
                        model.patchRoutingNode(id: node.id)
                    } label: {
                        Image(systemName: model.patchStartNodeID == node.id ? "link.circle.fill" : "link")
                    }
                    .buttonStyle(MiniIconButtonStyle(active: model.patchStartNodeID == node.id))
                    .help("Patch node")

                    Button {
                        model.disconnectRoutingNode(id: node.id)
                    } label: {
                        Image(systemName: "link.slash")
                    }
                    .buttonStyle(MiniIconButtonStyle())
                    .help("Disconnect node")

                    if node.kind == .equalizer {
                        Button {
                            model.setActiveEQNode(id: node.id)
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .buttonStyle(MiniIconButtonStyle(active: model.activeEQNode?.id == node.id))
                        .help("Set EQ tab target")
                    }

                    Spacer(minLength: 4)

                    Text(connectionSummary)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)

                    Button {
                        model.removeRoutingNode(id: node.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(MiniIconButtonStyle())
                    .help("Remove node")
                }

                if node.kind == .source {
                    SourceNodeMixer(nodeID: node.id, compact: true)
                }
            }
            .padding(11)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(nodeBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: model.selectedRoutingNodeID == node.id ? 1.8 : 1)
        )
        .shadow(color: .black.opacity(model.selectedRoutingNodeID == node.id ? 0.38 : 0.22), radius: 8, y: 4)
        .offset(liveDragTranslation)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .gesture(dragGesture)
        .onTapGesture {
            model.selectRoutingNode(id: node.id)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("routingCanvas"))
            .onChanged { value in
                if dragOffset == nil {
                    dragOffset = CGSize(
                        width: node.position.x - value.location.x,
                        height: node.position.y - value.location.y
                    )
                    model.selectRoutingNode(id: node.id)
                }

                let offset = dragOffset ?? .zero
                let targetPosition = clampedPosition(
                    CGPoint(x: value.location.x + offset.width, y: value.location.y + offset.height)
                )
                liveDragTranslation = CGSize(
                    width: targetPosition.x - node.position.x,
                    height: targetPosition.y - node.position.y
                )
            }
            .onEnded { _ in
                let finalPosition = CGPoint(
                    x: node.position.x + liveDragTranslation.width,
                    y: node.position.y + liveDragTranslation.height
                )
                model.moveRoutingNode(id: node.id, to: finalPosition, in: canvasSize)
                dragOffset = nil
                liveDragTranslation = .zero
            }
    }

    private func clampedPosition(_ position: CGPoint) -> CGPoint {
        CGPoint(
            x: position.x.clamped(to: 118...max(118, canvasSize.width - 118)),
            y: position.y.clamped(to: 72...max(72, canvasSize.height - 72))
        )
    }

    private var nodeColor: Color {
        if node.kind == .output, node.audioOutputUID != nil {
            return Color.pureQGreen
        }
        return node.kind.accent
    }

    private var nodeBackground: Color {
        model.selectedRoutingNodeID == node.id ? Color(red: 0.16, green: 0.18, blue: 0.20) : Color.pureQControl
    }

    private var nodeIcon: String {
        if node.kind == .source,
           let sourceID = node.audioSourceID,
           let source = model.availableAudioSources.first(where: { $0.id == sourceID }) {
            return source.systemImage
        }
        return node.kind.systemImage
    }

    private var borderColor: Color {
        if model.patchStartNodeID == node.id { return Color.pureQAmber }
        if model.selectedRoutingNodeID == node.id { return nodeColor }
        return Color.pureQStroke
    }

    private var connectionSummary: String {
        let incoming = model.routingConnections.filter { $0.to == node.id }.count
        let outgoing = model.routingConnections.filter { $0.from == node.id }.count
        return "\(incoming) in / \(outgoing) out"
    }

    private var port: some View {
        Circle()
            .fill(Color.pureQBackground)
            .frame(width: 13, height: 13)
            .overlay(Circle().stroke(borderColor.opacity(0.86), lineWidth: 2))
    }
}

struct SourceNodeMixer: View {
    @EnvironmentObject private var model: EqualizerModel
    let nodeID: RoutingNode.ID
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            Button {
                model.toggleRoutingSourceMute(id: nodeID)
            } label: {
                Text("M")
                    .font(.caption2.weight(.black))
                    .frame(width: compact ? 24 : 30, height: compact ? 22 : 26)
            }
            .buttonStyle(SourceMixerButtonStyle(active: model.routingSourceMuted(id: nodeID), tint: Color.pureQOrange))
            .help("Mute this source route")

            Button {
                model.toggleRoutingSourceSolo(id: nodeID)
            } label: {
                Text("S")
                    .font(.caption2.weight(.black))
                    .frame(width: compact ? 24 : 30, height: compact ? 22 : 26)
            }
            .buttonStyle(SourceMixerButtonStyle(active: model.routingSourceSoloed(id: nodeID), tint: Color.pureQAmber))
            .help("Solo this source route")

            Slider(
                value: Binding(get: {
                    model.routingSourceVolume(id: nodeID)
                }, set: { value in
                    model.setRoutingSourceVolume(id: nodeID, volume: value, persist: false)
                }),
                in: 0...2,
                onEditingChanged: { editing in
                    if !editing {
                        model.commitRoutingSourceVolume(id: nodeID)
                    }
                }
            )
            .tint(Color.pureQGreen)
            .frame(minWidth: compact ? 72 : 110)
            .help("Source volume")

            Text("\(Int((model.routingSourceVolume(id: nodeID) * 100).rounded()))%")
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: compact ? 36 : 42, alignment: .trailing)
        }
    }
}

struct SourceMixerButtonStyle: ButtonStyle {
    let active: Bool
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? tint : .secondary)
            .background(active ? tint.opacity(0.18) : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(active ? tint.opacity(0.58) : Color.pureQStroke, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

struct RoutingInspector: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let node {
                    inspectorSection("Selected", systemImage: node.kind.systemImage) {
                        TextField("Name", text: Binding(get: {
                            node.title
                        }, set: { newTitle in
                            model.renameRoutingNode(id: node.id, title: newTitle)
                        }))
                        .textFieldStyle(.roundedBorder)

                        Picker("Type", selection: Binding(get: {
                            node.kind
                        }, set: { kind in
                            model.setRoutingNodeKind(id: node.id, kind: kind)
                        })) {
                            ForEach(RoutingNodeKind.allCases.filter { kind in
                                kind != .bus && (node.kind == .monitor || kind != .monitor)
                            }) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                    }

                    if node.kind == .source {
                        inspectorSection("Source", systemImage: "music.note.list") {
                            Picker("Source", selection: Binding(get: {
                                node.audioSourceID ?? AudioSourceItem.systemMixID
                            }, set: { sourceID in
                                model.setRoutingNodeSource(id: node.id, sourceID: sourceID)
                            })) {
                                ForEach(model.availableAudioSources) { source in
                                    Text(source.title).tag(source.id)
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Mixer")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                                SourceNodeMixer(nodeID: node.id)
                            }
                        }
                    }

                    if node.kind == .output {
                        inspectorSection("Output", systemImage: "speaker.wave.2.fill") {
                            Picker("Device", selection: Binding(get: {
                                node.audioOutputUID ?? ""
                            }, set: { uid in
                                model.setRoutingNodeOutput(id: node.id, uid: uid.isEmpty ? nil : uid)
                            })) {
                                Text("Unassigned").tag("")
                                ForEach(model.hardwareOutputDevices) { device in
                                    Text(device.name).tag(device.uid)
                                }
                            }

                        }
                    }

                    if node.kind == .equalizer {
                        inspectorSection("EQ Profile", systemImage: "slider.horizontal.3") {
                            HStack {
                                Label("Unique", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(Color.pureQGreen)
                                Spacer()
                                Text(eqSummary(for: node))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption.weight(.semibold))

                            Button {
                                model.setActiveEQNode(id: node.id)
                            } label: {
                                Label("Set EQ Target", systemImage: "slider.horizontal.3")
                            }
                            .buttonStyle(RouteActionButtonStyle(active: model.activeEQNode?.id == node.id))

                            Button {
                                model.setActiveEQNode(id: node.id)
                                model.copyMainEqualizerToActiveNode()
                            } label: {
                                Label("Copy Main", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(RouteActionButtonStyle(active: false))
                        }
                    }

                    inspectorSection("Links", systemImage: "link") {
                        HStack(spacing: 8) {
                            Text(connectionSummary(for: node))
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        Button {
                            model.patchRoutingNode(id: node.id)
                        } label: {
                            Label(model.patchStartNodeID == node.id ? "Cancel Patch" : "Patch", systemImage: "link")
                        }
                        .buttonStyle(RouteActionButtonStyle(active: model.patchStartNodeID == node.id))

                        Button {
                            model.disconnectRoutingNode(id: node.id)
                        } label: {
                            Label("Disconnect", systemImage: "link.slash")
                        }
                        .buttonStyle(RouteActionButtonStyle(active: false))
                    }

                    Button(role: .destructive) {
                        model.removeRoutingNode(id: node.id)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .padding(.top, 2)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("No Selection", systemImage: "cursorarrow.click")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            Label("\(model.routingNodes.count)", systemImage: "square.stack.3d.up")
                            Label("\(model.routingConnections.count)", systemImage: "link")
                        }
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.pureQPanel)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.pureQStroke)
                .frame(width: 1)
        }
    }

    private var node: RoutingNode? {
        guard let selectedID = model.selectedRoutingNodeID else { return nil }
        return model.routingNodes.first(where: { $0.id == selectedID })
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pureQControl.opacity(0.78), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.pureQStroke, lineWidth: 1)
        )
    }

    private func connectionSummary(for node: RoutingNode) -> String {
        let incoming = model.routingConnections.filter { $0.to == node.id }.count
        let outgoing = model.routingConnections.filter { $0.from == node.id }.count
        return "\(incoming) input / \(outgoing) output"
    }

    private func eqSummary(for node: RoutingNode) -> String {
        let activeCount = node.eqBands.filter { $0.isEnabled && abs($0.gain) > 0.01 }.count
        return "\(model.eqBandLayoutTitle(for: node)), \(activeCount) active"
    }
}

struct RouteActionButtonStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(active ? Color.pureQGreen : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(active ? Color.pureQGreen.opacity(0.15) : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(active ? Color.pureQGreen.opacity(0.48) : Color.pureQStroke, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
