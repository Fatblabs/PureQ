//
//  EqualizerGraph.swift
//  PureQ
//

import SwiftUI

private let equalizerGraphBandDragCoordinateSpace = "PureQ.EqualizerGraphBandDragCoordinateSpace"

struct EqualizerGraph: View {
    let bands: [EqualizerBand]
    let preamp: Double
    var responseSampleRate = 48_000.0
    var spectrumLevels: [Double] = []
    var bandEditingEnabled = false
    var onBandPositionChange: ((EqualizerBand.ID, Double, Double) -> Void)?
    var onBandPositionCommit: ((EqualizerBand.ID, Double, Double) -> Void)?

    private let minimumFrequency = 20.0
    private let maximumFrequency = 20_000.0
    private let minimumDB = -20.0
    private let maximumDB = 20.0

    var body: some View {
        ZStack {
            Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
                let plot = plotRect(in: size)
                drawGrid(in: plot, context: &context)
                drawCurve(in: plot, context: &context)
            }

            if !spectrumLevels.isEmpty {
                EqualizerSpectrumOverlay(
                    spectrumLevels: spectrumLevels,
                    minimumFrequency: minimumFrequency,
                    maximumFrequency: maximumFrequency
                )
                .allowsHitTesting(false)
            }
        }
        .overlay {
            if bandEditingEnabled {
                EqualizerGraphBandHandles(
                    bands: bands,
                    preamp: preamp,
                    minimumFrequency: minimumFrequency,
                    maximumFrequency: maximumFrequency,
                    minimumDB: minimumDB,
                    maximumDB: maximumDB,
                    onBandPositionChange: onBandPositionChange,
                    onBandPositionCommit: onBandPositionCommit
                )
            }
        }
        .background(Color.pureQBackground)
    }

    private func plotRect(in size: CGSize) -> CGRect {
        CGRect(x: 54, y: 18, width: max(size.width - 108, 10), height: max(size.height - 56, 10))
    }

    private func drawGrid(in plot: CGRect, context: inout GraphicsContext) {
        let majorFrequencies: [Double] = [20, 40, 100, 200, 400, 1_000, 2_000, 4_000, 10_000, 20_000]
        let majorDB: [Double] = [-20, -10, 0, 10, 20]

        for db in majorDB {
            let y = yPosition(for: db, in: plot)
            var path = Path()
            path.move(to: CGPoint(x: plot.minX, y: y))
            path.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(path, with: .color(db == 0 ? .white.opacity(0.70) : .white.opacity(0.13)), lineWidth: db == 0 ? 2 : 1)

            let label = "\(Int(db))dB"
            context.draw(
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.58)),
                at: CGPoint(x: plot.minX - 30, y: y),
                anchor: .center
            )
            context.draw(
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.58)),
                at: CGPoint(x: plot.maxX + 30, y: y),
                anchor: .center
            )
        }

        for frequency in EqualizerBand.standardFrequencies {
            let x = xPosition(for: frequency, in: plot)
            var path = Path()
            path.move(to: CGPoint(x: x, y: plot.minY))
            path.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 1)
        }

        for frequency in majorFrequencies {
            let x = xPosition(for: frequency, in: plot)
            var path = Path()
            path.move(to: CGPoint(x: x, y: plot.minY))
            path.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(path, with: .color(.white.opacity(0.13)), lineWidth: 1.2)

            context.draw(
                Text(shortFrequencyLabel(frequency)).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.58)),
                at: CGPoint(x: x, y: plot.maxY + 22),
                anchor: .center
            )
        }
    }

    private func drawCurve(in plot: CGRect, context: inout GraphicsContext) {
        let sampleCount = min(300, max(180, Int(plot.width / 5)))
        let responseSamples = (0..<sampleCount).map { index -> GraphResponseSample in
            let fraction = Double(index) / Double(sampleCount - 1)
            let frequency = pow(10, log10(minimumFrequency) + (log10(maximumFrequency) - log10(minimumFrequency)) * fraction)
            let omega = 2 * Double.pi * frequency / responseSampleRate
            return GraphResponseSample(
                frequency: frequency,
                cos1: cos(omega),
                sin1: sin(omega),
                cos2: cos(2 * omega),
                sin2: sin(2 * omega)
            )
        }
        let activeBands = bands.filter { $0.isEnabled }
        let baselineDB = preamp.clamped(to: minimumDB...maximumDB)
        let responseBands = activeBands.compactMap { band -> (band: EqualizerBand, coefficients: PureQBiquadCoefficients)? in
            guard shouldIncludeInResponse(band),
                  let coefficients = PureQBiquadMath.coefficients(
                    shape: band.shape,
                    sampleRate: responseSampleRate,
                    frequency: band.frequency,
                    q: band.q,
                    gain: band.gain
                  ) else {
                return nil
            }
            return (band, coefficients)
        }
        let shouldShowIndividualResponses = responseBands.count <= 8

        if shouldShowIndividualResponses {
            for responseBand in responseBands {
                let band = responseBand.band
                let color = bandColor(for: band.frequency)
                var strokePath = Path()

                for (index, sample) in responseSamples.enumerated() {
                    let response = (
                        baselineDB + responseBand.coefficients.magnitudeDecibels(
                            cos1: sample.cos1,
                            sin1: sample.sin1,
                            cos2: sample.cos2,
                            sin2: sample.sin2
                        )
                    ).clamped(to: minimumDB...maximumDB)
                    let point = CGPoint(x: xPosition(for: sample.frequency, in: plot), y: yPosition(for: response, in: plot))

                    if index == 0 {
                        strokePath.move(to: point)
                    } else {
                        strokePath.addLine(to: point)
                    }
                }

                context.stroke(strokePath, with: .color(color.opacity(0.34)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }

        var combinedPath = Path()
        for (index, sample) in responseSamples.enumerated() {
            let summedBands = responseBands.reduce(0.0) { partialResult, responseBand in
                partialResult + responseBand.coefficients.magnitudeDecibels(
                    cos1: sample.cos1,
                    sin1: sample.sin1,
                    cos2: sample.cos2,
                    sin2: sample.sin2
                )
            }
            let combinedDB = (preamp + summedBands).clamped(to: minimumDB...maximumDB)
            let point = CGPoint(x: xPosition(for: sample.frequency, in: plot), y: yPosition(for: combinedDB, in: plot))

            if index == 0 {
                combinedPath.move(to: point)
            } else {
                combinedPath.addLine(to: point)
            }
        }

        context.stroke(combinedPath, with: .color(.white.opacity(0.74)), style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))

        if !bandEditingEnabled {
            for responseBand in responseBands {
                let band = responseBand.band
                let point = CGPoint(
                    x: xPosition(for: band.frequency, in: plot),
                    y: yPosition(for: (preamp + band.gain).clamped(to: minimumDB...maximumDB), in: plot)
                )
                context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(bandColor(for: band.frequency)))
            }
        }
    }

    private func shouldIncludeInResponse(_ band: EqualizerBand) -> Bool {
        switch band.shape {
        case .bell:
            return abs(band.gain) > 0.01
        case .notch:
            return true
        case .shelf:
            return abs(band.gain) > 0.01
        }
    }

    private func xPosition(for frequency: Double, in rect: CGRect) -> CGFloat {
        let minLog = log10(minimumFrequency)
        let maxLog = log10(maximumFrequency)
        let fraction = (log10(frequency) - minLog) / (maxLog - minLog)
        return rect.minX + rect.width * CGFloat(fraction)
    }

    private func yPosition(for db: Double, in rect: CGRect) -> CGFloat {
        let fraction = (maximumDB - db) / (maximumDB - minimumDB)
        return rect.minY + rect.height * CGFloat(fraction)
    }

    private func shortFrequencyLabel(_ frequency: Double) -> String {
        if frequency >= 1_000 {
            let value = frequency / 1_000
            return value.rounded() == value ? "\(Int(value))K" : String(format: "%.1fK", value)
        }
        return "\(Int(frequency))"
    }

    private func bandColor(for frequency: Double) -> Color {
        let fraction = ((log10(frequency) - log10(minimumFrequency)) / (log10(maximumFrequency) - log10(minimumFrequency))).clamped(to: 0...1)
        return Color(hue: 0.04 + fraction * 0.22, saturation: 0.96, brightness: 1.0)
    }

    private struct GraphResponseSample {
        let frequency: Double
        let cos1: Double
        let sin1: Double
        let cos2: Double
        let sin2: Double
    }
}

