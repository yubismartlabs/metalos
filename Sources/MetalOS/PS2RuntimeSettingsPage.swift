import SwiftUI

struct PS2RuntimeSettingsPage: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appearance = StudioAppearance.shared
    @StateObject private var runtime = PS2RuntimeManager()
    @State private var selection = 0

    private var workspace: URL? { store.workspaceURL }
    private var actions: [String] { runtime.applicationURL == nil ? ["Install ARMSX2"] : ["Open ARMSX2 setup", "Check for updates"] }
    private var supportsRuntime: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "opticaldisc")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(appearance.accent)
                Text("PlayStation 2")
                    .font(.system(size: 28, weight: .light))
                    .tracking(-0.4)
                Spacer()
            }
            .padding(.bottom, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("MetalOS uses ARMSX2, a standalone PS2 emulator with native Apple Silicon support. The managed build is downloaded from the official project’s unsigned nightly channel.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(runtime.status)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                        if let version = runtime.installedVersion {
                            Text("Version: \(version)")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

                    if workspace == nil {
                        Text("Choose a library folder before installing the emulator.")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange.opacity(0.9))
                    } else if !supportsRuntime {
                        Text("ARMSX2’s managed macOS build requires Apple Silicon.")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange.opacity(0.9))
                    }

                    if runtime.isWorking {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small).tint(appearance.accent)
                            Text(runtime.status).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .padding(14)
                    } else {
                        VStack(spacing: 9) {
                            ForEach(Array(actions.enumerated()), id: \.offset) { index, title in
                                Button {
                                    selection = index
                                    activate(index)
                                } label: {
                                    HStack {
                                        Image(systemName: index == 0 && runtime.applicationURL != nil ? "gearshape" : "arrow.down.circle")
                                            .frame(width: 22)
                                        Text(title).font(.system(size: 13, weight: .medium))
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.system(size: 10))
                                    }
                                    .padding(15)
                                    .foregroundStyle(selection == index ? studioBackground : .white.opacity(0.88))
                                    .background(selection == index ? appearance.accent : .white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(ConsoleButtonStyle())
                                .consoleFocus(selection == index, cornerRadius: 10, scale: 1.02)
                                .disabled(workspace == nil || !supportsRuntime)
                            }
                        }
                    }

                    Text("ARMSX2 manages BIOS files, controllers, memory cards, and saves. Provide a BIOS dumped from your own PS2. macOS may ask you to approve the unsigned nightly in Privacy & Security on first launch.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 900)
                .padding(.horizontal, 42)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 34)
        .padding(.top, 27)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(appearance.background.ignoresSafeArea())
        .onAppear { runtime.refresh(workspace: workspace) }
        .consoleInput { command in
            switch command {
            case "up", "left": selection = max(selection - 1, 0)
            case "down", "right": selection = min(selection + 1, actions.count - 1)
            case "confirm": activate(selection)
            case "back": dismiss()
            default: break
            }
        }
    }

    private func activate(_ index: Int) {
        guard let workspace else { return }
        if runtime.applicationURL == nil || (runtime.applicationURL != nil && index == 1) {
            Task { await runtime.install(workspace: workspace) }
        } else {
            runtime.openSetup(workspace: workspace)
        }
    }
}
