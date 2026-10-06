import Foundation
import SwiftUI

enum L10n {
    // SwiftPM's accessor misses Contents/Resources in a packaged .app.
    static let bundle = Bundle.main.url(forResource: "Waypaper_Waypaper", withExtension: "bundle")
        .flatMap(Bundle.init(url:)) ?? Bundle.module

    static func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: string(key), locale: .current, arguments: args)
    }
}

extension Text {
    init(l10n key: String) {
        self.init(LocalizedStringKey(stringLiteral: key), bundle: L10n.bundle)
    }
}
