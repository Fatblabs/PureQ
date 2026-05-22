//
//  ContentView.swift
//  PureQ
//

import SwiftUI

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case equalizer = "Equalizer"
    case routing = "Routing"
    case about = "About"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .equalizer: return "slider.horizontal.3"
        case .routing: return "point.topleft.down.curvedto.point.bottomright.up"
        case .about: return "info.circle"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: EqualizerModel
    @State private var selectedWorkspace: WorkspaceTab = .equalizer
    @State private var showingConsole = false
    @State private var graphicalSurfaceID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            WorkspaceSwitcher(selectedWorkspace: $selectedWorkspace)

            Group {
                switch selectedWorkspace {
                case .equalizer:
                    EqualizerWorkspace()
                case .routing:
                    RoutingWorkspace()
                case .about:
                    AboutWorkspace()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showingConsole {
                ReadinessConsole(isPresented: $showingConsole)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            StatusFooter(showingConsole: $showingConsole)
        }
        .frame(minWidth: 760, minHeight: 620)
        .background(Color.pureQBackground)
        .foregroundStyle(.white.opacity(0.88))
        .background(ClickOutsideEditableTextFieldObserver())
        .onAppear {
            model.setGraphicalSurface(id: graphicalSurfaceID, visible: true)
            model.setActiveUndoScope(undoScope(for: selectedWorkspace))
        }
        .onDisappear {
            model.setGraphicalSurface(id: graphicalSurfaceID, visible: false)
            model.setActiveUndoScope(nil)
        }
        .onChange(of: selectedWorkspace) { _, newValue in
            model.setActiveUndoScope(undoScope(for: newValue))
        }
        .onChange(of: model.readinessSummary) { _, newValue in
            if newValue == .blocked {
                showingConsole = true
            }
        }
        .onChange(of: model.audioEngineRunState) { _, newValue in
            if case .failed = newValue {
                showingConsole = true
            }
        }
    }

    private func undoScope(for tab: WorkspaceTab) -> PureQUndoScope? {
        switch tab {
        case .equalizer:
            return .equalizer
        case .routing:
            return .routing
        case .about:
            return nil
        }
    }
}


#Preview {
    let model = EqualizerModel()
    ContentView()
        .environmentObject(model)
        .environmentObject(model.telemetryStore)
}
