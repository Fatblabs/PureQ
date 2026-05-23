//
//  BandControls.swift
//  PureQ
//

import SwiftUI

struct PreampRow: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                preampControls
                Divider()
                    .frame(height: 30)
                BalanceControl(
                    value: model.activeEQBalance,
                    onChange: { model.setActiveEQBalance($0) }
                )
                .frame(width: 330)
            }

            VStack(spacing: 8) {
                preampControls
                BalanceControl(
                    value: model.activeEQBalance,
                    onChange: { model.setActiveEQBalance($0) }
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(red: 0.18, green: 0.19, blue: 0.21))
    }

    private var preampControls: some View {
        HStack(spacing: 10) {
            Text("Preamp:")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.pureQControl, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            Slider(value: Binding(get: {
                model.activeEQPreamp
            }, set: { value in
                model.setActiveEQPreamp(value)
            }), in: -20...20)
            .tint(Color.pureQGreen)

            Text(String(format: "%.1fdB", model.activeEQPreamp))
                .font(.callout.monospacedDigit().weight(.semibold))
                .frame(width: 82)
                .padding(.vertical, 4)
                .background(Color.pureQControl, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Toggle("Auto", isOn: Binding(get: {
                model.activeEQAutoGainEnabled
            }, set: { enabled in
                model.setActiveEQAutoGain(enabled)
            }))
            .toggleStyle(.checkbox)
            .font(.callout.weight(.semibold))
            .help("Automatically lower preamp to offset the largest enabled boost")

            EQClippingIndicator(status: model.activeEQClippingStatus)
        }
    }
}

struct EQClippingIndicator: View {
    let status: EQClippingStatus

    var body: some View {
        Label(label, systemImage: systemImage)
            .font(.caption.monospacedDigit().weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(tint.opacity(0.38), lineWidth: 1)
            )
            .help(helpText)
    }

    private var label: String {
        switch status.risk {
        case .safe:
            return String(format: "Headroom %.1fdB", status.headroomDecibels)
        case .caution:
            return String(format: "Near clip %.1fdB", status.peakDecibels)
        case .clipping:
            return String(format: "Clip +%.1fdB", status.clipAmountDecibels)
        }
    }

    private var systemImage: String {
        switch status.risk {
        case .safe: return "checkmark.circle.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .clipping: return "waveform.path.badge.exclamationmark"
        }
    }

    private var tint: Color {
        switch status.risk {
        case .safe: return Color.pureQGreen
        case .caution: return Color.pureQAmber
        case .clipping: return Color.pureQOrange
        }
    }

    private var helpText: String {
        "Estimated peak EQ gain after preamp. Positive values can clip full-scale audio."
    }
}

struct BalanceControl: View {
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        VStack(spacing: 3) {
            Text("Balance")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("Left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                BandValueField(
                    value: leftPercent,
                    range: 0...100,
                    suffix: "%",
                    decimals: 0,
                    compact: true,
                    onCommit: { percent in
                        onChange(((100 - percent) / 100).clamped(to: -1...1))
                    }
                )
                .frame(width: 52)

                Slider(value: Binding(get: {
                    value
                }, set: { newValue in
                    onChange(newValue)
                }), in: -1...1)
                .tint(Color.pureQGreen)
                .frame(minWidth: 90)

                BandValueField(
                    value: rightPercent,
                    range: 0...100,
                    suffix: "%",
                    decimals: 0,
                    compact: true,
                    onCommit: { percent in
                        onChange((-(100 - percent) / 100).clamped(to: -1...1))
                    }
                )
                .frame(width: 52)

                Text("Right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var leftPercent: Double {
        value <= 0 ? 100 : (1 - value).clamped(to: 0...1) * 100
    }

    private var rightPercent: Double {
        value >= 0 ? 100 : (1 + value).clamped(to: 0...1) * 100
    }
}

struct BandLayoutMenu: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        Menu {
            ForEach(EqualizerBandLayout.allCases) { layout in
                Button {
                    model.setActiveEQBandLayout(layout)
                } label: {
                    if model.activeEQBandLayout == layout {
                        Label(layout.title, systemImage: "checkmark")
                    } else {
                        Text(layout.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.vertical.3")
                Text(model.activeEQBandLayoutTitle)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.bold))
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white.opacity(0.86))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.pureQControl, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.pureQStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .help("Switch band layout while matching the current curve")
    }
}

struct BandScroller: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 8) {
                ForEach(model.activeEQVisibleBands) { band in
                    BandStrip(
                        band: band,
                        width: 74,
                        onFrequencyChange: { model.setActiveEQBandFrequency(id: band.id, frequency: $0) },
                        onGainChange: { model.setActiveEQBandGain(id: band.id, gain: $0, persist: false) },
                        onGainCommit: { model.setActiveEQBandGain(id: band.id, gain: $0, persist: true) },
                        onQChange: { model.setActiveEQBandQ(id: band.id, q: $0, persist: false) },
                        onQCommit: { model.setActiveEQBandQ(id: band.id, q: $0, persist: true) },
                        onToggleEnabled: { model.toggleActiveEQBand(id: band.id) },
                        onToggleStereoLink: { model.toggleActiveEQStereoLink(id: band.id) },
                        onCycleShape: { model.cycleActiveEQShape(id: band.id) }
                    )
                }

