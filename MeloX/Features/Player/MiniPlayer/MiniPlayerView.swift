import SwiftUI

struct MiniPlayerView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(PlayerStore.self) private var player

    let artworkTransitionID: String
    let artworkTransitionNamespace: Namespace.ID
    let onExpand: () -> Void

    private static let swipeActivationDistance: CGFloat = 6

    @GestureState(resetTransaction: Transaction(animation: .easeOut(duration: 0.18)))
    private var dragTranslation: CGFloat = 0
    @State private var trackWidth: CGFloat = 0
    @State private var swipeDirection = 1
    @State private var committedCards: [TrackCard]?
    @State private var committedTranslation: CGFloat = 0
    @State private var pendingSwipeDirection: Int?

    var body: some View {
        if let song = player.currentSong {
            HStack(spacing: isInline ? 8 : 10) {
                trackButton(song: song)

                if player.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 36, height: 36)
                } else {
                    Button {
                        player.togglePlayback()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3.weight(.semibold))
                            .contentTransition(
                                accessibilityReduceMotion
                                    ? .identity
                                    : .symbolEffect(
                                        .replace.downUp.wholeSymbol,
                                        options: .speed(1.6)
                                    )
                            )
                            .animation(
                                accessibilityReduceMotion
                                    ? nil
                                    : .snappy(duration: 0.2, extraBounce: 0),
                                value: player.isPlaying
                            )
                            .frame(width: 36, height: 36)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        player.isPlaying
                            ? L10n.string("ui.player.pause")
                            : L10n.string("ui.common.play")
                    )
                }

                if !isInline {
                    Button {
                        Task { await player.next() }
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title3.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("ui.player.next")
                }
            }
            .padding(.horizontal, isInline ? 8 : 12)
            .padding(.vertical, isInline ? 3 : 6)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            // Prioritize horizontal swipes over the expand button's tap.
            .highPriorityGesture(trackSwipeGesture)
            .onChange(of: committedCards != nil) { _, isSettling in
                guard !isSettling, let direction = pendingSwipeDirection else { return }
                pendingSwipeDirection = nil
                commitSwipe(by: direction, translation: 0)
            }
            .accessibilityAction(named: L10n.string("ui.player.previous")) {
                Task { await player.previous() }
            }
            .accessibilityAction(named: L10n.string("ui.player.next")) {
                Task { await player.next() }
            }
        }
    }

    private var isInline: Bool {
        placement == .inline
    }

    private var artworkSize: CGFloat {
        isInline ? 30 : 40
    }

    private func trackButton(song: Song) -> some View {
        let translation = committedCards == nil ? dragTranslation : committedTranslation
        let cards = committedCards ?? trackCards(song: song)

        return Button {
            guard committedCards == nil else { return }
            onExpand()
        } label: {
            ZStack {
                ForEach(cards) { card in
                    trackContent(card)
                        .offset(x: CGFloat(card.slot) * trackWidth + translation)
                        .opacity(card.slot == 0 || trackWidth > 0 ? 1 : 0)
                }
            }
            .clipped()
            .contentShape(.rect)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                trackWidth = width
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: song.name))
        .accessibilityValue(Text(verbatim: song.artistText))
    }

    private func trackContent(_ card: TrackCard) -> some View {
        HStack(spacing: isInline ? 8 : 10) {
            ArtworkImage(url: card.song.album?.artworkURL, cornerRadius: 6)
                .frame(width: artworkSize, height: artworkSize)
                .matchedTransitionSource(
                    id: card.slot == 0 ? artworkTransitionID : "\(artworkTransitionID)-preview-\(card.id)",
                    in: artworkTransitionNamespace
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(card.song.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                if !isInline {
                    Text(card.song.artistText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityHidden(true)
    }

    private func trackCards(song: Song) -> [TrackCard] {
        let current = TrackCard(id: player.currentIndex, song: song, slot: 0)
        let previous = previewCard(by: -1)
        let next = previewCard(by: 1)
        if let previous, let next, previous.id == next.id {
            // Keep the shared neighbor on the same side while a canceled swipe settles.
            return [current, swipeDirection < 0 ? previous : next]
        }
        return [current] + [previous, next].compactMap { $0 }
    }

    private func previewCard(by direction: Int) -> TrackCard? {
        guard let index = player.adjacentQueueIndex(by: direction),
              index != player.currentIndex else { return nil }
        return TrackCard(id: index, song: player.queue[index], slot: direction)
    }

    private var trackSwipeGesture: some Gesture {
        DragGesture(minimumDistance: Self.swipeActivationDistance)
            .updating($dragTranslation) { value, translation, transaction in
                transaction.animation = nil
                guard !accessibilityReduceMotion, committedCards == nil,
                      abs(value.translation.width) > abs(value.translation.height) else {
                    translation = 0
                    return
                }
                translation = displayedTranslation(value.translation.width)
            }
            .onChanged { value in
                guard !accessibilityReduceMotion, committedCards == nil,
                      abs(value.translation.width) > abs(value.translation.height) else { return }
                let direction = value.translation.width < 0 ? 1 : -1
                if swipeDirection != direction { swipeDirection = direction }
            }
            .onEnded { value in
                let horizontalDistance = value.translation.width
                guard abs(horizontalDistance) > abs(value.translation.height) else {
                    return
                }
                let distanceThreshold = min(max(trackWidth * 0.27, 35), 88)
                let projectedDistance = value.predictedEndTranslation.width
                let isFlick = abs(horizontalDistance) >= 18
                    && horizontalDistance.sign == projectedDistance.sign
                    && abs(projectedDistance) >= max(trackWidth * 0.6, 65)
                guard abs(horizontalDistance) >= distanceThreshold || isFlick else { return }
                let direction = horizontalDistance < 0 ? 1 : -1
                if committedCards != nil {
                    pendingSwipeDirection = direction
                } else {
                    commitSwipe(by: direction, translation: horizontalDistance)
                }
            }
    }

    private func displayedTranslation(_ distance: CGFloat) -> CGFloat {
        // The recognition distance is already traveled when the first drag update arrives.
        let movement = max(abs(distance) - Self.swipeActivationDistance, 0)
        let translation = distance < 0 ? -movement : movement
        let direction = distance < 0 ? 1 : -1
        if previewCard(by: direction) == nil {
            return min(max(translation * 0.18, -24), 24)
        }
        return min(max(translation, -trackWidth), trackWidth)
    }

    private func commitSwipe(by direction: Int, translation: CGFloat) {
        guard let song = player.currentSong else { return }
        let sourceIndex = player.currentIndex

        if !accessibilityReduceMotion, trackWidth > 0,
           let incoming = previewCard(by: direction) {
            let start = displayedTranslation(translation)
            let destination = -CGFloat(incoming.slot) * trackWidth
            let remainingFraction = abs(destination - start) / trackWidth
            let duration = 0.10 + 0.18 * Double(remainingFraction)
            // Keep both cards in place while playback publishes the new song.
            withTransaction(Transaction(animation: nil)) {
                swipeDirection = direction
                committedCards = trackCards(song: song)
                committedTranslation = start
            }
            withAnimation(.easeOut(duration: duration), completionCriteria: .removed) {
                committedTranslation = destination
            } completion: {
                withTransaction(Transaction(animation: nil)) {
                    committedCards = nil
                    committedTranslation = 0
                }
            }
        }

        Task {
            guard player.currentIndex == sourceIndex,
                  player.currentSong?.id == song.id else { return }
            if direction > 0 {
                await player.next()
            } else {
                await player.previous()
            }
        }
    }

    private struct TrackCard: Identifiable {
        let id: Int
        let song: Song
        let slot: Int
    }
}
