import Observation
import SwiftUI

private let sceneCardFill = Color(red: 0.96, green: 0.95, blue: 0.91)
private let sceneCardTint = Color(red: 0.90, green: 0.93, blue: 0.89)
private let sceneCardStroke = Color.white.opacity(0.52)
private let sceneInk = Color(red: 0.16, green: 0.22, blue: 0.20)
private let sceneMutedInk = Color(red: 0.33, green: 0.40, blue: 0.37)
private let sceneSoftInk = Color(red: 0.47, green: 0.54, blue: 0.51)
private let sceneForest = Color(red: 0.18, green: 0.46, blue: 0.40)
private let sceneForestDeep = Color(red: 0.10, green: 0.24, blue: 0.22)
private let sceneSun = Color(red: 0.95, green: 0.78, blue: 0.33)
private let sceneRose = Color(red: 0.78, green: 0.47, blue: 0.43)
private let sceneTrack = Color.black.opacity(0.08)

private enum GameTab: Hashable {
    case city
    case missions
    case profile
}

struct RootView: View {
    let configuration: AppConfiguration

    @Environment(\.scenePhase) private var scenePhase
    @State private var store: GameStore
    @State private var selectedTab: GameTab = .city

    init(configuration: AppConfiguration) {
        self.configuration = configuration
        _store = State(initialValue: GameStore(configuration: configuration))
    }

    var body: some View {
        @Bindable var bindableStore = store

        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.19, blue: 0.18),
                    Color(red: 0.18, green: 0.33, blue: 0.29),
                    Color(red: 0.74, green: 0.84, blue: 0.73),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: selectedTab == .city ? 0 : 14) {
                if selectedTab != .city {
                    GameHeaderView(store: store)
                        .padding(.top, 12)
                }

                TabView(selection: $selectedTab) {
                    CitySceneView(store: store)
                        .tag(GameTab.city)
                        .tabItem {
                            Label("City", systemImage: "square.grid.3x3.fill")
                        }

                    MissionSceneView(store: store)
                        .tag(GameTab.missions)
                        .tabItem {
                            Label("Trek", systemImage: "figure.walk.motion")
                        }

                    ProfileSceneView(
                        store: store,
                        showSignIn: { bindableStore.isShowingLoginSheet = true }
                    )
                    .tag(GameTab.profile)
                    .tabItem {
                        Label("Profile", systemImage: "person.crop.circle.fill")
                    }
                }
                .tint(Color(red: 0.95, green: 0.78, blue: 0.33))
            }
        }
        .task {
            store.start()
        }
        .onChange(of: scenePhase) { _, newValue in
            if newValue == .active {
                store.refreshForForeground()
            }
        }
        .sheet(isPresented: $bindableStore.isShowingLoginSheet) {
            AuthWebSheet(
                configuration: configuration,
                onCancel: { bindableStore.isShowingLoginSheet = false },
                onSuccess: { user in
                    bindableStore.isShowingLoginSheet = false
                    store.completeSignIn(with: user)
                }
            )
        }
        .alert(
            store.notice?.title ?? "",
            isPresented: Binding(
                get: { store.notice != nil },
                set: { isPresented in
                    if !isPresented {
                        store.dismissNotice()
                    }
                }
            ),
            actions: {
                Button("OK", role: .cancel) {
                    store.dismissNotice()
                }
            },
            message: {
                Text(store.notice?.message ?? "")
            }
        )
    }
}

private struct GameHeaderView: View {
    let store: GameStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Terra Tread")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: Color.black.opacity(0.30), radius: 10, x: 0, y: 4)

                    Text(store.citySummary.narrative.subtitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .shadow(color: Color.black.opacity(0.24), radius: 8, x: 0, y: 3)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        Label("\(store.citySummary.level)", systemImage: "sparkles.rectangle.stack.fill")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.black.opacity(0.30), in: Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.white.opacity(0.10))
                            )
                            .foregroundStyle(.white)

                        Label(store.state.availableSteps.formatted(), systemImage: "shoeprints.fill")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color(red: 0.96, green: 0.79, blue: 0.33), in: Capsule())
                            .foregroundStyle(Color(red: 0.17, green: 0.20, blue: 0.18))
                    }

                    Text(store.citySummary.narrative.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .shadow(color: Color.black.opacity(0.24), radius: 8, x: 0, y: 3)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    StatusChip(
                        text: store.playerStatusText,
                        tone: .muted,
                        symbol: "person.fill"
                    )
                    StatusChip(
                        text: store.connectionStatusText,
                        tone: store.connectionStatusTone,
                        symbol: "antenna.radiowaves.left.and.right"
                    )
                    StatusChip(
                        text: store.cloudStatusText,
                        tone: store.cloudStatusTone,
                        symbol: "icloud.fill"
                    )
                }
                .padding(.horizontal, 1)
            }
        }
        .padding(.horizontal, 16)
    }
}

