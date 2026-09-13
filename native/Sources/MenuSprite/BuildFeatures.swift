import Foundation

enum BuildFeatures {
    #if MENUSPRITE_PUBLIC_PREVIEW
    static let publicPreview = true
    static let privilegedPowerControls = false
    #else
    static let publicPreview = false
    static let privilegedPowerControls = true
    #endif
    static var powerPageTitle: String { publicPreview ? "Keep Awake" : "Power Controls" }
}