struct EqualizerSpectrumOverlay: View {
    let spectrumLevels: [Double]
    let minimumFrequency: Double
    let maximumFrequency: Double

    var body: some View {
        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            let plot = CGRect(x: 54, y: 18, width: max(size.width - 108, 10), height: max(size.height - 56, 10))
            drawSpectrum(in: plot, context: &context)
        }
        .drawingGroup(opaque: false, colorMode: .linear)
    }

    private func drawSpectrum(in plot: CGRect, context: inout GraphicsContext) {
        guard !spectrumLevels.isEmpty else { return }

        let binCount = spectrumLevels.count
        let minLog = log10(minimumFrequency)
        let maxLog = log10(maximumFrequency)
        var outline = Path()
        var fill = Path()
        var didStart = false

        for index in spectrumLevels.indices {
            let centerFraction = (Double(index) + 0.5) / Double(binCount)
            let centerFrequency = pow(10, minLog + ((maxLog - minLog) * centerFraction))
            let level = spectrumLevels[index].clamped(to: 0...1)
            let point = CGPoint(
                x: xPosition(for: centerFrequency, in: plot),
                y: plot.maxY - (plot.height * CGFloat(level))
            )
            if !didStart {
                fill.move(to: CGPoint(x: point.x, y: plot.maxY))
                fill.addLine(to: point)
                outline.move(to: point)
                didStart = true
            } else {
                fill.addLine(to: point)
                outline.addLine(to: point)
            }
        }

        if didStart {
            let lastX = xPosition(for: maximumFrequency, in: plot)
            fill.addLine(to: CGPoint(x: lastX, y: plot.maxY))
            fill.closeSubpath()
            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [
                        Color.green.opacity(0.34),
                        Color.yellow.opacity(0.28),
                        Color.cyan.opacity(0.22)
                    ]),
                    startPoint: CGPoint(x: plot.minX, y: plot.maxY),
                    endPoint: CGPoint(x: plot.maxX, y: plot.minY)
                )
            )
        }

        context.stroke(
            outline,
            with: .color(Color.cyan.opacity(0.58)),
            style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round)
        )
    }

    private func xPosition(for frequency: Double, in rect: CGRect) -> CGFloat {
        let minLog = log10(minimumFrequency)
        let maxLog = log10(maximumFrequency)
        let fraction = (log10(frequency) - minLog) / (maxLog - minLog)
        return rect.minX + rect.width * CGFloat(fraction.clamped(to: 0...1))
    }
}

