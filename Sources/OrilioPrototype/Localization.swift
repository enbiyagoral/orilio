// SPDX-License-Identifier: GPL-3.0-or-later
// Orilio — a calm control surface for the Mac notch.
// Copyright (C) 2026 Enbiya Goral and Orilio contributors

import Foundation

/// A string that arrives as a `String` (a component's title, a menu item), looked up in
/// Localizable.strings like SwiftUI does for literals. Anything not in the table is shown as is.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}