                AddBandStrip(width: 74) {
                    model.addActiveEQBand()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(minHeight: 342, idealHeight: 356, maxHeight: 382)
        .background(Color(red: 0.17, green: 0.18, blue: 0.20))
    }
}

struct BandStrip: View {
    let band: EqualizerBand
    let width: CGFloat
    let onFrequencyChange: (Double) -> Void
    let onGainChange: (Double) -> Void
    let onGainCommit: (Double) -> Void
    let onQChange: (Double) -> Void
    let onQCommit: (Double) -> Void
    let onToggleEnabled: () -> Void
    let onToggleStereoLink: () -> Void
    let onCycleShape: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Button(action: onToggleEnabled) {
                    Image(systemName: band.isEnabled ? "checkmark" : "xmark")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(MiniToggleButtonStyle(active: band.isEnabled))
                .help(band.isEnabled ? "Disable band" : "Enable band")

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(colorForBand)
                    .frame(width: 19, height: 19)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(.black.opacity(0.45), lineWidth: 2)
                    )
            }

            Button(action: onToggleStereoLink) {
                Image(systemName: band.isStereoLinked ? "speaker.wave.2.fill" : "speaker.wave.1")
            }
            .buttonStyle(PillButtonStyle(active: band.isStereoLinked))
            .help("Toggle stereo link")

            Button(action: onCycleShape) {
                Image(systemName: band.shape.systemImage)
            }
            .buttonStyle(PillButtonStyle(active: true))
            .help("Cycle filter shape")

            BandValueField(
                value: band.frequency,
                range: 20...20_000,
                suffix: "Hz",
                decimals: band.frequency >= 1_000 ? 0 : 1,
                compact: true,
                onCommit: onFrequencyChange
            )

            VerticalFader(
                value: band.gain,
                range: -20...20,
                meterFrequency: band.frequency,
                isEnabled: band.isEnabled,
                onChange: onGainChange,
                onEditingEnded: onGainCommit
            )
                .frame(height: 154)
                .opacity(band.isEnabled ? 1 : 0.36)

            BandValueField(
                value: band.gain,
                range: -20...20,
                suffix: "dB",
                decimals: 1,
                compact: true,
                onCommit: onGainCommit
            )

            QDial(value: band.q, onChange: onQChange, onEditingEnded: onQCommit)
                .frame(height: 54)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .frame(width: width, height: 344)
        .background(Color(red: 0.20, green: 0.21, blue: 0.23), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.pureQStroke, lineWidth: 1)
        )
    }

    private var colorForBand: Color {
        let fraction = min(max((log10(band.frequency) - log10(20)) / (log10(20_000) - log10(20)), 0), 1)
        return Color(hue: 0.04 + fraction * 0.12, saturation: 0.95, brightness: 1.0)
    }
}

struct AddBandStrip: View {
    let width: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(Color.pureQGreen.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.pureQGreen.opacity(0.45), lineWidth: 1)
                    )

                Text("Add")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.82))
            }
            .frame(width: width, height: 344)
            .background(Color(red: 0.18, green: 0.19, blue: 0.21), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.pureQGreen.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
            )
        }
        .buttonStyle(.plain)
        .help("Add a custom EQ band")
    }
}