private struct MissionSceneView: View {
    let store: GameStore

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                TrekHeroCard(store: store, goalStatusText: goalStatusText)

                GameSurfaceCard {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeading(
                            eyebrow: "Contracts",
                            title: "City Plans",
                            detail: "Small goals that help the town fill in naturally without turning the game into a grind."
                        )

                        ContractCard(
                            evaluation: store.dailyContractEvaluation,
                            claim: { store.claimContract(.daily) }
                        )

                        ContractCard(
                            evaluation: store.weeklyContractEvaluation,
                            claim: { store.claimContract(.weekly) }
                        )
                    }
                }

                if !store.streakSummary.recentDailyTotals.isEmpty {
                    GameSurfaceCard {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeading(
                                eyebrow: "History",
                                title: "Recent Walks",
                                detail: "A quick read on how your recent movement is feeding the city."
                            )

                            ForEach(store.streakSummary.recentDailyTotals) { total in
                                RecentWalkRow(total: total)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
    }

    private var goalStatusText: String {
        let goal = store.streakSummary.dailyGoal
        if goal.rewardClaimed {
            return "Today's bonus is already claimed. The city can rest until your next walk."
        }
        if let reward = store.streakSummary.rewards.claimable.first(where: { $0.type == "daily-goal" }) {
            return "Today's walk already funded a new burst of growth: +\(reward.steps) steps ready."
        }
        if let reward = store.streakSummary.rewards.claimable.first(where: { $0.type == "streak-milestone" }) {
            return "\(reward.streakLength ?? 0)-day rhythm bonus unlocked: +\(reward.steps) steps."
        }
        if goal.completed {
            return "Goal reached. Folding those steps into the city now."
        }
        return "Need \(goal.remainingSteps.formatted()) more steps for +\(goal.rewardSteps) steps."
    }
}

private struct ProfileSceneView: View {
    let store: GameStore
    let showSignIn: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ProfileHeroCard(store: store, showSignIn: showSignIn)

                GameSurfaceCard {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeading(
                            eyebrow: "Systems",
                            title: "Sync & Movement",
                            detail: "Your phone steps, backend connection, and cloud city should all read clearly at a glance."
                        )

                        SyncStatusRow(title: "Connection", value: store.connectionStatusText, tone: store.connectionStatusTone)
                        SyncStatusRow(title: "Cloud Save", value: store.cloudStatusText, tone: store.cloudStatusTone)
                        SyncStatusRow(title: "Native Steps", value: store.nativeSyncSummary, tone: .muted)

                        Button("Refresh Backend State") {
                            store.manualSync()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(sceneSun)
                        .disabled(store.currentUser == nil)
                    }
                }

                GameSurfaceCard {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeading(
                            eyebrow: "City",
                            title: "Town Snapshot",
                            detail: store.citySummary.narrative.atmosphere
                        )

                        CityNarrativePanel(
                            title: store.citySummary.narrative.title,
                            detail: store.citySummary.narrative.heritage
                        )

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                            SnapshotMetricCard(symbol: "square.grid.3x3.fill", title: "Buildings", value: "\(store.citySummary.buildingCount)")
                            SnapshotMetricCard(symbol: "building.2.fill", title: "Stage", value: store.citySummary.stage.label)
                            SnapshotMetricCard(symbol: "sparkles", title: "Prosperity", value: "\(store.citySummary.prosperity)")
                            SnapshotMetricCard(symbol: "tree.fill", title: "Trees", value: "\(store.state.trees.count)")
                        }

                        InfoRow(title: "Undo Buffer", value: store.canUndo ? "Available" : "Empty")
                        InfoRow(title: "Next Chapter", value: store.citySummary.narrative.nextChapter)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
    }
}

private struct TrekHeroCard: View {
    let store: GameStore
    let goalStatusText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Daily Trek")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.72))

