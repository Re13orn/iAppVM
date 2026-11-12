import SwiftUI

/// Script Market: browse built-in scenario scripts and attach them to
/// specific guest apps in one tap. Attached scripts run on the app's next
/// launch (same mechanism as the manual script library).
struct LCFridaScriptMarketView: View {
    @EnvironmentObject private var sharedModel: SharedModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedScript: LCFridaMarketScript?
    @State private var showAppPicker = false
    @State private var errorInfo: String?
    @State private var errorShow = false
    @State private var successInfo: String?
    @State private var successShow = false

    private var apps: [LCAppModel] {
        sharedModel.apps + sharedModel.hiddenApps
    }

    var body: some View {
        List {
            Section {
                Text("lc.market.header".loc)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("lc.market.section.builtin".loc) {
                ForEach(LCFridaScriptMarket.scripts) { script in
                    marketRow(for: script)
                }
            }
            Section {
                Text("lc.market.note".loc)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("lc.market.title".loc)
        .sheet(isPresented: $showAppPicker) {
            if let script = selectedScript {
                LCFridaMarketAppPicker(script: script) { app in
                    do {
                        try LCFridaScriptMarket.enable(script, model: app)
                        successInfo = "lc.market.attachSuccess".localizeWithFormat(script.name, app.displayName)
                        successShow = true
                    } catch {
                        errorInfo = error.localizedDescription
                        errorShow = true
                    }
                }
            }
        }
        .alert("lc.market.title".loc, isPresented: $errorShow) {
            Button("lc.common.ok".loc, role: .cancel) {}
        } message: {
            Text(errorInfo ?? "")
        }
        .alert("lc.market.title".loc, isPresented: $successShow) {
            Button("lc.common.ok".loc, role: .cancel) {}
        } message: {
            Text(successInfo ?? "")
        }
    }

    private func marketRow(for script: LCFridaMarketScript) -> some View {
        let attached: [LCAppModel] = apps.filter { app in
            let folder = LCFridaSetup.folder(for: app.appInfo) ?? LCPath.tweakPath
            return script.isEnabled(for: folder)
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: script.symbol)
                    .foregroundStyle(.tint)
                Text(script.name).font(.headline)
                Spacer()
                Button("lc.market.attach".loc) {
                    selectedScript = script
                    showAppPicker = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Text(script.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(attached, id: \.appInfo.relativeBundlePath) { app in
                HStack {
                    Text(app.displayName)
                        .font(.subheadline)
                    Spacer()
                    Button("lc.market.detach".loc) {
                        do {
                            try LCFridaScriptMarket.disable(script, model: app)
                            successInfo = "lc.market.detachSuccess".localizeWithFormat(script.name, app.displayName)
                            successShow = true
                        } catch {
                            errorInfo = error.localizedDescription
                            errorShow = true
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.mini)
                }
                .padding(.leading, 8)
            }
        }
        .padding(.vertical, 2)
    }
}

/// App picker sheet shown when attaching a market script.
struct LCFridaMarketAppPicker: View {
    @EnvironmentObject private var sharedModel: SharedModel
    @Environment(\.dismiss) private var dismiss

    let script: LCFridaMarketScript
    let onPick: (LCAppModel) -> Void

    @State private var errorInfo: String?
    @State private var errorShow = false

    private var apps: [LCAppModel] {
        let all = sharedModel.apps + sharedModel.hiddenApps
        return all.sorted { left, right in
            left.displayName < right.displayName
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("lc.market.picker.header".localizeWithFormat(script.name))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(apps, id: \.appInfo.relativeBundlePath) { app in
                        Button {
                            onPick(app)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "app")
                                    .resizable()
                                    .frame(width: 28, height: 28)
                                    .cornerRadius(8)
                                    .foregroundStyle(.tint)
                                Text(app.displayName)
                                Spacer()
                                if script.isEnabled(for: LCFridaSetup.folder(for: app.appInfo) ?? LCPath.tweakPath) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            .navigationTitle("lc.market.picker.title".loc)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.market.cancel".loc) { dismiss() }
                }
            }
        }
    }
}