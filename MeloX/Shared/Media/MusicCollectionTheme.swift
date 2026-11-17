import SwiftUI

extension ArtworkDetailPalette {
    /// Artwork colors tint the background without overriding the app's appearance.
    func backgroundColor(for colorScheme: ColorScheme, nearArtwork: Bool = false) -> Color {
        let isDark = colorScheme == .dark
        // Move toward white/black along the source hue, instead of tinting a
        // fixed neutral with a separately brightened accent. Keep some source
        // luminance variation for black-and-white covers as well.
        let luminance = sourceRGB.x * 0.2126 + sourceRGB.y * 0.7152 + sourceRGB.z * 0.0722
        // The upper wash carries the cover identity; the lower surface settles
        // toward a quieter reading background without losing its hue.
        let target: Double
        if isDark {
            target = nearArtwork ? 0.15 + luminance * 0.09 : 0.07 + luminance * 0.07
        } else {
            target = nearArtwork ? 0.72 + luminance * 0.08 : 0.84 + luminance * 0.08
        }
        let background: SIMD3<Double>
        if luminance < target {
            let whiteMix = (target - luminance) / max(1 - luminance, 0.001)
            background = sourceRGB * (1 - whiteMix) + SIMD3<Double>(repeating: whiteMix)
        } else {
            background = sourceRGB * (target / max(luminance, 0.001))
        }

        return Color(
            red: background.x,
            green: background.y,
            blue: background.z
        )
    }
}

/// Smooth alpha interpolation avoids visible slope changes in long artwork fades.
/// Only opacity is masked: the destination is always the actual background below.
struct MusicCollectionArtworkFade: View {
    var start: Double = 0

    var body: some View {
        LinearGradient(
            stops: (start > 0 ? [Gradient.Stop(color: .black, location: 0)] : []) + (0...32).map { index in
                let progress = Double(index) / 32
                let opacity = 1 - progress * progress * (3 - 2 * progress)
                return Gradient.Stop(
                    color: .black.opacity(opacity),
                    location: CGFloat(start + (1 - start) * progress)
                )
            },
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

func filterMusicCollectionTracks(_ tracks: [Song], query: String) -> [Song] {
    let keywords = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !keywords.isEmpty else { return tracks }
    return tracks.filter { song in
        song.name.localizedCaseInsensitiveContains(keywords)
            || song.artistText.localizedCaseInsensitiveContains(keywords)
            || (song.album?.name.localizedCaseInsensitiveContains(keywords) ?? false)
    }
}
