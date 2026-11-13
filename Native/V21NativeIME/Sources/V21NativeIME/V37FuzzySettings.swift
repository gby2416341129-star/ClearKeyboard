import Foundation

/// Stable existing ABI bits. UI order/string sorting must never renumber these.
public enum V37FuzzyGroup: UInt32, CaseIterable, Sendable {
    case zZh = 1, cCh = 2, sSh = 4, nL = 8, fH = 16
    case anAng = 32, enEng = 64, inIng = 128
    public var uiKey: String {
        switch self {
        case .zZh: return "z/zh"
        case .cCh: return "c/ch"
        case .sSh: return "s/sh"
        case .nL: return "n/l"
        case .fH: return "f/h"
        case .anAng: return "an/ang"
        case .enEng: return "en/eng"
        case .inIng: return "in/ing"
        }
    }
}
public enum V37FuzzySettingsError: Error {
    case unknownUIKey(String)
    case unknownMask(UInt32)
}
public enum V37FuzzySettings {
    public static func mask(enabledUIKeys: Set<String>) throws -> UInt32 {
        var value: UInt32 = 0
        for key in enabledUIKeys {
            guard let group = V37FuzzyGroup.allCases.first(where: { $0.uiKey == key }) else {
                throw V37FuzzySettingsError.unknownUIKey(key)
            }
            value |= group.rawValue
        }
        return value
    }
    /// Updates only fuzzy settings, preserving the App's independent typo/initials choices.
    public static func applying(mask: UInt32, to existing: V23InputSettings) throws -> V23InputSettings {
        guard mask <= 255 else { throw V37FuzzySettingsError.unknownMask(mask) }
        var settings = existing
        settings.fuzzyGroups = mask
        return settings
    }
    /// Optional manual specialist comparison. Kernel configuration must also set allowIncompleteTail=false.
    public static func isolated(mask: UInt32) throws -> V23InputSettings {
        var settings = try applying(mask: mask, to: V23InputSettings())
        settings.allowInitials = false
        settings.allowTypos = false
        settings.maximumEdits = 0 // Native fuzzy edges consume zero ordinary edits.
        return settings
    }
}