                    Text("Every walk leaves a mark on your city.")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Stay steady, fund the next block, and let the settlement thicken day by day.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.84))
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 8) {
                    Text("\(store.streakSummary.dailyGoal.currentSteps.formatted())")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundStyle(.white)

                    Text("steps today")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.74))
                }
            }

            HStack(spacing: 10) {
                HeroMetricPill(
                    symbol: "flame.fill",
                    value: "\(store.streakSummary.streak.current)",
                    label: "Current streak"
                )
                HeroMetricPill(
                    symbol: "figure.walk.motion",
                    value: "\(store.streakSummary.streak.longest)",
                    label: "Best run"
                )
                HeroMetricPill(
                    symbol: "gift.fill",
                    value: "+\(activeRewardSteps)",
                    label: "Next reward"
                )
            }

            ProgressMeter(
                title: "Daily Goal",
                current: store.streakSummary.dailyGoal.currentSteps,
                target: store.streakSummary.dailyGoal.targetSteps,
                titleColor: .white.opacity(0.72),
                valueColor: .white,
                trackColor: Color.white.opacity(0.16)
            )

            Text(goalStatusText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            sceneForestDeep,
                            sceneForest,
                            Color(red: 0.40, green: 0.58, blue: 0.50),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10))
                )
                .shadow(color: Color.black.opacity(0.18), radius: 20, x: 0, y: 12)
        )
    }

    private var activeRewardSteps: Int {
        if let reward = store.streakSummary.rewards.claimable.first {
            return reward.steps
        }
        return store.streakSummary.dailyGoal.rewardSteps
    }
}

private struct ProfileHeroCard: View {
    let store: GameStore
    let showSignIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.white.opacity(0.14))

                    Image(systemName: store.currentUser == nil ? "person.crop.circle.badge.questionmark" : "person.crop.circle.badge.checkmark")
                        .font(.system(size: 28, weight: .black))
                        .foregroundStyle(.white)
                }
                .frame(width: 62, height: 62)

                VStack(alignment: .leading, spacing: 6) {
                    Text(store.currentUser?.label ?? "Guest Mode")
                        .font(.title3.weight(.black))
                        .foregroundStyle(.white)

                    Text(accountDescription)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.82))
                }

                Spacer(minLength: 8)
            }

            HStack(spacing: 10) {
                HeroMetricPill(symbol: "building.2.fill", value: store.citySummary.stage.label, label: "City stage")
                HeroMetricPill(symbol: "sparkles", value: "\(store.citySummary.level)", label: "Level")
            }

            Group {
                if store.currentUser != nil {
                    Button("Sign Out", role: .destructive) {
                        store.signOut()
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                } else {
                    Button(store.canAuthenticateInApp ? "Sign In to Sync" : "Sign-In Unavailable") {
                        showSignIn()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(sceneSun)
                    .disabled(!store.canAuthenticateInApp)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.23, green: 0.20, blue: 0.31),
                            Color(red: 0.20, green: 0.39, blue: 0.47),
                            Color(red: 0.46, green: 0.62, blue: 0.58),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10))
                )
                .shadow(color: Color.black.opacity(0.18), radius: 20, x: 0, y: 12)
        )
    }

    private var accountDescription: String {
        if store.currentUser != nil {
            return "Cloud sync and streak tracking are active for this player."
        }
        return "Sign in with Continental ID to keep your city, streaks, and native step history tied together across devices."
    }
}

private struct SectionHeading: View {
    let eyebrow: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow.uppercased())
                .font(.caption.weight(.black))
                .tracking(0.8)
                .foregroundStyle(sceneForest)

            Text(title)
                .font(.title3.weight(.black))
                .foregroundStyle(sceneInk)

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(sceneMutedInk)
        }
    }
}

