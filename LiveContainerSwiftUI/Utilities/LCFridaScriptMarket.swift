import Foundation

/// Built-in script catalog for the Script Market.
/// Each entry maps a fixed UUID (idempotent installs) to a bundled JS
/// resource, following the same pattern as LCFridaKeychainInspector.
struct LCFridaMarketScript: Identifiable {
    let id: UUID
    let resourceName: String
    let nameKey: String
    let descriptionKey: String
    let symbol: String

    var name: String { nameKey.loc }
    var description: String { descriptionKey.loc }

    /// Install (idempotently) into the global script library.
    func install() throws -> LCFridaScriptStore.Script {
        let source = try LCFridaScriptCompatibility.resource(resourceName)
        return try LCFridaScriptStore.save(id: id, name: name, source: source, bridgeMode: .automatic)
    }

    /// True if this script is already installed in the library.
    var isInstalled: Bool {
        (try? LCFridaScriptStore.list())?.contains { $0.id == id } ?? false
    }

    /// True if this script is attached to the given app's selection.
    func isEnabled(for folder: URL) -> Bool {
        guard let selection = try? LCFridaScriptStore.selection(folder: folder) else { return false }
        return selection.scripts.contains(id)
    }
}

enum LCFridaScriptMarket {
    /// Fixed UUIDs keep installs idempotent across app restarts.
    static let scripts: [LCFridaMarketScript] = [
        LCFridaMarketScript(
            id: UUID(uuidString: "B11C0DE0-1A55-4C11-9E33-1A9C42E77A11")!,
            resourceName: "sslpinning-bypass.js",
            nameKey: "lc.market.sslpinning.name",
            descriptionKey: "lc.market.sslpinning.desc",
            symbol: "lock.open"
        ),
        LCFridaMarketScript(
            id: UUID(uuidString: "B22C0DE0-1A55-4C11-9E33-1A9C42E77A22")!,
            resourceName: "antidebug-bypass.js",
            nameKey: "lc.market.antidebug.name",
            descriptionKey: "lc.market.antidebug.desc",
            symbol: "ant"
        ),
        LCFridaMarketScript(
            id: UUID(uuidString: "A11C0DE0-1A55-4C11-9E33-1A9C42E77A11")!,
            resourceName: "keychain-inspector.js",
            nameKey: "lc.market.keychain.name",
            descriptionKey: "lc.market.keychain.desc",
            symbol: "key.horizontal"
        ),
        LCFridaMarketScript(
            id: UUID(uuidString: "B33C0DE0-1A55-4C11-9E33-1A9C42E77A33")!,
            resourceName: "phone-logger.js",
            nameKey: "lc.market.phonelogger.name",
            descriptionKey: "lc.market.phonelogger.desc",
            symbol: "doc.text"
        )
    ]

    @MainActor
    static func enable(_ script: LCFridaMarketScript, model: LCAppModel) throws {
        guard !model.isAppRunning else {
            throw "lc.market.error.appRunning".loc
        }
        guard let folder = LCFridaSetup.folder(for: model.appInfo),
              LCFridaSetup.enabled(model.appInfo) else {
            throw "lc.market.error.gadgetNotEnabled".loc
        }
        _ = try script.install()
        var selection = try LCFridaScriptStore.selection(folder: folder)
        guard selection.owner == model.appInfo.relativeBundlePath else {
            throw "lc.market.error.ownerMismatch".loc
        }
        if !selection.scripts.contains(script.id) {
            selection.scripts.append(script.id)
        }
        selection.automatic = true
        try LCFridaScriptStore.apply(selection, folder: folder)
        model.uiIsJITNeeded = selection.allowGenericHooks == true
        model.appInfo.save()
    }

    @MainActor
    static func disable(_ script: LCFridaMarketScript, model: LCAppModel) throws {
        guard !model.isAppRunning else {
            throw "lc.market.error.appRunning".loc
        }
        guard let folder = LCFridaSetup.folder(for: model.appInfo) else {
            return
        }
        var selection = try LCFridaScriptStore.selection(folder: folder)
        guard selection.owner == model.appInfo.relativeBundlePath else {
            return
        }
        selection.scripts.removeAll { $0 == script.id }
        // Removing the last script must also leave automatic mode; otherwise
        // apply() rejects an empty automatic selection.
        if selection.scripts.isEmpty { selection.automatic = false }
        try LCFridaScriptStore.apply(selection, folder: folder)
        model.appInfo.save()
    }
}