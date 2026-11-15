import SwiftUI

struct ContentSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("ui.settings.content.section.discovery") {
                Picker("ui.settings.content.album_region", selection: $settings.musicArea) {
                    Text("ui.region.all").tag("ALL")
                    Text("ui.region.china").tag("ZH")
                    Text("ui.region.europe_america").tag("EA")
                    Text("ui.region.korea").tag("KR")
                    Text("ui.region.japan").tag("JP")
                }

                Toggle("ui.settings.content.show_play_count", isOn: $settings.showPlayCount)
            }
        }
        .navigationTitle("ui.settings.content.title")
        .navigationBarTitleDisplayMode(.inline)
    }
}