private struct HeroMetricPill: View {
    let symbol: String
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.headline.weight(.black))
                .foregroundStyle(.white)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(.white)

                Text(label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ContractCard: View {
    let evaluation: ContractEvaluation
    let claim: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(evaluation.contract.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(sceneInk)

                    Text(evaluation.contract.description)
                        .font(.subheadline)
                        .foregroundStyle(sceneMutedInk)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    Text(evaluation.contract.slot.label)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(sceneForest.opacity(0.14), in: Capsule())
                        .foregroundStyle(sceneForest)

                    Text("+\(evaluation.contract.rewardSteps)")
                        .font(.caption.weight(.black))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(sceneSun.opacity(0.24), in: Capsule())
                        .foregroundStyle(sceneInk)
                }
            }

            ProgressMeter(
                title: evaluation.contract.metricKey.label.capitalized,
                current: min(evaluation.progressValue, evaluation.targetDelta),
                target: max(1, evaluation.targetDelta)
            )

            HStack {
                Text(statusText)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(sceneMutedInk)
                Spacer()
                Button(buttonTitle, action: claim)
                    .buttonStyle(.borderedProminent)
                    .disabled(!evaluation.completed || evaluation.contract.claimed)
                    .tint(sceneForest)
            }
        }
        .padding(16)
        .background(sceneCardTint, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var buttonTitle: String {
        if evaluation.contract.claimed {
            return "Claimed"
        }
        if evaluation.completed {
            return "Claim +\(evaluation.contract.rewardSteps)"
        }
        return "In Progress"
    }

    private var statusText: String {
        if evaluation.contract.claimed {
            return "Reward claimed."
        }
        if evaluation.completed {
            return "Objective complete."
        }
        return "\(evaluation.remaining) \(evaluation.contract.metricKey.label) remaining."
    }
}

struct ProgressMeter: View {
    let title: String
    let current: Int
    let target: Int
    var titleColor: Color = sceneMutedInk
    var valueColor: Color = sceneInk
    var trackColor: Color = sceneTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(titleColor)
                Spacer()
                Text("\(current.formatted()) / \(target.formatted())")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(valueColor)
            }

            GeometryReader { proxy in
                let progress = max(0, min(1, Double(current) / Double(max(1, target))))

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(trackColor)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    sceneSun,
                                    sceneForest,
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 12)
        }
    }
}

private struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(sceneMutedInk)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(sceneInk)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct RecentWalkRow: View {
    let total: RecentDailyTotal

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(total.dayKey)
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(sceneInk)

                Text(total.totalSteps >= TerraTreadRules.dailyGoal ? "Goal reached" : "Still below today’s rhythm")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(total.totalSteps >= TerraTreadRules.dailyGoal ? sceneForest : sceneSoftInk)
            }

            Spacer()

            Text("\(total.totalSteps.formatted()) steps")
                .font(.subheadline.weight(.black))
                .foregroundStyle(sceneInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    (total.totalSteps >= TerraTreadRules.dailyGoal ? sceneSun.opacity(0.24) : Color.black.opacity(0.05)),
                    in: Capsule()
                )
        }
        .padding(14)
        .background(sceneCardTint, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct SyncStatusRow: View {
    let title: String
    let value: String
    let tone: StatusTone

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(sceneInk)

                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(sceneMutedInk)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(sceneCardTint, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var indicatorColor: Color {
        switch tone {
        case .online:
            sceneForest
        case .offline:
            sceneRose
        case .syncing:
            sceneSun
        case .muted:
            sceneSoftInk
        }
    }
}

private struct SnapshotMetricCard: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.headline.weight(.black))
                .foregroundStyle(sceneForest)

            Text(value)
                .font(.headline.weight(.black))
                .foregroundStyle(sceneInk)

            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(sceneMutedInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(sceneCardTint, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct CityNarrativePanel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline.weight(.black))
                .foregroundStyle(sceneInk)

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(sceneMutedInk)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sceneCardTint, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct StatusChip: View {
    let text: String
    let tone: StatusTone
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(backgroundColor, in: Capsule())
            .foregroundStyle(foregroundColor)
            .overlay(
                Capsule()
                    .strokeBorder(borderColor)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 4)
    }

    private var backgroundColor: Color {
        switch tone {
        case .online:
            Color(red: 0.81, green: 0.93, blue: 0.83)
        case .offline:
            Color(red: 0.96, green: 0.80, blue: 0.79)
        case .syncing:
            Color(red: 0.97, green: 0.86, blue: 0.66)
        case .muted:
            Color.black.opacity(0.30)
        }
    }

    private var foregroundColor: Color {
        switch tone {
        case .muted:
            .white
        default:
            Color(red: 0.14, green: 0.18, blue: 0.17)
        }
    }

    private var borderColor: Color {
        switch tone {
        case .muted:
            Color.white.opacity(0.10)
        default:
            Color.black.opacity(0.08)
        }
    }
}

struct GameSurfaceCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(sceneCardFill.opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(sceneCardStroke)
                )
                .shadow(color: Color.black.opacity(0.16), radius: 20, x: 0, y: 12)
        )
    }
}

#Preview {
    RootView(configuration: .current)
}
