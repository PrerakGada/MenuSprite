import Foundation

enum BuildFeatures {
    #if MENUSPRITE_PUBLIC_PREVIEW
    static let publicPreview = true
    #else
    static let publicPreview = false
    #endif
    static let powerPageTitle = "Power Controls"
}