struct EqualizerGraphBandHandles: View {
    let bands: [EqualizerBand]
    let preamp: Double
    let minimumFrequency: Double
    let maximumFrequency: Double
    let minimumDB: Double
    let maximumDB: Double
    let onBandPositionChange: ((EqualizerBand.ID, Double, Double) -> Void)?
    let onBandPositionCommit: ((EqualizerBand.ID, Double, Double) -> Void)?
    @State private var activeDragBandID: EqualizerBand.ID?
    @State private var activeDragPoint: CGPoint?
    @State private var lastSentAt = 0.0

    private let hitRadius: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            let plot = CGRect(x: 54, y: 18, width: max(proxy.size.width - 108, 10), height: max(proxy.size.height - 56, 10))
            let enabledBands = bands.filter(\.isEnabled)
            ZStack {
                ForEach(enabledBands) { band in
                    let isActive = activeDragBandID == band.id
                    let displayPoint = isActive ? (activeDragPoint ?? point(for: band, in: plot)) : point(for: band, in: plot)
                    let isDimmed = activeDragBandID != nil && activeDragBandID != band.id

                    Circle()
                        .fill(bandColor(for: band.frequency))
                        .frame(width: 15, height: 15)
                        .overlay(Circle().stroke(.black.opacity(0.55), lineWidth: 2))
                        .shadow(color: bandColor(for: band.frequency).opacity(isActive ? 0.55 : 0.35), radius: isActive ? 7 : 4)
                        .opacity(isDimmed ? 0.22 : 1)
                        .scaleEffect(isActive ? 1.18 : 1)
                        .position(displayPoint)
                        .allowsHitTesting(false)
                        .zIndex(isActive ? 1 : 0)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .coordinateSpace(name: equalizerGraphBandDragCoordinateSpace)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(equalizerGraphBandDragCoordinateSpace))
                    .onChanged { gesture in
                        if activeDragBandID == nil {
                            activeDragBandID = nearestBandID(to: gesture.startLocation, in: plot, bands: enabledBands)
                        }
                        guard let activeDragBandID else { return }

                        let location = clampedLocation(gesture.location, in: plot)
                        activeDragPoint = location
                        sendThrottled(bandID: activeDragBandID, values: graphValues(for: location, in: plot))
                    }
                    .onEnded { gesture in
                        guard let activeDragBandID else {
                            resetDragState()
                            return
                        }

                        let location = clampedLocation(gesture.location, in: plot)
                        let values = graphValues(for: location, in: plot)
                        onBandPositionCommit?(activeDragBandID, values.frequency, values.gain)
                        resetDragState()
                    }
            )
            .help("Drag an enabled band to change frequency and gain")
        }
    }

    private func point(for band: EqualizerBand, in plot: CGRect) -> CGPoint {
        CGPoint(
            x: xPosition(for: band.frequency, in: plot),
            y: yPosition(for: (preamp + band.gain).clamped(to: minimumDB...maximumDB), in: plot)
        )
    }

    private func graphValues(for location: CGPoint, in plot: CGRect) -> (frequency: Double, gain: Double) {
        let xFraction = ((location.x - plot.minX) / max(plot.width, 1)).clamped(to: 0...1)
        let yFraction = ((location.y - plot.minY) / max(plot.height, 1)).clamped(to: 0...1)
        let minLog = log10(minimumFrequency)
        let maxLog = log10(maximumFrequency)
        let frequency = pow(10, minLog + ((maxLog - minLog) * Double(xFraction)))
        let graphDB = maximumDB - ((maximumDB - minimumDB) * Double(yFraction))
        let gain = (graphDB - preamp).clamped(to: minimumDB...maximumDB)
        return (frequency, gain)
    }

    private func xPosition(for frequency: Double, in rect: CGRect) -> CGFloat {
        let minLog = log10(minimumFrequency)
        let maxLog = log10(maximumFrequency)
        let fraction = (log10(frequency) - minLog) / (maxLog - minLog)
        return rect.minX + rect.width * CGFloat(fraction.clamped(to: 0...1))
    }

    private func yPosition(for db: Double, in rect: CGRect) -> CGFloat {
        let fraction = (maximumDB - db) / (maximumDB - minimumDB)
        return rect.minY + rect.height * CGFloat(fraction.clamped(to: 0...1))
    }

    private func bandColor(for frequency: Double) -> Color {
        let fraction = ((log10(frequency) - log10(minimumFrequency)) / (log10(maximumFrequency) - log10(minimumFrequency))).clamped(to: 0...1)
        return Color(hue: 0.04 + fraction * 0.22, saturation: 0.96, brightness: 1.0)
    }

    private func nearestBandID(to location: CGPoint, in plot: CGRect, bands: [EqualizerBand]) -> EqualizerBand.ID? {
        let candidates = bands.map { band -> (id: EqualizerBand.ID, distanceSquared: CGFloat, slotFrequency: Double) in
            let bandPoint = point(for: band, in: plot)
            let dx = location.x - bandPoint.x
            let dy = location.y - bandPoint.y
            return (band.id, (dx * dx) + (dy * dy), band.slotFrequency)
        }

        guard let nearest = candidates.min(by: { lhs, rhs in
            if abs(lhs.distanceSquared - rhs.distanceSquared) > 0.001 {
                return lhs.distanceSquared < rhs.distanceSquared
            }
            return lhs.slotFrequency < rhs.slotFrequency
        }), nearest.distanceSquared <= hitRadius * hitRadius else {
            return nil
        }

        return nearest.id
    }

    private func sendThrottled(bandID: EqualizerBand.ID, values: (frequency: Double, gain: Double)) {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastSentAt >= (1.0 / 30.0) else { return }
        lastSentAt = now
        onBandPositionChange?(bandID, values.frequency, values.gain)
    }

    private func clampedLocation(_ location: CGPoint, in plot: CGRect) -> CGPoint {
        CGPoint(
            x: location.x.clamped(to: plot.minX...plot.maxX),
            y: location.y.clamped(to: plot.minY...plot.maxY)
        )
    }

    private func resetDragState() {
        activeDragBandID = nil
        activeDragPoint = nil
        lastSentAt = 0
    }
}

