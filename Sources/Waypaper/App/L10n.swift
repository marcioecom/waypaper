import Foundation
import SwiftUI

enum L10n {
    static func string(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: string(key), locale: .current, arguments: args)
    }
}

extension Text {
    init(l10n key: String) {
        self.init(LocalizedStringKey(stringLiteral: key), bundle: .module)
    }
}
