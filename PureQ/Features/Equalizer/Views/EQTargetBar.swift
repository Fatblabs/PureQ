//
//  EQTargetBar.swift
//  PureQ
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let pureQEQProfile = UTType(filenameExtension: "pureqeq") ?? .json
    static let equaliserEQPreset = UTType(filenameExtension: "eqpreset") ?? .json
}

struct EQTargetBar: View {
    @EnvironmentObject private var model: EqualizerModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullBar
            compactBar
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(red: 0.13, green: 0.14, blue: 0.16))
    }

    private var fullBar: some View {
        HStack(spacing: 10) {
            Label("EQ Target", systemImage: "slider.horizontal.3")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 116, alignment: .leading)

            Picker("EQ target", selection: Binding(get: {
                model.activeEQNode?.id
            }, set: { nodeID in
                model.setActiveEQNode(id: nodeID)
            })) {
                Text("Main Equalizer").tag(RoutingNode.ID?.none)
                ForEach(model.eqRoutingNodes) { node in
                    Text(node.title).tag(Optional(node.id))
                }
            }
            .labelsHidden()
            .frame(width: 226)

            if model.activeEQNode != nil {
                Label("Unique Profile", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.pureQGreen)

                Button {
                    model.copyMainEqualizerToActiveNode()
                } label: {
                    Label("Copy Main", systemImage: "doc.on.doc")
                }
                .buttonStyle(RouteToolbarButtonStyle())
                .help("Copy the main equalizer profile into this EQ node")
            }

            profileFileMenu(labelStyle: .titleAndIcon)

            Divider()
                .frame(height: 24)
                .overlay(Color.pureQStroke)

            Text(model.activeEQTitle)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)

            Text(model.activeEQProfileSummary)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let message = model.eqFileMessage {
                Text(message)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.pureQGreen)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
    }

    private var compactBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("EQ target", selection: Binding(get: {
                model.activeEQNode?.id
            }, set: { nodeID in
                model.setActiveEQNode(id: nodeID)
            })) {
                Text("Main Equalizer").tag(RoutingNode.ID?.none)
                ForEach(model.eqRoutingNodes) { node in
                    Text(node.title).tag(Optional(node.id))
                }
            }
            .labelsHidden()
            .frame(width: 210)

            if model.activeEQNode != nil {
                Button {
                    model.copyMainEqualizerToActiveNode()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(IconButtonStyle(size: 30))
                .help("Copy the main equalizer profile into this EQ node")
            }

            profileFileMenu(labelStyle: .iconOnly)

            Spacer(minLength: 4)

            Text(model.activeEQTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func profileFileMenu(labelStyle: EQProfileFileMenuLabelStyle) -> some View {
        switch labelStyle {
        case .titleAndIcon:
            Menu {
                profileFileMenuItems
            } label: {
                Label("EQ File", systemImage: "doc.badge.gearshape")
            }
            .buttonStyle(RouteToolbarButtonStyle())
            .help("Import or export the selected EQ profile")
        case .iconOnly:
            Menu {
                profileFileMenuItems
            } label: {
                Image(systemName: "doc.badge.gearshape")
            }
            .buttonStyle(IconButtonStyle(size: 30))
            .help("Import or export the selected EQ profile")
        }
    }

    @ViewBuilder
    private var profileFileMenuItems: some View {
        Button {
            importProfile()
        } label: {
            Label("Import EQ Profile...", systemImage: "square.and.arrow.down")
        }

        Button {
            exportProfile()
        } label: {
            Label("Export EQ Profile...", systemImage: "square.and.arrow.up")
        }
    }

    private func exportProfile() {
        let panel = NSSavePanel()
        panel.title = "Export PureQ EQ Profile"
        panel.nameFieldStringValue = "\(sanitizedFileName(model.activeEQTitle)).pureqeq"
        panel.allowedContentTypes = [.pureQEQProfile, .json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try model.exportActiveEQProfile(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.title = "Import EQ Profile"
        panel.allowedContentTypes = [.pureQEQProfile, .equaliserEQPreset, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try model.importEQProfile(from: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func sanitizedFileName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let sanitized = name
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "PureQ EQ Profile" : sanitized
    }
}

private enum EQProfileFileMenuLabelStyle {
    case titleAndIcon
    case iconOnly
}

