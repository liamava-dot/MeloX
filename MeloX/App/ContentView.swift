import SwiftUI
import UIKit

private enum ContentSheet: String, Identifiable {
    case settings

    var id: String { rawValue }
}

private struct HeartModeLaunchReadiness: Equatable {
    let hasRestoredPlayback: Bool
    let isLoggedIn: Bool
    let canStartHeartMode: Bool
}

struct ContentView: View {
    @Environment(\.colorScheme) private var appColorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(PlayerStore.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadStore.self) private var downloads
    @Environment(LyricsStore.self) private var lyrics

    @State private var selectedTab: AppTab
    @State private var navigationPaths = Dictionary(
        uniqueKeysWithValues: AppTab.allCases.map {
            ($0, NavigationPath())
        }
    )
    @State private var presentedSheet: ContentSheet?
    @State private var playerPresentation: PlayerPresentation?
    @State private var playerNavigationPath: [MusicRoute] = []
    @State private var neteaseSharePresentation: NeteaseSharePresentation?
    @State private var nowPlayingSharePresentation: NeteaseSharePresentation?
    @State private var isTabViewBottomAccessorySuppressed = false
    @State private var hasRestoredPlayback = false
    @State private var hasHandledHeartModeLaunch = false
    @State private var heartModeLaunchErrorMessage: String?
    @Namespace private var playerTransitionNamespace
    @Namespace private var musicNavigationNamespace

    private let playerTransitionID = "now-playing"

    init(initialTab: AppTab = .home) {
        _selectedTab = State(initialValue: initialTab)
        #if DEBUG && targetEnvironment(simulator)
        if MeloXDesignPreview.isEnabled,
           let pageName = ProcessInfo.processInfo.environment["MELOX_UI_PAGE"],
           let page = NowPlayingPage(rawValue: pageName) {
            _playerPresentation = State(initialValue: .nowPlaying(initialPage: page))
        }
        #endif
    }

    var body: some View {
        Group {
            if settings.hasCompletedOnboarding {
                mainExperience
            } else {
                OnboardingView()
            }
        }
    }