struct BandValueField: View {
    let value: Double
    let range: ClosedRange<Double>
    var prefix: String = ""
    let suffix: String
    let decimals: Int
    var compact = false
    let onCommit: (Double) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 2) {
            if !prefix.isEmpty {
                Text(prefix)
                    .font((compact ? Font.caption2 : Font.caption).weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            TextField("", text: Binding(get: {
                isFocused ? text : formattedText(from: value)
            }, set: { newText in
                text = newText
            }))
                .textFieldStyle(.plain)
                .font((compact ? Font.caption2 : Font.caption).monospacedDigit().weight(.bold))
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
                .onSubmit(commit)

            if !suffix.isEmpty {
                Text(suffix)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .padding(.horizontal, compact ? 4 : 5)
        .padding(.vertical, compact ? 1 : 2)
        .frame(maxWidth: .infinity, minHeight: compact ? 18 : 20)
        .background(Color.pureQControl, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isFocused ? Color.pureQGreen.opacity(0.72) : .clear, lineWidth: 1)
        )
        .onAppear {
            updateText(from: value)
        }
        .onChange(of: value) { _, newValue in
            guard !isFocused else { return }
            updateText(from: newValue)
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                let currentText = text.isEmpty ? formattedText(from: value) : text
                text = trimmedNumberText(from: currentText)
            } else {
                commit()
            }
        }
    }

    private func commit() {
        let candidate = trimmedNumberText(from: text)
        guard let parsedValue = Double(candidate) else {
            updateText(from: value)
            return
        }
        let clampedValue = parsedValue.clamped(to: range)
        onCommit(clampedValue)
        updateText(from: clampedValue)
    }

    private func updateText(from value: Double) {
        text = formattedText(from: value)
    }

    private func formattedText(from value: Double) -> String {
        if decimals == 0 {
            return String(format: "%.0f", value)
        } else {
            return String(format: "%.\(decimals)f", value)
        }
    }

    private func trimmedNumberText(from text: String) -> String {
        let allowed = Set("0123456789.-")
        var result = text.filter { allowed.contains($0) }
        if result.filter({ $0 == "-" }).count > 1 {
            result.removeAll { $0 == "-" }
            result = "-" + result
        }
        if let minusIndex = result.firstIndex(of: "-"), minusIndex != result.startIndex {
            result.remove(at: minusIndex)
            result.insert("-", at: result.startIndex)
        }
        if let firstDecimal = result.firstIndex(of: ".") {
            let afterDecimal = result.index(after: firstDecimal)..<result.endIndex
            result.replaceSubrange(afterDecimal, with: result[afterDecimal].filter { $0 != "." })
        }
        return result
    }
}

struct VerticalFader: View {
    @EnvironmentObject private var telemetry: AudioTelemetryStore
    let value: Double
    let range: ClosedRange<Double>
    let meterFrequency: Double
    let isEnabled: Bool
    let onChange: (Double) -> Void
    let onEditingEnded: (Double) -> Void
    @State private var dragValue: Double?
    @State private var lastSentAt = 0.0

    var body: some View {
        GeometryReader { proxy in
            let knobHeight = 27.0
            let knobWidth = 27.0
            let trackHeight = max(proxy.size.height - knobHeight, 1)
            let effectiveValue = dragValue ?? value
            let activity = telemetry.bandActivityLevel(for: meterFrequency)
            let fraction = (effectiveValue - range.lowerBound) / (range.upperBound - range.lowerBound)
            let knobY = trackHeight * (1 - fraction)

            ZStack(alignment: .top) {
                VerticalFaderTrack(activity: activity, isEnabled: isEnabled)

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.pureQControl)
                    .frame(width: knobWidth, height: knobHeight)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.pureQStroke, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    .offset(y: knobY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let y = min(max(gesture.location.y - knobHeight / 2, 0), trackHeight)
                        let newFraction = 1 - (y / trackHeight)
                        let newValue = range.lowerBound + newFraction * (range.upperBound - range.lowerBound)
                        dragValue = newValue
                        sendThrottled(newValue)
                    }
                    .onEnded { _ in
                        if let dragValue {
                            onEditingEnded(dragValue)
                        }
                        self.dragValue = nil
                        lastSentAt = 0
                    }
            )
        }
    }

    private func sendThrottled(_ newValue: Double) {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastSentAt >= (1.0 / 30.0) else { return }
        lastSentAt = now
        onChange(newValue)
    }
}

