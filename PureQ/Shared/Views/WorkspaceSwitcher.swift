//
//  WorkspaceSwitcher.swift
//  PureQ
//

import SwiftUI

struct WorkspaceSwitcher: View {
    @Binding var selectedWorkspace: WorkspaceTab

    var body: some View {
        HStack(spacing: 12) {
            Picker("Workspace", selection: $selectedWorkspace) {
                ForEach(WorkspaceTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 284)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(red: 0.10, green: 0.11, blue: 0.13))
    }
}

