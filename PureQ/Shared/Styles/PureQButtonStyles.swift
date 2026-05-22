//
//  PureQButtonStyles.swift
//  PureQ
//

import SwiftUI

struct PowerToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(configuration.isOn ? Color.pureQGreen.opacity(0.22) : Color.black.opacity(0.25))
                .frame(width: 54, height: 28)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(configuration.isOn ? Color.pureQGreen : Color(red: 0.09, green: 0.10, blue: 0.12))
                        .frame(width: 20, height: 20)
                        .padding(4)
                        .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.pureQStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

struct RouteToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white.opacity(0.86))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.pureQControl, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.pureQStroke, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct IconButtonStyle: ButtonStyle {
    let size: CGFloat
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(active ? Color.pureQGreen : .white.opacity(0.82))
            .frame(width: size, height: size)
            .background(active ? Color.pureQGreen.opacity(0.16) : Color.pureQControl, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.pureQStroke, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

struct MiniIconButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(active ? Color.pureQGreen : .white.opacity(0.72))
            .frame(width: 23, height: 23)
            .background(active ? Color.pureQGreen.opacity(0.16) : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(active ? Color.pureQGreen.opacity(0.48) : Color.pureQStroke, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

struct MiniToggleButtonStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? Color.pureQGreen : .secondary)
            .frame(width: 22, height: 22)
            .background(Color.pureQControl, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.pureQStroke, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

struct PillButtonStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(active ? Color.pureQGreen : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(Color.pureQControl, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.pureQStroke, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private extension View {
    @ViewBuilder
    func pureQHardwareAccelerated(_ enabled: Bool) -> some View {
        if enabled {
            self.drawingGroup(opaque: false, colorMode: .linear)
        } else {
            self
        }
    }
}