struct VerticalFaderTrack: View {
    let activity: Double
    let isEnabled: Bool

    var body: some View {
        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            let centerX = size.width / 2
            let trackRect = CGRect(x: centerX - 4, y: 2, width: 8, height: max(size.height - 4, 1))
            let usableHeight = max(trackRect.height, 1)
            context.fill(Path(roundedRect: trackRect, cornerRadius: 4), with: .color(Color.pureQControl))
            context.stroke(Path(roundedRect: trackRect, cornerRadius: 4), with: .color(.black.opacity(0.35)), lineWidth: 1)

            for tick in 0..<7 {
                let tickFraction = CGFloat(tick) / 6.0
                let isCenterTick = tick == 3
                let width: CGFloat = isCenterTick ? 24 : 15
                let opacity = isCenterTick ? 0.68 : 0.42
                let y = trackRect.minY + usableHeight * tickFraction
                let tickRect = CGRect(x: centerX - width / 2, y: y - 1, width: width, height: 2)
                context.fill(
                    Path(roundedRect: tickRect, cornerRadius: 1),
                    with: .color(Color.pureQGreen.opacity(opacity))
                )
            }

            let meterFraction = CGFloat(activity.clamped(to: 0...1))
            guard meterFraction > 0.025 else {
                return
            }

            let meterColor = activity > 0.84 ? Color.red : Color.pureQGreen
            let meterHeight = usableHeight * meterFraction
            let meterRect = CGRect(x: centerX - 2.5, y: trackRect.maxY - meterHeight, width: 5, height: meterHeight)
            context.fill(
                Path(roundedRect: meterRect, cornerRadius: 2.5),
                with: .color(meterColor.opacity(isEnabled ? 0.46 : 0.14))
            )

            if meterFraction > 0.12 {
                let markerY = trackRect.maxY - meterHeight
                let markerRect = CGRect(x: centerX + 4.5, y: markerY - 1.25, width: 8, height: 2.5)
                context.fill(
                    Path(roundedRect: markerRect, cornerRadius: 1.25),
                    with: .color(meterColor.opacity(isEnabled ? 0.70 : 0.22))
                )
            }
        }
    }
}

struct QDial: View {
    let value: Double
    let onChange: (Double) -> Void
    let onEditingEnded: (Double) -> Void
    @State private var dragStartValue: Double?
    @State private var dragValue: Double?
    @State private var lastSentAt = 0.0

    var body: some View {
        let effectiveValue = dragValue ?? value

        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(Color.pureQGreen.opacity(0.92))
                    .overlay(Circle().stroke(Color.pureQGreen.opacity(0.55), lineWidth: 5))
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)

                Capsule()
                    .fill(Color.pureQControl)
                    .frame(width: 3, height: 15)
                    .offset(y: -6)
                    .rotationEffect(.degrees(angle(for: effectiveValue)))
            }
            .frame(width: 30, height: 30)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if dragStartValue == nil {
                            dragStartValue = value
                        }
                        let delta = Double(gesture.translation.width - gesture.translation.height) * 0.015
                        let newValue = ((dragStartValue ?? value) + delta).clamped(to: 0.1...10)
                        dragValue = newValue
                        sendThrottled(newValue)
                    }
                    .onEnded { _ in
                        if let dragValue {
                            onEditingEnded(dragValue)
                        }
                        dragStartValue = nil
                        dragValue = nil
                        lastSentAt = 0
                    }
            )

            BandValueField(
                value: effectiveValue,
                range: 0.1...10,
                prefix: "Q:",
                suffix: "",
                decimals: 3,
                compact: true,
                onCommit: onEditingEnded
            )
        }
    }

    private func angle(for value: Double) -> Double {
        let fraction = (value - 0.1) / (10 - 0.1)
        return -135 + fraction * 270
    }

    private func sendThrottled(_ newValue: Double) {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastSentAt >= (1.0 / 30.0) else { return }
        lastSentAt = now
        onChange(newValue)
    }
}
