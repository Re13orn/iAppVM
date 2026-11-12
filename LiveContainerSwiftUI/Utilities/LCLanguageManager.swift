//
//  LCLanguageManager.swift
//  LiveContainerSwiftUI
//
//  In-app language override. When set, String.loc resolves through the
//  matching lproj bundle instead of the system-preferred localization.
//

import Foundation

enum LCLanguageOverride: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "lc.settings.language.system".loc
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    static var stored: LCLanguageOverride {
        get { LCLanguageOverride(rawValue: UserDefaults.standard.string(forKey: "LCLanguageOverride") ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "LCLanguageOverride") }
    }
}

enum LCLanguage {
    private static let lock = NSLock()
    private static var cachedBundle: Bundle?
    private static var cachedLanguage: String = "§"

    /// The lproj bundle for the active override, or nil to follow the system.
    static var bundle: Bundle? {
        let raw = LCLanguageOverride.stored.rawValue
        lock.lock()
        defer { lock.unlock() }
        guard !raw.isEmpty else {
            // "Follow system" must drop the previous override bundle, otherwise
            // the UI stays stuck in the overridden language.
            cachedLanguage = raw
            cachedBundle = nil
            return nil
        }
        guard raw != cachedLanguage else { return cachedBundle }
        cachedLanguage = raw
        cachedBundle = Bundle.main.path(forResource: raw, ofType: "lproj").flatMap(Bundle.init(path:))
        return cachedBundle
    }
}