import Foundation
import Observation

@MainActor
@Observable
final class GameStore {
    let configuration: AppConfiguration

    var state: GameState
    var citySummary: CitySummary
    var streakSummary = StreakSummary()
    var currentUser: AuthenticatedUser?

    var isBuildMode = false
    var selectedBuildingID: String?
    var selectedBuildType: BuildingType?
    var relocationBuildingID: String?
    var pendingPlacement: PendingPlacement?

    var isShowingLoginSheet = false
    var notice: AppNotice?

    var connectionStatusText = "Backend not checked yet"
    var connectionStatusTone: StatusTone = .muted
    var cloudStatusText = "Cloud saves are available after login."
    var cloudStatusTone: StatusTone = .muted

    var latestStepSnapshot: StepSnapshot?

    var hasConfiguredBackend: Bool {
        configuration.effectiveGameAPIBaseURL != nil
    }

    var canAuthenticateInApp: Bool {
        configuration.canAuthenticateInApp
    }

    var selectedBuilding: PlacedBuilding? {
        guard let selectedBuildingID else { return nil }
        return GameEngine.building(id: selectedBuildingID, buildings: state.buildings)
    }

    var selectedBuildingBreakdown: BuildingBreakdown? {
        guard let selectedBuildingID else { return nil }
        return citySummary.breakdown.first { $0.id == selectedBuildingID }
    }

    var dailyContractEvaluation: ContractEvaluation {
        GameEngine.evaluateContract(state.contracts.daily, state: state, summary: citySummary)
    }

    var weeklyContractEvaluation: ContractEvaluation {
        GameEngine.evaluateContract(state.contracts.weekly, state: state, summary: citySummary)
    }

    var nativeSyncSummary: String {
        let synced = max(0, state.lastNativeStepTotal)
        return state.lastNativeStepDate == nil ? "Waiting for step data" : "iPhone steps synced: \(synced) today"
    }

    var playerStatusText: String {
        if let currentUser {
            return "\(nativeSyncSummary) • \(currentUser.label)"
        }
        return "\(nativeSyncSummary) • Guest mode"
    }

    var canUndo: Bool {
        !undoStack.isEmpty
    }

    var inPlacementMode: Bool {
        isBuildMode || relocationBuildingID != nil
    }

    @ObservationIgnored private let persistence: GamePersistence
    @ObservationIgnored private let backendClient: GameBackendClient
    @ObservationIgnored private let stepService = StepSyncService()
    @ObservationIgnored private var undoStack: [GameState] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var cloudStateReady = false
    @ObservationIgnored private var cloudStateUserID = ""
    @ObservationIgnored private var cloudSaveTask: Task<Void, Never>?
    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?

    init(configuration: AppConfiguration, persistence: GamePersistence? = nil) {
        let persistence = persistence ?? .shared
        let loadedState = persistence.loadState()
        let loadedUser = persistence.loadUser()

        self.configuration = configuration
        self.persistence = persistence
        self.backendClient = GameBackendClient(configuration: configuration)
        self.state = loadedState
        self.currentUser = loadedUser
        self.citySummary = GameEngine.computeCitySummary(buildings: loadedState.buildings)
        reconcileState(touch: false, scheduleCloud: false)

        if currentUser == nil {
            cloudStatusText = "Cloud saves are available after login."
            cloudStatusTone = .muted
        } else {
            cloudStatusText = "Ready to sync your cloud city."
            cloudStatusTone = .muted
        }

        if hasConfiguredBackend {
            connectionStatusText = "Backend configured"
            connectionStatusTone = .muted
        } else {
            connectionStatusText = "Backend unavailable in this build"
            connectionStatusTone = .offline
        }
    }

    func start() {
        guard !started else { return }
        started = true

        stepService.onSnapshot = { [weak self] snapshot in
            self?.handleStepSnapshot(snapshot)
        }
        stepService.onAuthorizationDenied = { [weak self] in
            self?.notice = AppNotice(
                title: "Motion Access Needed",
                message: "Enable Motion & Fitness access in Settings to convert your steps into build currency."
            )
        }

        stepService.start()

        if currentUser != nil {
            syncTask = Task { [weak self] in
                await self?.restoreAuthenticatedSession()
            }
        }
    }

