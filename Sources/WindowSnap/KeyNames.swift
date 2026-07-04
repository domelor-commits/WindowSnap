import Carbon.HIToolbox

/// Maps Carbon virtual key codes to short display strings for the UI.
enum KeyNames {
    static func string(for code: UInt32) -> String {
        switch Int(code) {
        case kVK_LeftArrow:   return "←"
        case kVK_RightArrow:  return "→"
        case kVK_UpArrow:     return "↑"
        case kVK_DownArrow:   return "↓"
        case kVK_Return:      return "↩"
        case kVK_ANSI_KeypadEnter: return "⌅"
        case kVK_Space:       return "Space"
        case kVK_Escape:      return "⎋"
        case kVK_Delete:      return "⌫"
        case kVK_Tab:         return "⇥"
        case kVK_F13: return "F13"; case kVK_F14: return "F14"; case kVK_F15: return "F15"
        case kVK_F16: return "F16"; case kVK_F17: return "F17"; case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"
        case kVK_F4: return "F4"; case kVK_F5: return "F5"; case kVK_F6: return "F6"
        case kVK_F7: return "F7"; case kVK_F8: return "F8"; case kVK_F9: return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        case kVK_ANSI_A: return "A"; case kVK_ANSI_B: return "B"; case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"; case kVK_ANSI_E: return "E"; case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"; case kVK_ANSI_H: return "H"; case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"; case kVK_ANSI_K: return "K"; case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"; case kVK_ANSI_N: return "N"; case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"; case kVK_ANSI_Q: return "Q"; case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"; case kVK_ANSI_T: return "T"; case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"; case kVK_ANSI_W: return "W"; case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"; case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"; case kVK_ANSI_1: return "1"; case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"; case kVK_ANSI_4: return "4"; case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"; case kVK_ANSI_7: return "7"; case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        default: return "?"
        }
    }

    /// Friendly label for a SnapRegion in the shortcuts table.
    static func regionLabel(_ raw: String) -> String {
        switch raw {
        case "leftHalf": return "Left Half"
        case "rightHalf": return "Right Half"
        case "topHalf": return "Top Half"
        case "bottomHalf": return "Bottom Half"
        case "topLeft": return "Top Left"
        case "topRight": return "Top Right"
        case "bottomLeft": return "Bottom Left"
        case "bottomRight": return "Bottom Right"
        case "leftThird": return "Left Third"
        case "centerThird": return "Center Third"
        case "rightThird": return "Right Third"
        case "maximize": return "Maximize"
        case "center": return "Center"
        case "overwriteLayout": return "Overwrite Selected Layout"
        case "restoreLayout": return "Restore Selected Layout"
        case "restoreDefault": return "Restore Default Layout"
        case "restorePresentation": return "Restore Presentation Layout"
        case "overwriteDefault": return "Overwrite Default Layout"
        case "overwritePresentation": return "Overwrite Presentation Layout"
        default:
            // Prefixed, per-item keys used by launchers and saved layouts.
            if raw.hasPrefix("launcher:") {
                return "Launcher (\(raw.dropFirst("launcher:".count)))"
            }
            if raw.hasPrefix("restoreLayout:") { return "a saved layout's Restore shortcut" }
            if raw.hasPrefix("overwriteLayout:") { return "a saved layout's Overwrite shortcut" }
            return raw
        }
    }

    /// Display order for the shortcuts table.
    static let order: [String] = [
        "leftHalf", "rightHalf", "topHalf", "bottomHalf",
        "topLeft", "topRight", "bottomLeft", "bottomRight",
        "leftThird", "centerThird", "rightThird",
        "maximize", "center", "overwriteLayout"
    ]
}