    private var mainExperience: some View {
        playerAwareTabView
            .environment(
                \.openMusicRoute,
                OpenMusicRouteAction(action: openMusicRoute)
            )
            .environment(
                \.openNeteaseShare,
                OpenNeteaseShareAction(action: openNeteaseShare)
            )
            .environment(
                \.setTabViewBottomAccessorySuppressed,
                SetTabViewBottomAccessorySuppressedAction {
                    isTabViewBottomAccessorySuppressed = $0
                }
            )
            .fullScreenCover(
                item: $playerPresentation,
                onDismiss: { playerNavigationPath.removeAll() }
            ) { destination in
                switch destination {
                case .nowPlaying(let initialPage):
                    playerNavigationStack(initialPage: initialPage)
                }
            }
            .sheet(item: $neteaseSharePresentation) { presentation in
                NeteaseShareSheet(presentation: presentation)
            }
            .sheet(item: $presentedSheet) { destination in
                switch destination {
                case .settings:
                    NavigationStack {
                        SettingsView()
                            .musicDestinations(
                                in: musicNavigationNamespace
                            )
                    }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .presentationCornerRadius(32)
                }
            }
            .task {
                await player.restore()
                guard !Task.isCancelled else { return }
                hasRestoredPlayback = true
            }
            .task(
                id: HeartModeLaunchReadiness(
                    hasRestoredPlayback: hasRestoredPlayback,
                    isLoggedIn: library.isLoggedIn,
                    canStartHeartMode: library.canStartHeartMode
                )
            ) {
                await startHeartModeOnLaunchIfNeeded()
            }
            .task(id: player.currentSong?.id) {
                await synchronizeLyrics()
            }
            .onChange(of: settings.lyricsSourcePreference) { _, _ in
                Task { await synchronizeLyrics() }
            }
            .task(id: settings.cookie) {
                await library.refresh()
            }
            .onAppear {
                guard usesTabletNavigation,
                      settings.restoresLastSelectedTab,
                      navigationTabs.contains(settings.lastSelectedTab) else { return }
                selectedTab = settings.lastSelectedTab
            }
            .onChange(of: selectedTab) { _, tab in
                settings.lastSelectedTab = tab
            }
            .onChange(of: navigationTabs) { _, tabs in
                guard !tabs.contains(selectedTab) else { return }
                if settings.homeTabs.contains(selectedTab),
                   tabs.contains(.home) {
                    selectedTab = .home
                } else if selectedTab.libraryPage != nil,
                   tabs.contains(.library) {
                    if let page = selectedTab.libraryPage {
                        settings.lastLibraryPage = page
                    }
                    selectedTab = .library
                } else {
                    selectedTab = settings.fallbackNavigationTab
                }
            }
            .onChange(of: scenePhase) { _, phase in
                player.refreshLyricsNotification()
                guard phase == .active else { return }
                player.refreshLyricsLiveActivity()
            }
            .alert(
                "ui.error.playback.title",
                isPresented: Binding(
                    get: { player.playbackIssue != nil },
                    set: { isPresented in
                        if !isPresented {
                            player.dismissPlaybackIssue()
                        }
                    }
                )
            ) {
                if player.canPlayNext {
                    Button("ui.player.play_next") {
                        player.dismissPlaybackIssue()
                        Task { await player.next() }
                    }
                }
                Button("ui.common.ok", role: .cancel) {
                    player.dismissPlaybackIssue()
                }
            } message: {
                Text(player.playbackIssue?.message ?? L10n.string("ui.error.playback.current_unavailable"))
            }
            .alert(
                "ui.error.heart_mode_launch.title",
                isPresented: Binding(
                    get: { heartModeLaunchErrorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            heartModeLaunchErrorMessage = nil
                        }
                    }
                )
            ) {
                Button("ui.common.ok", role: .cancel) {
                    heartModeLaunchErrorMessage = nil
                }
            } message: {
                Text(heartModeLaunchErrorMessage ?? L10n.string("ui.error.try_again_later"))
            }
            .alert(
                "ui.error.download.title",
                isPresented: Binding(
                    get: {
                        AppFeatureAvailability.downloads
                            && downloads.errorMessage != nil
                    },
                    set: { isPresented in
                        if !isPresented {
                            downloads.clearError()
                        }
                    }
                )
            ) {
                Button("ui.common.ok", role: .cancel) {
                    downloads.clearError()
                }
            } message: {
                Text(downloads.errorMessage ?? L10n.string("ui.error.download.operation_failed"))
            }
            .coordinateListenTogether()
            .recognizesClipboardLinksOnLaunch { song in
                openMusicRoute(.song(song))
            }
            .appLaunchExperience()
    }

    private func synchronizeLyrics() async {
        let song = player.currentSong
        let lyricSong = song?.isPodcastProgram == true ? nil : song
        await lyrics.load(for: lyricSong)
        guard !Task.isCancelled else { return }
        player.setNowPlayingLyrics(lyrics.lyrics, for: lyricSong?.id)
    }

    private func startHeartModeOnLaunchIfNeeded() async {
        guard !hasHandledHeartModeLaunch,
              hasRestoredPlayback else {
            return
        }
        guard settings.startsHeartModeOnLaunch else {
            hasHandledHeartModeLaunch = true
            return
        }
        guard library.isLoggedIn else {
            hasHandledHeartModeLaunch = true
            return
        }
        guard library.canStartHeartMode,
              let playlistID = library.likedPlaylistID,
              let seedSongID = library.randomHeartModeSeedSongID() else {
            return
        }

        hasHandledHeartModeLaunch = true
        do {
            try await player.playHeartMode(
                playlistID: playlistID,
                seedSongID: seedSongID
            )
        } catch is CancellationError {
            return
        } catch {
            heartModeLaunchErrorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private var playerAwareTabView: some View {
        if player.currentSong != nil {
            if #available(iOS 26.1, *) {
                tabs
                    .tabViewBottomAccessory(
                        isEnabled: !isTabViewBottomAccessorySuppressed
                    ) {
                        miniPlayer
                    }
            } else {
                tabs
                    .tabViewBottomAccessory {
                        if !isTabViewBottomAccessorySuppressed {
                            miniPlayer
                        }
                    }
            }
        } else {
            tabs
        }
    }

    @ViewBuilder
    private var miniPlayer: some View {
        if usesTabletNavigation {
            TabletMiniPlayerView(
                artworkTransitionID: playerTransitionID,
                artworkTransitionNamespace: playerTransitionNamespace,
                onExpand: presentPlayer
            )
        } else {
            MiniPlayerView(
                artworkTransitionID: playerTransitionID,
                artworkTransitionNamespace: playerTransitionNamespace
            ) {
                presentPlayer()
            }
        }
    }

    private var usesTabletNavigation: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
            && horizontalSizeClass == .regular
    }

    private var sidebarHomeTabs: [AppTab] {
        settings.homeTabs.filter {
            $0 != .music && $0 != .recommended && $0.libraryPage == nil
                && !settings.visibleTabs.contains($0)
        }
    }

    private var sidebarLibraryTabs: [AppTab] {
        let embedded = settings.embeddedLibraryPages.map { AppTab(libraryPage: $0) }
        let homeLibraryPages = settings.homeTabs.filter { $0.libraryPage != nil }
        var seen = Set(settings.visibleTabs)
        return (embedded + homeLibraryPages).filter { seen.insert($0).inserted }
    }

    private var navigationTabs: [AppTab] {
        settings.visibleTabs.filter { $0 != .music }
            + (usesTabletNavigation ? sidebarHomeTabs + sidebarLibraryTabs : [])
    }

    private var displayedPrimaryTabs: [AppTab] {
        let visibleTabs = settings.visibleTabs.filter { $0 != .music }
        guard usesTabletNavigation, visibleTabs.contains(.search) else { return visibleTabs }
        return [.search] + visibleTabs.filter { $0 != .search }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            ForEach(displayedPrimaryTabs) { tab in
                Tab(
                    tab.title,
                    systemImage: tab.systemImage,
                    value: tab,
                    role: tab == .search ? .search : nil
                ) {
                    tabNavigationStack(for: tab)
                }
            }

            if usesTabletNavigation {
                if !sidebarHomeTabs.isEmpty {
                    TabSection("ui.navigation.explore") {
                        ForEach(sidebarHomeTabs) { tab in
                            Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                                tabNavigationStack(for: tab)
                            }
                        }
                    }
                    .tabPlacement(.sidebarOnly)
                }

                if !sidebarLibraryTabs.isEmpty {
                    TabSection("ui.navigation.library") {
                        ForEach(sidebarLibraryTabs) { tab in
                            Tab(
                                tab.libraryPage?.title ?? tab.title,
                                systemImage: tab.systemImage,
                                value: tab
                            ) {
                                tabNavigationStack(for: tab)
                            }
                        }
                    }
                    .tabPlacement(.sidebarOnly)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .defaultAdaptableTabBarPlacement(usesTabletNavigation ? .sidebar : .automatic)
        .tabViewSidebarBottomBar {
            SidebarAccountButton(accessibilityLabel: accountToolbarAccessibilityLabel) {
                presentedSheet = .settings
            } label: {
                HStack(spacing: 10) {
                    accountToolbarLabel
                        .frame(width: 28, height: 28)
                    Text(library.profile?.nickname ?? L10n.string("ui.account.login_settings"))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 16)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .tabBarMinimizeBehavior(usesTabletNavigation ? .never : .onScrollDown)
        .environment(\.musicUsesSidebar, usesTabletNavigation)
        .environment(\.musicNavigationNamespace, musicNavigationNamespace)
    }

    private func tabNavigationStack(for tab: AppTab) -> some View {
        NavigationStack(path: navigationPathBinding(for: tab)) {
            tabRoot(for: tab)
                .toolbar {
                    primaryToolbar(for: tab)
                }
                .musicDestinations(in: musicNavigationNamespace)
        }
    }

    private func playerNavigationStack(initialPage: NowPlayingPage) -> some View {
        NavigationStack(path: $playerNavigationPath) {
            NowPlayingView(initialPage: initialPage) {
                playerPresentation = nil
            }
            .environment(\.colorScheme, .dark)
            .toolbarVisibility(.hidden, for: .navigationBar)
            .musicDestinations()
        }
        .environment(
            \.openMusicRoute,
            OpenMusicRouteAction(action: openMusicRoute)
        )
        .environment(
            \.openNeteaseShare,
            OpenNeteaseShareAction { presentation in
                presentNeteaseShare(presentation, fromNowPlaying: true)
            }
        )
        .environment(
            \.setTabViewBottomAccessorySuppressed,
            SetTabViewBottomAccessorySuppressedAction()
        )
        .sheet(item: $nowPlayingSharePresentation) { presentation in
            NeteaseShareSheet(presentation: presentation)
        }
        .preferredColorScheme(appColorScheme)
        .interactiveDismissDisabled(!playerNavigationPath.isEmpty)
        .presentationBackground(.clear)
        .presentationContentInteraction(.resizes)
        .navigationTransition(
            .zoom(sourceID: playerTransitionID, in: playerTransitionNamespace)
        )
    }

    private func presentPlayer(page: NowPlayingPage? = nil) {
        if let page, settings.rememberNowPlayingPage {
            settings.rememberedNowPlayingPage = page.rawValue
        }
        playerPresentation = .nowPlaying(initialPage: page ?? initialNowPlayingPage)
    }

    @ViewBuilder
    private func tabRoot(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            HomeView()
        case .recommended:
            HomeRecommendedView()
                .navigationTitle("ui.navigation.recommended")
                .navigationBarTitleDisplayMode(.large)
        case .music:
            ExploreView(navigationTitle: L10n.string("ui.navigation.music"))
        case .podcasts:
            PodcastHomeView()
        case .explore:
            ExploreView()
        case .library:
            LibraryView()
        case .search:
            SearchView()
        case .librarySongs,
             .libraryPlaylists,
             .libraryAlbums,
             .libraryArtists,
             .libraryPodcasts,
             .libraryDownloads,
             .libraryCloud,
             .libraryHistory:
            if let page = tab.libraryPage {
                LibraryView(fixedPage: page)
            }
        }
    }

    @ToolbarContentBuilder
    private func primaryToolbar(
        for tab: AppTab
    ) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !usesTabletNavigation {
                Button {
                    presentedSheet = .settings
                } label: {
                    accountToolbarLabel
                }
                .accessibilityLabel(accountToolbarAccessibilityLabel)
            }
        }
    }

    @ViewBuilder
    private var accountToolbarLabel: some View {
        if let profile = library.profile {
            AsyncImage(url: profile.artworkURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .background(.quaternary, in: .circle)
            .clipShape(.circle)
        } else {
            MusicToolbarSymbol(
                systemName: library.isLoggedIn
                    ? "person.crop.circle.fill"
                    : "person.crop.circle"
            )
        }
    }

    private var accountToolbarAccessibilityLabel: String {
        if let profile = library.profile {
            return L10n.format("ui.account.settings_for_user", profile.nickname)
        }
        return library.isLoggedIn
            ? L10n.string("ui.account.settings")
            : L10n.string("ui.account.login_settings")
    }

    private func navigationPathBinding(
        for tab: AppTab
    ) -> Binding<NavigationPath> {
        Binding(
            get: {
                navigationPaths[tab] ?? NavigationPath()
            },
            set: {
                navigationPaths[tab] = $0
            }
        )
    }

    private var initialNowPlayingPage: NowPlayingPage {
        guard settings.rememberNowPlayingPage else { return .artwork }
        return NowPlayingPage(rawValue: settings.rememberedNowPlayingPage) ?? .artwork
    }

    private func openMusicRoute(_ route: MusicRoute) {
        if playerPresentation != nil {
            playerNavigationPath.append(route)
            return
        }
        var path = navigationPaths[selectedTab] ?? NavigationPath()
        path.append(route)
        navigationPaths[selectedTab] = path
    }

    private func openNeteaseShare(
        _ presentation: NeteaseSharePresentation
    ) {
        presentNeteaseShare(presentation, fromNowPlaying: false)
    }

    private func presentNeteaseShare(
        _ presentation: NeteaseSharePresentation,
        fromNowPlaying: Bool
    ) {
        Task { @MainActor in
            // Menu actions can fire before the system has completed
            // dismissing the menu. Present on the next settled UI turn.
            try? await Task.sleep(for: .milliseconds(140))
            if fromNowPlaying {
                nowPlayingSharePresentation = presentation
            } else {
                neteaseSharePresentation = presentation
            }
        }
    }
}