    func refreshForForeground() {
        stepService.refresh()

        guard currentUser != nil else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            await self?.fetchStepSummary()
        }
    }

    func dismissNotice() {
        notice = nil
    }

    func toggleBuildMode() {
        if isBuildMode {
            exitBuildMode()
        } else {
            enterBuildMode()
        }
    }

    func enterBuildMode() {
        isBuildMode = true
        selectedBuildingID = nil
        relocationBuildingID = nil
        pendingPlacement = nil
    }

    func startBuilding(_ type: BuildingType) {
        isBuildMode = true
        selectedBuildType = type
        relocationBuildingID = nil
        pendingPlacement = nil
        selectedBuildingID = nil
    }

    func exitBuildMode() {
        isBuildMode = false
        selectedBuildType = nil
        pendingPlacement = nil
        selectedBuildingID = nil
    }

    func cancelPlacementMode() {
        exitBuildMode()
        relocationBuildingID = nil
    }

    func clearPendingPlacement() {
        pendingPlacement = nil
    }

    func handleTileTap(row: Int, col: Int) {
        if isBuildMode {
            guard let selectedBuildType else {
                pendingPlacement = nil
                selectedBuildingID = nil
                return
            }

            let definition = GameEngine.buildingDefinition(for: selectedBuildType)
            guard state.availableSteps >= definition.cost else {
                pendingPlacement = nil
                notice = AppNotice(
                    title: "More Steps Needed",
                    message: "You need \(max(0, definition.cost - state.availableSteps)) more steps to place a \(definition.label.lowercased())."
                )
                return
            }

            let placement = GameEngine.canPlaceBuilding(state.buildings, type: selectedBuildType, row: row, col: col)
            pendingPlacement = PendingPlacement(
                mode: .build(selectedBuildType),
                row: row,
                col: col,
                tiles: placement.tiles,
                isValid: placement.ok,
                blockedReason: placement.reason
            )
            return
        }

        if let relocationBuildingID,
           let building = GameEngine.building(id: relocationBuildingID, buildings: state.buildings) {
            let placement = GameEngine.canPlaceBuilding(state.buildings, type: building.type, row: row, col: col, ignoring: relocationBuildingID)
            pendingPlacement = PendingPlacement(
                mode: .move(buildingID: relocationBuildingID, buildingType: building.type),
                row: row,
                col: col,
                tiles: placement.tiles,
                isValid: placement.ok,
                blockedReason: placement.reason
            )
            return
        }

        if let building = GameEngine.building(at: row, col: col, buildings: state.buildings) {
            selectedBuildingID = building.id
            pendingPlacement = nil
        } else {
            selectedBuildingID = nil
            pendingPlacement = nil
        }
    }

    func confirmPendingPlacement() {
        guard let pendingPlacement else { return }
        guard pendingPlacement.isValid else {
            notice = AppNotice(
                title: "That Plot Is Unavailable",
                message: placementMessage(for: pendingPlacement.blockedReason)
            )
            return
        }

        recordUndoSnapshot()

        switch pendingPlacement.mode {
        case .build(let type):
            let result = GameEngine.applyBuildAction(state: &state, type: type, row: pendingPlacement.row, col: pendingPlacement.col)
            guard result.ok else {
                undoStack.removeLast()
                notice = AppNotice(title: "Build Failed", message: actionMessage(for: result.error))
                return
            }

            relocationBuildingID = nil
            self.pendingPlacement = nil
            selectedBuildingID = nil
            if state.availableSteps < GameEngine.buildingDefinition(for: type).cost {
                selectedBuildType = nil
            }
            reconcileState()

        case .move(let buildingID, _):
            let result = GameEngine.applyMoveAction(state: &state, buildingID: buildingID, row: pendingPlacement.row, col: pendingPlacement.col)
            guard result.ok else {
                undoStack.removeLast()
                notice = AppNotice(title: "Move Failed", message: actionMessage(for: result.error))
                return
            }

            relocationBuildingID = nil
            self.pendingPlacement = nil
            selectedBuildingID = buildingID
            reconcileState()
        }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        let preservedBuildMode = isBuildMode
        let preservedBuildType = selectedBuildType
        state = previous
        relocationBuildingID = nil
        pendingPlacement = nil
        selectedBuildingID = nil
        isBuildMode = preservedBuildMode
        selectedBuildType = preservedBuildMode ? preservedBuildType : nil
        reconcileState(touch: false)
    }

    func beginRelocationForSelectedBuilding() {
        guard let selectedBuilding else { return }

        if relocationBuildingID == selectedBuilding.id {
            relocationBuildingID = nil
            pendingPlacement = nil
            return
        }

        isBuildMode = false
        selectedBuildType = nil
        relocationBuildingID = selectedBuilding.id
        pendingPlacement = nil
    }

    func upgradeSelectedBuilding() {
        guard let selectedBuildingID else { return }

        recordUndoSnapshot()
        let result = GameEngine.applyUpgradeAction(state: &state, buildingID: selectedBuildingID)
        guard result.ok else {
            undoStack.removeLast()
            notice = AppNotice(title: "Upgrade Failed", message: actionMessage(for: result.error))
            return
        }

        reconcileState()
    }

    func demolishSelectedBuilding() {
        guard let selectedBuildingID else { return }

        recordUndoSnapshot()
        let result = GameEngine.applyDemolishAction(state: &state, buildingID: selectedBuildingID)
        guard result.ok else {
            undoStack.removeLast()
            notice = AppNotice(title: "Demolition Failed", message: actionMessage(for: result.error))
            return
        }

        self.selectedBuildingID = nil
        relocationBuildingID = nil
        pendingPlacement = nil
        reconcileState()
    }

    func resetCity() {
        recordUndoSnapshot()
        _ = GameEngine.applyResetAction(state: &state)
        selectedBuildingID = nil
        isBuildMode = false
        selectedBuildType = nil
        relocationBuildingID = nil
        pendingPlacement = nil
        reconcileState()
    }

    func claimContract(_ slot: ContractSlot) {
        let result = GameEngine.claimContractReward(state: &state, slot: slot, summary: citySummary)
        guard result.ok else {
            notice = AppNotice(title: "Reward Locked", message: "Complete the contract before claiming its step reward.")
            return
        }

        reconcileState()
    }

    func signOut() {
        currentUser = nil
        persistence.saveUser(nil)
        cloudStateReady = false
        cloudStateUserID = ""
        cloudSaveTask?.cancel()
        uploadTask?.cancel()
        streakSummary = StreakSummary()
        cloudStatusText = "Cloud saves are available after login."
        cloudStatusTone = .muted

        Task {
            await ContinentalAuthSessionStore.clearSession()
        }
    }

    func completeSignIn(with user: AuthenticatedUser) {
        currentUser = user
        persistence.saveUser(user)
        cloudStatusText = "Syncing your city from the cloud..."
        cloudStatusTone = .syncing

        syncTask?.cancel()
        syncTask = Task { [weak self] in
            await self?.restoreAuthenticatedSession()
        }
    }

    func manualSync() {
        guard currentUser != nil else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            await self?.syncCloudStateForCurrentUser()
            await self?.fetchStepSummary()
        }
    }

    private func restoreAuthenticatedSession() async {
        await syncCloudStateForCurrentUser()
        await fetchStepSummary()
        await syncPendingNativeSteps()
    }

    private func handleStepSnapshot(_ snapshot: StepSnapshot) {
        latestStepSnapshot = snapshot
        _ = GameEngine.applyNativeStepSnapshot(state: &state, todaySteps: snapshot.todaySteps, dayKey: snapshot.dayKey)
        reconcileState()

        guard currentUser != nil else { return }
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            await self?.syncPendingNativeSteps()
        }
    }

    private func fetchStepSummary() async {
        guard let user = currentUser else { return }

        do {
            let response = try await backendClient.fetchSteps(for: user.userId)
            streakSummary = response.summary ?? StreakSummary()
            setConnectionStatus("Backend connected", tone: .online)
            await claimAvailableRewards(streakSummary.rewards.claimable, userID: user.userId)
        } catch {
            setConnectionStatus("Backend unavailable", tone: .offline)
        }
    }

    private func claimAvailableRewards(_ rewards: [RewardSummary], userID: String) async {
        guard !rewards.isEmpty else { return }

        var grantedSteps = 0

        for reward in rewards {
            do {
                let response = try await backendClient.claimReward(userID: userID, reward: reward)
                grantedSteps += response.reward?.steps ?? 0
                if let summary = response.summary {
                    streakSummary = summary
                }
            } catch {
                setConnectionStatus("Backend unavailable", tone: .offline)
            }
        }

        guard grantedSteps > 0 else { return }

        state.availableSteps += grantedSteps
        reconcileState()
    }

    private func syncPendingNativeSteps() async {
        guard let user = currentUser,
              let payload = pendingNativeStepUploadPayload(for: user) else {
            return
        }

        do {
            try await backendClient.uploadSteps(payload)
            state.lastUploadedNativeUserId = payload.userId
            state.lastUploadedNativeDayKey = payload.deviceDayKey
            state.lastUploadedNativeStepTotal = payload.metadata.totalSteps
            reconcileState()
            setConnectionStatus("Backend connected", tone: .online)
            await fetchStepSummary()
        } catch {
            setConnectionStatus("Backend unavailable", tone: .offline)
        }
    }

    private func pendingNativeStepUploadPayload(for user: AuthenticatedUser) -> StepUploadRequest? {
        guard let dayKey = state.lastNativeStepDate,
              state.lastNativeStepTotal > 0 else {
            return nil
        }

        let totalSteps = max(0, state.lastNativeStepTotal)
        let sameUser = state.lastUploadedNativeUserId == user.userId
        let sameDay = state.lastUploadedNativeDayKey == dayKey
        let uploadedTotal = sameUser && sameDay ? max(0, state.lastUploadedNativeStepTotal) : 0
        let pendingSteps = totalSteps - uploadedTotal

        guard pendingSteps > 0 else { return nil }

        return StepUploadRequest(
            userId: user.userId,
            steps: pendingSteps,
            source: "ios-motion",
            syncKey: "ios-motion:\(user.userId):\(dayKey):\(totalSteps)",
            deviceDayKey: dayKey,
            metadata: .init(platform: "ios-app", totalSteps: totalSteps)
        )
    }

    private func syncCloudStateForCurrentUser() async {
        guard let user = currentUser else {
            cloudStateReady = false
            cloudStateUserID = ""
            cloudStatusText = "Cloud saves are available after login."
            cloudStatusTone = .muted
            return
        }

        cloudStatusText = "Syncing your city from the cloud..."
        cloudStatusTone = .syncing

        do {
            let response = try await backendClient.fetchCloudState(for: user.userId)
            let remoteState = response.state.map(GameEngine.normalizedState)
            let remoteUpdatedAt = response.updatedAt ?? remoteState?.updatedAt
            let localOwner = state.cloudOwnerUserId ?? ""
            let localOwnedByDifferentUser = !localOwner.isEmpty && localOwner != user.userId
            let shouldUseRemoteState: Bool

            if let remoteState {
                shouldUseRemoteState =
                    localOwnedByDifferentUser ||
                    !GameEngine.hasMeaningfulProgress(state) ||
                    GameEngine.timestampValue(remoteUpdatedAt ?? remoteState.updatedAt) > GameEngine.timestampValue(state.updatedAt)
            } else {
                shouldUseRemoteState = false
            }

            if let remoteState, shouldUseRemoteState {
                state = remoteState
                state.updatedAt = remoteUpdatedAt ?? remoteState.updatedAt
                state.cloudOwnerUserId = user.userId
                reconcileState(touch: false, scheduleCloud: false)
            } else if remoteState == nil, localOwnedByDifferentUser {
                state = GameEngine.createDefaultState { state in
                    state.cloudOwnerUserId = user.userId
                }
                reconcileState(touch: false, scheduleCloud: false)
            } else {
                state.cloudOwnerUserId = user.userId
                reconcileState(touch: false, scheduleCloud: false)
            }

            cloudStateReady = true
            cloudStateUserID = user.userId

            if remoteState == nil || !shouldUseRemoteState {
                await syncCloudStateToServer()
            } else {
                cloudStatusText = "Cloud save synced."
                cloudStatusTone = .online
            }

            setConnectionStatus("Backend connected", tone: .online)
        } catch {
            cloudStateReady = false
            cloudStateUserID = ""
            cloudStatusText = "Cloud saves are unavailable while the backend is offline."
            cloudStatusTone = .offline
            setConnectionStatus("Backend unavailable", tone: .offline)
        }
    }

    private func syncCloudStateToServer() async {
        guard let user = currentUser,
              cloudStateReady,
              cloudStateUserID == user.userId else {
            return
        }

        cloudStatusText = "Saving city to the cloud..."
        cloudStatusTone = .syncing

        do {
            state.cloudOwnerUserId = user.userId
            let response = try await backendClient.saveCloudState(state, for: user.userId)
            if let remoteState = response.state {
                state = GameEngine.normalizedState(remoteState)
                state.updatedAt = response.updatedAt ?? remoteState.updatedAt
                state.cloudOwnerUserId = user.userId
                reconcileState(touch: false, scheduleCloud: false)
            } else if let updatedAt = response.updatedAt {
                state.updatedAt = updatedAt
                reconcileState(touch: false, scheduleCloud: false)
            }
            cloudStatusText = "Cloud save synced."
            cloudStatusTone = .online
        } catch {
            cloudStatusText = "Cloud save pending. Retry when the backend is reachable."
            cloudStatusTone = .offline
            setConnectionStatus("Backend unavailable", tone: .offline)
        }
    }

    private func scheduleCloudSave(immediate: Bool = false) {
        guard let user = currentUser,
              cloudStateReady,
              cloudStateUserID == user.userId else {
            return
        }

        cloudSaveTask?.cancel()

        if immediate {
            cloudSaveTask = Task { [weak self] in
                await self?.syncCloudStateToServer()
            }
            return
        }

        cloudSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled else { return }
            await self?.syncCloudStateToServer()
        }
    }

    private func recordUndoSnapshot() {
        undoStack.append(state)
        if undoStack.count > TerraTreadRules.maxUndoEntries {
            undoStack.removeFirst(undoStack.count - TerraTreadRules.maxUndoEntries)
        }
    }

    private func reconcileState(touch: Bool = true, scheduleCloud: Bool = true) {
        state = GameEngine.normalizedState(state)
        citySummary = GameEngine.computeCitySummary(buildings: state.buildings)
        let refreshedContracts = GameEngine.refreshContracts(state: state, summary: citySummary)
        state.contracts = refreshedContracts.contracts

        if let selectedBuildingID,
           GameEngine.building(id: selectedBuildingID, buildings: state.buildings) == nil {
            self.selectedBuildingID = nil
        }

        if let relocationBuildingID,
           GameEngine.building(id: relocationBuildingID, buildings: state.buildings) == nil {
            self.relocationBuildingID = nil
            pendingPlacement = nil
        }

        state.nextBuildingId = max(state.nextBuildingId, GameEngine.nextBuildingSequence(for: state.buildings))
        state.updatedAt = touch ? Self.isoFormatter.string(from: Date()) : state.updatedAt.flatMap(GameEngine.normalizedISODate)

        persistence.saveState(state)

        if scheduleCloud {
            scheduleCloudSave()
        }
    }

    private func setConnectionStatus(_ text: String, tone: StatusTone) {
        connectionStatusText = text
        connectionStatusTone = tone
    }

    private func placementMessage(for code: String?) -> String {
        switch code {
        case "occupied":
            "Another district already covers that footprint."
        case "locked-area":
            "That district is outside your current build zone."
        case "out-of-bounds":
            "That district would cross the city boundary."
        default:
            "Choose an open plot inside the city limits."
        }
    }

    private func actionMessage(for code: String?) -> String {
        switch code {
        case "locked":
            "That district unlocks at a higher city level."
        case "insufficient-steps":
            "You need more steps in your bank to do that."
        case "occupied":
            "Another district already occupies that destination."
        case "locked-area":
            "That plot is outside your current build zone."
        case "out-of-bounds":
            "That placement would cross the city boundary."
        case "max-level":
            "This district has already reached its max level."
        case "missing-building":
            "That district could not be found anymore."
        case "same-position":
            "Pick a different plot to move this district."
        default:
            "That action could not be completed."
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
