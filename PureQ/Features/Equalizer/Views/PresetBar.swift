//
//  PresetBar.swift
//  PureQ
//

import SwiftUI

struct PresetBar: View {
    @EnvironmentObject private var model: EqualizerModel
    @State private var showingManualFlattenConfirmation = false
    @State private var showingPresetFlattenOptions = false

    var body: some View {
        HStack(spacing: 14) {
            Button {
                model.applyActiveEQSelection(.manual)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(IconButtonStyle(size: 34))
            .help("Manual editing")

            Button {
                if model.activeEQSelection == .manual {
                    showingManualFlattenConfirmation = true
                } else {
                    showingPresetFlattenOptions = true
                }
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(IconButtonStyle(size: 34))
            .help("Flatten EQ")

            BandLayoutMenu()
                .frame(width: 132)

            Menu {
                ForEach(EqualizerSelection.profileOptions) { selection in
                    Button(selection.title) {
                        model.applyActiveEQSelection(selection)
                    }
                }
            } label: {
                HStack {
                    Spacer()
                    Text(model.activeEQSelection.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                    Spacer()
                    VStack(spacing: -2) {
                        Image(systemName: "triangle.fill")
                            .font(.system(size: 10))
                        Image(systemName: "triangle.fill")
                            .font(.system(size: 10))
                            .rotationEffect(.degrees(180))
                    }
                    .foregroundStyle(Color.pureQGreen)
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Color.pureQControl, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.pureQStroke, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)

            Button {
                model.applyActiveEQSelection(.bassLift)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(IconButtonStyle(size: 34))
            .help("Add a Bass Lift preset")

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.17, green: 0.18, blue: 0.20))
        .confirmationDialog("Flatten Manual EQ?", isPresented: $showingManualFlattenConfirmation, titleVisibility: .visible) {
            Button("Flatten Manual EQ", role: .destructive) {
                model.flattenActiveEQAsManual()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This erases the current manual gains, custom frequencies, Q values, and shapes for the selected EQ.")
        }
        .confirmationDialog("Flatten Preset EQ?", isPresented: $showingPresetFlattenOptions, titleVisibility: .visible) {
            Button("Create New Flat EQ Node") {
                model.createFlatEQNodeFromActiveEQ()
            }
            Button("Switch To Manual And Flatten", role: .destructive) {
                model.flattenActiveEQAsManual()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can keep the current preset intact and work on a new flat EQ node, or replace this selected EQ with a flat manual profile.")
        }
    }
}

