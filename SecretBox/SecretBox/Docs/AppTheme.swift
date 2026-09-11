import SwiftUI

struct AppTheme {
    // Brand color from asset catalog with fallback to accentColor
    private static let assetBrand = Color("BrandColor", bundle: .main)
    static var brand: Color {
        resolvedBrand
    }
    
    private static var resolvedBrand: Color {
        // Attempt to resolve assetBrand by checking if it is not the default fallback
        // Since Color("BrandColor") always returns a Color, we try a workaround:
        // We'll attempt to create an NSColor using the asset name and return fallback if fails
        #if os(macOS)
        if let _ = NSColor(named: NSColor.Name("BrandColor"), bundle: Bundle.main) {
            return assetBrand
        } else {
            return Color.accentColor
        }
        #else
        // On iOS/tvOS/watchOS fallback to accentColor if asset is missing is not straightforward,
        // so just return assetBrand; if asset is missing it falls back to clear color 
        return assetBrand
        #endif
    }
    
    static func pageBackground(_ scheme: ColorScheme) -> Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    static func underPageBackground(_ scheme: ColorScheme) -> Color {
        #if os(macOS)
        Color(nsColor: .underPageBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    static func controlBackground(_ scheme: ColorScheme) -> Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }

    static func cardBackground(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color.white.opacity(0.9)
        case .dark:
            return Color.black.opacity(0.2)
        @unknown default:
            return Color.white.opacity(0.9)
        }
    }
    
    static func surfaceBackground(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            #if os(macOS)
            return Color(nsColor: .windowBackgroundColor)
            #else
            return Color(uiColor: .systemBackground)
            #endif
        case .dark:
            #if os(macOS)
            return Color(nsColor: .underPageBackgroundColor)
            #else
            return Color(uiColor: .secondarySystemBackground)
            #endif
        @unknown default:
            #if os(macOS)
            return Color(nsColor: .windowBackgroundColor)
            #else
            return Color(uiColor: .systemBackground)
            #endif
        }
    }
    
    static func border(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .light:
            return Color.black.opacity(0.12)
        case .dark:
            return Color.white.opacity(0.12)
        @unknown default:
            return Color.black.opacity(0.12)
        }
    }
}
