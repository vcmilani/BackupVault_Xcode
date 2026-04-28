import Foundation
import SwiftUI

// Shorthand: L("key") or Text("key") via SwiftUI's built-in LocalizedStringKey support
// All Text("...") calls in SwiftUI automatically look up Localizable.strings
// This file just adds a helper for non-view contexts

func L(_ key: String, _ args: CVarArg...) -> String {
    let base = NSLocalizedString(key, comment: "")
    if args.isEmpty { return base }
    return String(format: base, arguments: args)
}
