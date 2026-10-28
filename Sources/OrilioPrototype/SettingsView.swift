import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKeys.openOnHover) private var openOnHover = true
    @AppStorage(SettingsKeys.preferNotchedDisplay) private var preferNotchedDisplay = false
    @AppStorage(SettingsKeys.showDemoSource) private var showDemoSource = false

    var body: some View {
        Form {
            Toggle("Open the island on hover", isOn: $openOnHover)
            Toggle("Show on the built-in notched display when connected", isOn: $preferNotchedDisplay)
            Toggle("Show the Demo media source", isOn: $showDemoSource)
            Text("Spotify and Music are read through their public notifications and controlled with Apple Events after you allow it. The Demo source is fake. No analytics; the only network use is loading Spotify cover art from Spotify.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }
}
