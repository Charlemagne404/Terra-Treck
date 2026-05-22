import Foundation

@MainActor
enum GameEngine {
    struct PlacementResult {
        let ok: Bool
        let reason: String?
        let tiles: [GridPoint]
    }

    struct BuildResult {
        let ok: Bool
        let error: String?
        let building: PlacedBuilding?
        let tiles: [GridPoint]
    }

    struct MoveResult {
        let ok: Bool
        let error: String?
        let buildingID: String?
        let tiles: [GridPoint]
    }

    struct UpgradeResult {
        let ok: Bool
        let error: String?
        let upgradeCost: Int
    }

    struct DemolishResult {
        let ok: Bool
        let error: String?
        let refundSteps: Int
    }

    struct ResetResult {
        let ok: Bool
        let refundedSteps: Int
    }

    struct ClaimContractResult {
        let ok: Bool
        let error: String?
        let rewardSteps: Int
        let evaluation: ContractEvaluation?
    }

    struct StepDeltaResult {
        let grantedSteps: Int
        let dayKey: String
        let totalSteps: Int
    }

    struct ServerSyncResult {
        let grantedSteps: Int
        let newestTimestamp: String?
    }

    struct ContractRefreshResult {
        let contracts: ContractsState
        let changed: Bool
    }

    struct ContractTemplate {
        let id: String
        let title: String
        let isAvailable: (GameState, CitySummary) -> Bool
        let create: (GameState, CitySummary) -> (metric: ContractMetric, targetDelta: Int, rewardSteps: Int, description: String)
    }

    static func createInitialTrees(
        gridSize: Int = TerraTreadRules.gridSize,
        imageCount: Int = TerraTreadRules.treeVariantCount,
        treeChance: Double = TerraTreadRules.treeSpawnChance
    ) -> [TreeTile] {
        var trees: [TreeTile] = []
        let origin = TerraTreadRules.startingTerrainOrigin

        for rowOffset in 0..<gridSize {
            for colOffset in 0..<gridSize where Double.random(in: 0...1) < treeChance {
                trees.append(
                    TreeTile(
                        row: origin + rowOffset,
                        col: origin + colOffset,
                        imageIndex: Int.random(in: 0..<imageCount)
                    )
                )
            }
        }

        return trees
    }

    static func createDefaultState(overrides: ((inout GameState) -> Void)? = nil) -> GameState {
        var state = GameState(
            schemaVersion: TerraTreadRules.cloudStateSchemaVersion,
            availableSteps: TerraTreadRules.defaultSteps,
            lastStepTimestamp: nil,
            lastNativeStepDate: nil,
            lastNativeStepTotal: 0,
            lastUploadedNativeUserId: nil,
            lastUploadedNativeDayKey: nil,
            lastUploadedNativeStepTotal: 0,
            buildings: [],
            nextBuildingId: 1,
            trees: createInitialTrees(),
            lifetimeStats: LifetimeStats(),
            contracts: ContractsState(),
            updatedAt: nil,
            cloudOwnerUserId: nil
        )
        overrides?(&state)
        return normalizedState(state)
    }

    static func normalizedState(_ state: GameState) -> GameState {
        var normalized = state
        normalized.schemaVersion = TerraTreadRules.cloudStateSchemaVersion
        normalized.availableSteps = max(0, normalized.availableSteps)
        normalized.lastStepTimestamp = normalized.lastStepTimestamp.flatMap(normalizedISODate)
        normalized.lastNativeStepDate = normalized.lastNativeStepDate.flatMap(normalizedDayKey)
        normalized.lastNativeStepTotal = max(0, normalized.lastNativeStepTotal)
        normalized.lastUploadedNativeDayKey = normalized.lastUploadedNativeDayKey.flatMap(normalizedDayKey)
        normalized.lastUploadedNativeStepTotal = max(0, normalized.lastUploadedNativeStepTotal)
        normalized.buildings = sanitizedBuildings(normalized.buildings)
        normalized.nextBuildingId = max(nextBuildingSequence(for: normalized.buildings), max(1, normalized.nextBuildingId))
        normalized.trees = sanitizedTrees(normalized.trees)
        normalized.updatedAt = normalized.updatedAt.flatMap(normalizedISODate)
        return normalized
    }

    static func sanitizedBuildings(_ source: [PlacedBuilding]) -> [PlacedBuilding] {
        var usedIDs = Set<String>()

        return source.enumerated().compactMap { index, building in
            guard let definition = TerraTreadRules.buildingDefinitions[building.type] else {
                return nil
            }

            guard isFootprintWithinBuildBounds(
                row: building.row,
                col: building.col,
                width: definition.width,
                height: definition.height
            ) else {
                return nil
            }

            var identifier = building.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if identifier.isEmpty {
                identifier = "legacy-\(index + 1)"
            }
            while usedIDs.contains(identifier) {
                identifier = "\(identifier)-\(index + 1)"
            }
            usedIDs.insert(identifier)

            return PlacedBuilding(
                id: identifier,
                type: building.type,
                row: building.row,
                col: building.col,
                level: normalizedBuildingLevel(building.level)
            )
        }
    }

    static func sanitizedTrees(_ source: [TreeTile]) -> [TreeTile] {
        source.filter { tree in
            isBuildableTile(row: tree.row, col: tree.col) &&
            tree.imageIndex >= 0 &&
            tree.imageIndex < TerraTreadRules.treeVariantCount
        }
    }

    static func hasMeaningfulProgress(_ state: GameState) -> Bool {
        !state.buildings.isEmpty ||
        state.availableSteps != TerraTreadRules.defaultSteps ||
        !(state.lastStepTimestamp ?? "").isEmpty ||
        !(state.lastNativeStepDate ?? "").isEmpty ||
        state.lastNativeStepTotal > 0 ||
        state.lifetimeStats.built > 0 ||
        state.lifetimeStats.upgraded > 0 ||
        state.lifetimeStats.moved > 0 ||
        state.lifetimeStats.demolished > 0
    }

    static func timestampValue(_ value: String?) -> TimeInterval {
        guard let value,
              let date = isoFormatter.date(from: value) else {
            return 0
        }
        return date.timeIntervalSince1970
    }

    static func buildingEntries() -> [BuildingDefinition] {
        TerraTreadRules.buildingDefinitions.values.sorted {
            $0.unlockLevel == $1.unlockLevel ? $0.cost < $1.cost : $0.unlockLevel < $1.unlockLevel
        }
    }

    static func buildingDefinition(for type: BuildingType) -> BuildingDefinition {
        TerraTreadRules.buildingDefinitions[type]!
    }

    static func isBuildingUnlocked(_ type: BuildingType, level: Int) -> Bool {
        buildingDefinition(for: type).unlockLevel <= level
    }

    static func buildingMaxLevel(for type: BuildingType) -> Int {
        TerraTreadRules.maxBuildingLevel
    }

    static func buildingLevelMultiplier(_ level: Int) -> Double {
        1 + (Double(max(0, normalizedBuildingLevel(level) - 1)) * TerraTreadRules.buildingLevelStep)
    }

    static func buildingUpgradeCost(_ building: PlacedBuilding) -> Int {
        let definition = buildingDefinition(for: building.type)
        let level = normalizedBuildingLevel(building.level)
        guard level < buildingMaxLevel(for: building.type) else {
            return 0
        }

        let multiplier = 0.6 + (Double(level - 1) * 0.35)
        return max(10, Int((Double(definition.cost) * multiplier).rounded()))
    }

    static func buildingTotalInvestment(_ building: PlacedBuilding) -> Int {
        let definition = buildingDefinition(for: building.type)
        let level = normalizedBuildingLevel(building.level)
        var total = definition.cost

        guard level > 1 else { return total }

        for currentLevel in 1..<level {
            total += buildingUpgradeCost(PlacedBuilding(id: building.id, type: building.type, row: building.row, col: building.col, level: currentLevel))
        }

        return total
    }

    static func footprint(for building: PlacedBuilding) -> [GridPoint] {
        let definition = buildingDefinition(for: building.type)
        var tiles: [GridPoint] = []

        for rowOffset in 0..<definition.height {
            for colOffset in 0..<definition.width {
                tiles.append(GridPoint(row: building.row + rowOffset, col: building.col + colOffset))
            }
        }

        return tiles
    }

    static func footprint(for type: BuildingType, row: Int, col: Int) -> [GridPoint] {
        footprint(for: PlacedBuilding(id: "preview", type: type, row: row, col: col, level: 1))
    }

    static func occupancyMap(for buildings: [PlacedBuilding]) -> [GridPoint: Int] {
        var occupancy: [GridPoint: Int] = [:]
        for (index, building) in sanitizedBuildings(buildings).enumerated() {
            for tile in footprint(for: building) {
                occupancy[tile] = index
            }
        }
        return occupancy
    }

    static func computeCitySummary(buildings: [PlacedBuilding]) -> CitySummary {
        let normalizedBuildings = sanitizedBuildings(buildings)
        var stats = EffectTotals.zero
        var baseTotals = EffectTotals.zero
        var synergyTotals = EffectTotals.zero
        let occupancy = occupancyMap(for: normalizedBuildings)
        var adjacency = Array(repeating: Set<Int>(), count: normalizedBuildings.count)
        var triggeredSynergies = 0

        for (index, building) in normalizedBuildings.enumerated() {
            for tile in footprint(for: building) {
                for (rowDelta, colDelta) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let neighbor = GridPoint(row: tile.row + rowDelta, col: tile.col + colDelta)
                    if let neighborIndex = occupancy[neighbor], neighborIndex != index {
                        adjacency[index].insert(neighborIndex)
                    }
                }
            }
        }

        let breakdown: [BuildingBreakdown] = normalizedBuildings.enumerated().map { index, building in
            let definition = buildingDefinition(for: building.type)
            let levelMultiplier = buildingLevelMultiplier(building.level)
            let scaledBaseEffects = definition.baseEffects.scaled(multiplier: levelMultiplier)
            var totalEffects = scaledBaseEffects
            var synergyDetails: [BuildingSynergyDetail] = []
            baseTotals.add(scaledBaseEffects)

            for rule in definition.synergies {
                let matchingCount = adjacency[index]
                    .compactMap { normalizedBuildings[safe: $0] }
                    .filter { $0.type == rule.with }
                    .count

                guard matchingCount > 0 else { continue }
                let bonus = rule.effects.scaled(multiplier: levelMultiplier)
                let combinedBonus = bonus.adding(bonus, times: matchingCount - 1)
                totalEffects.add(combinedBonus)
                synergyTotals.add(combinedBonus)
                triggeredSynergies += matchingCount
                synergyDetails.append(
                    BuildingSynergyDetail(
                        with: rule.with,
                        count: matchingCount,
                        effects: combinedBonus,
                        label: rule.label
                    )
                )
            }

            stats.add(totalEffects)

            return BuildingBreakdown(
                id: building.id,
                type: building.type,
                row: building.row,
                col: building.col,
                level: building.level,
                totalEffects: totalEffects,
                synergyDetails: synergyDetails
            )
        }

        let prosperity = stats.prosperity
        let level = level(for: prosperity)
        let currentLevelThreshold = currentLevelThreshold(for: level)
        let nextLevelThreshold = nextLevelThreshold(for: level)
        let progressPercent: Double

        if let nextLevelThreshold, nextLevelThreshold > currentLevelThreshold {
            progressPercent = max(0, min(100, ((Double(prosperity - currentLevelThreshold) / Double(nextLevelThreshold - currentLevelThreshold)) * 100)))
        } else {
            progressPercent = 100
        }

        let unlockedBuildings = buildingEntries()
            .filter { level >= $0.unlockLevel }
            .map(\.type)
        let nextUnlock = buildingEntries().first { level < $0.unlockLevel }?.type
        let stage = cityStage(for: level)
        let narrative = cityNarrative(
            for: stage,
            stats: stats,
            buildings: normalizedBuildings,
            nextUnlock: nextUnlock
        )

        return CitySummary(
            level: level,
            prosperity: prosperity,
            currentLevelThreshold: currentLevelThreshold,
            nextLevelThreshold: nextLevelThreshold,
            progressPercent: progressPercent,
            stats: stats,
            baseTotals: baseTotals,
            synergyTotals: synergyTotals,
            prosperityBonus: synergyTotals.prosperity,
            unlockedBuildings: unlockedBuildings,
            nextUnlock: nextUnlock,
            buildingCount: normalizedBuildings.count,
            triggeredSynergies: triggeredSynergies,
            breakdown: breakdown,
            stage: stage,
            narrative: narrative
        )
    }

    static func evaluateContract(_ contract: ContractRecord, state: GameState, summary: CitySummary) -> ContractEvaluation {
        let currentValue = contractMetricValue(contract.metricKey, state: state, summary: summary)
        let targetDelta = max(1, contract.targetDelta > 0 ? contract.targetDelta : max(1, contract.targetValue - contract.startValue))
        let rawProgress = currentValue - contract.startValue
        let progressValue = max(0, rawProgress)
        let completed = contract.claimed || currentValue >= contract.targetValue
        let displayProgressValue = contract.claimed ? targetDelta : progressValue
        let progressPercent = contract.claimed ? 100 : max(0, min(100, (Double(displayProgressValue) / Double(targetDelta)) * 100))

        return ContractEvaluation(
            contract: contract,
            currentValue: currentValue,
            targetDelta: targetDelta,
            progressValue: displayProgressValue,
            completed: completed,
            progressPercent: progressPercent,
            remaining: contract.claimed ? 0 : max(0, targetDelta - displayProgressValue)
        )
    }

    static func refreshContracts(state: GameState, summary: CitySummary, date: Date = Date()) -> ContractRefreshResult {
        var contracts = state.contracts
        let nextDailyKey = contractCycleKey(for: .daily, date: date)
        let nextWeeklyKey = contractCycleKey(for: .weekly, date: date)
        var changed = false

        if contracts.daily.cycleKey != nextDailyKey || contracts.daily.title.isEmpty {
            contracts.daily = createContract(for: .daily, state: state, summary: summary, date: date)
            changed = true
        }

        if contracts.weekly.cycleKey != nextWeeklyKey || contracts.weekly.title.isEmpty {
            contracts.weekly = createContract(for: .weekly, state: state, summary: summary, date: date)
            changed = true
        }

        return ContractRefreshResult(contracts: contracts, changed: changed)
    }

    static func building(at row: Int, col: Int, buildings: [PlacedBuilding]) -> PlacedBuilding? {
        sanitizedBuildings(buildings).first { building in
            footprint(for: building).contains(GridPoint(row: row, col: col))
        }
    }

    static func building(id: String, buildings: [PlacedBuilding]) -> PlacedBuilding? {
        sanitizedBuildings(buildings).first { $0.id == id }
    }

    static func isBuildableTile(row: Int, col: Int) -> Bool {
        row >= TerraTreadRules.worldMinCoordinate &&
        row <= TerraTreadRules.worldMaxCoordinate &&
        col >= TerraTreadRules.worldMinCoordinate &&
        col <= TerraTreadRules.worldMaxCoordinate
    }

    static func isTileInCurrentBuildArea(row: Int, col: Int) -> Bool {
        row >= TerraTreadRules.initialBuildMinCoordinate &&
        row <= TerraTreadRules.initialBuildMaxCoordinate &&
        col >= TerraTreadRules.initialBuildMinCoordinate &&
        col <= TerraTreadRules.initialBuildMaxCoordinate
    }

    static func canPlaceBuilding(_ buildings: [PlacedBuilding], type: BuildingType, row: Int, col: Int, ignoring buildingID: String? = nil) -> PlacementResult {
        let tiles = footprint(for: type, row: row, col: col)
        let isOutOfBounds = tiles.contains { tile in
            !isBuildableTile(row: tile.row, col: tile.col)
        }

        if isOutOfBounds {
            return PlacementResult(ok: false, reason: "out-of-bounds", tiles: tiles)
        }

        let isOutsideCurrentBuildArea = tiles.contains { tile in
            !isTileInCurrentBuildArea(row: tile.row, col: tile.col)
        }
        if isOutsideCurrentBuildArea {
            return PlacementResult(ok: false, reason: "locked-area", tiles: tiles)
        }

        let filteredBuildings = sanitizedBuildings(buildings).filter { $0.id != ignoring(buildingID) }
        let occupancy = Set(filteredBuildings.flatMap(footprint(for:)))
        if tiles.contains(where: occupancy.contains) {
            return PlacementResult(ok: false, reason: "occupied", tiles: tiles)
        }

        return PlacementResult(ok: true, reason: nil, tiles: tiles)
    }

    static func applyBuildAction(state: inout GameState, type: BuildingType, row: Int, col: Int) -> BuildResult {
        let summary = computeCitySummary(buildings: state.buildings)
        guard isBuildingUnlocked(type, level: summary.level) else {
            return BuildResult(ok: false, error: "locked", building: nil, tiles: [])
        }

        let definition = buildingDefinition(for: type)
        guard state.availableSteps >= definition.cost else {
            return BuildResult(ok: false, error: "insufficient-steps", building: nil, tiles: [])
        }

        let placement = canPlaceBuilding(state.buildings, type: type, row: row, col: col)
        guard placement.ok else {
            return BuildResult(ok: false, error: placement.reason, building: nil, tiles: placement.tiles)
        }

        let building = PlacedBuilding(
            id: "b-\(max(1, state.nextBuildingId))",
            type: type,
            row: row,
            col: col,
            level: 1
        )
        state.nextBuildingId = max(1, state.nextBuildingId) + 1
        state.buildings.append(building)
        state.trees.removeAll { tree in
            placement.tiles.contains(GridPoint(row: tree.row, col: tree.col))
        }
        state.availableSteps -= definition.cost
        state.lifetimeStats.built += 1

        return BuildResult(ok: true, error: nil, building: building, tiles: placement.tiles)
    }

    static func applyMoveAction(state: inout GameState, buildingID: String, row: Int, col: Int) -> MoveResult {
        guard let building = building(id: buildingID, buildings: state.buildings) else {
            return MoveResult(ok: false, error: "missing-building", buildingID: nil, tiles: [])
        }

        guard building.row != row || building.col != col else {
            return MoveResult(ok: false, error: "same-position", buildingID: nil, tiles: [])
        }

        let placement = canPlaceBuilding(state.buildings, type: building.type, row: row, col: col, ignoring: buildingID)
        guard placement.ok else {
            return MoveResult(ok: false, error: placement.reason, buildingID: nil, tiles: placement.tiles)
        }

        guard let index = state.buildings.firstIndex(where: { $0.id == buildingID }) else {
            return MoveResult(ok: false, error: "missing-building", buildingID: nil, tiles: [])
        }

        state.buildings[index].row = row
        state.buildings[index].col = col
        state.lifetimeStats.moved += 1

        return MoveResult(ok: true, error: nil, buildingID: buildingID, tiles: placement.tiles)
    }

    static func applyUpgradeAction(state: inout GameState, buildingID: String) -> UpgradeResult {
        guard let building = building(id: buildingID, buildings: state.buildings) else {
            return UpgradeResult(ok: false, error: "missing-building", upgradeCost: 0)
        }

        let upgradeCost = buildingUpgradeCost(building)
        guard upgradeCost > 0 else {
            return UpgradeResult(ok: false, error: "max-level", upgradeCost: 0)
        }

        guard state.availableSteps >= upgradeCost else {
            return UpgradeResult(ok: false, error: "insufficient-steps", upgradeCost: upgradeCost)
        }

        guard let index = state.buildings.firstIndex(where: { $0.id == buildingID }) else {
            return UpgradeResult(ok: false, error: "missing-building", upgradeCost: 0)
        }

        state.buildings[index].level = normalizedBuildingLevel(state.buildings[index].level + 1)
        state.availableSteps -= upgradeCost
        state.lifetimeStats.upgraded += 1

        return UpgradeResult(ok: true, error: nil, upgradeCost: upgradeCost)
    }

    static func applyDemolishAction(state: inout GameState, buildingID: String) -> DemolishResult {
        guard let building = building(id: buildingID, buildings: state.buildings) else {
            return DemolishResult(ok: false, error: "missing-building", refundSteps: 0)
        }

        let refundSteps = max(0, Int((Double(buildingTotalInvestment(building)) * TerraTreadRules.demolishRefundRatio).rounded()))
        state.buildings.removeAll { $0.id == building.id }
        state.availableSteps += refundSteps
        state.lifetimeStats.demolished += 1

        return DemolishResult(ok: true, error: nil, refundSteps: refundSteps)
    }

    static func applyResetAction(state: inout GameState) -> ResetResult {
        let refundedSteps = sanitizedBuildings(state.buildings).reduce(into: 0) { total, building in
            total += buildingTotalInvestment(building)
        }
        state.availableSteps += refundedSteps
        state.buildings = []
        state.trees = createInitialTrees()
        return ResetResult(ok: true, refundedSteps: refundedSteps)
    }

    static func claimContractReward(state: inout GameState, slot: ContractSlot, summary: CitySummary) -> ClaimContractResult {
        let contract: ContractRecord
        switch slot {
        case .daily: contract = state.contracts.daily
        case .weekly: contract = state.contracts.weekly
        }

        let evaluation = evaluateContract(contract, state: state, summary: summary)
        guard evaluation.completed, !evaluation.contract.claimed else {
            return ClaimContractResult(ok: false, error: "not-claimable", rewardSteps: 0, evaluation: evaluation)
        }

        state.availableSteps += evaluation.contract.rewardSteps
        switch slot {
        case .daily: state.contracts.daily.claimed = true
        case .weekly: state.contracts.weekly.claimed = true
        }

        return ClaimContractResult(ok: true, error: nil, rewardSteps: evaluation.contract.rewardSteps, evaluation: evaluation)
    }

    static func applyNativeStepSnapshot(state: inout GameState, todaySteps: Int, dayKey: String) -> StepDeltaResult {
        let normalizedSteps = max(0, todaySteps)
        let normalizedDayKey = normalizedDayKey(dayKey) ?? currentDayKey()
        let lastDayKey = state.lastNativeStepDate ?? ""
        let lastTotal = max(0, state.lastNativeStepTotal)
        let grantedSteps: Int

        if lastDayKey != normalizedDayKey {
            grantedSteps = normalizedSteps
        } else if normalizedSteps > lastTotal {
            grantedSteps = normalizedSteps - lastTotal
        } else {
            grantedSteps = 0
        }

        state.availableSteps += grantedSteps
        state.lastNativeStepDate = normalizedDayKey
        state.lastNativeStepTotal = normalizedSteps

        return StepDeltaResult(grantedSteps: grantedSteps, dayKey: normalizedDayKey, totalSteps: normalizedSteps)
    }

    static func applyServerStepEntries(state: inout GameState, entries: [BackendStepEntry]) -> ServerSyncResult {
        let lastKnownTime = timestampValue(state.lastStepTimestamp)
        var newestTimestamp = state.lastStepTimestamp
        var grantedSteps = 0

        let sortedEntries = entries.sorted { left, right in
            timestampValue(left.timestamp) < timestampValue(right.timestamp)
        }

        for entry in sortedEntries {
            let entryTime = timestampValue(entry.timestamp)
            let newestTime = timestampValue(newestTimestamp)
            guard entry.steps > 0,
                  entryTime > lastKnownTime,
                  entryTime > newestTime else {
                continue
            }

            grantedSteps += entry.steps
            newestTimestamp = entry.timestamp
        }

        if grantedSteps > 0 {
            state.availableSteps += grantedSteps
            state.lastStepTimestamp = newestTimestamp
        }

        return ServerSyncResult(grantedSteps: grantedSteps, newestTimestamp: newestTimestamp)
    }

    static func contractMetricValue(_ metric: ContractMetric, state: GameState, summary: CitySummary) -> Int {
        switch metric {
        case .built, .upgraded, .moved, .demolished:
            return state.lifetimeStats.value(for: metric)
        case .prosperity, .commerce, .happiness, .ecology, .population:
            return summary.stats.value(for: metric)
        case .cityLevel:
            return summary.level
        }
    }

    static func contractCycleKey(for slot: ContractSlot, date: Date = Date()) -> String {
        switch slot {
        case .daily:
            return localDayKey(for: date)
        case .weekly:
            return "week-of-\(startOfWeekDayKey(for: date))"
        }
    }

    static func createContract(for slot: ContractSlot, state: GameState, summary: CitySummary, date: Date = Date()) -> ContractRecord {
        let template = pickContractTemplate(for: slot, state: state, summary: summary, date: date)
        let generated = template.create(state, summary)
        let startValue = contractMetricValue(generated.metric, state: state, summary: summary)
        let targetDelta = max(1, generated.targetDelta)
        let rewardSteps = max(0, generated.rewardSteps)

        return ContractRecord(
            slot: slot,
            cycleKey: contractCycleKey(for: slot, date: date),
            templateId: template.id,
            title: template.title,
            description: generated.description,
            metricKey: generated.metric,
            rewardSteps: rewardSteps,
            startValue: startValue,
            targetDelta: targetDelta,
            targetValue: startValue + targetDelta,
            claimed: false
        )
    }

    static func nextBuildingSequence(for buildings: [PlacedBuilding]) -> Int {
        let highest = buildings.compactMap { building -> Int? in
            let prefix = "b-"
            guard building.id.hasPrefix(prefix),
                  let value = Int(building.id.dropFirst(prefix.count)) else {
                return nil
            }
            return value
        }.max() ?? 0

        return highest + 1
    }

    static func currentDayKey() -> String {
        localDayKey(for: Date())
    }

    static func localDayKey(for date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    static func startOfWeekDayKey(for date: Date) -> String {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let localDate = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: localDate)
        let offset = (weekday + 5) % 7
        let weekStart = calendar.date(byAdding: .day, value: -offset, to: localDate) ?? localDate
        return dayKeyFormatter.string(from: weekStart)
    }

    static func normalizedISODate(_ value: String) -> String? {
        guard let date = isoFormatter.date(from: value) else { return nil }
        return isoFormatter.string(from: date)
    }

    static func normalizedDayKey(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return trimmed
    }

    private static func normalizedBuildingLevel(_ level: Int) -> Int {
        min(TerraTreadRules.maxBuildingLevel, max(1, level))
    }

    private static func level(for prosperity: Int) -> Int {
        var level = 1
        for (index, threshold) in TerraTreadRules.levelThresholds.enumerated() where prosperity >= threshold {
            level = index + 1
        }
        return level
    }

    private static func currentLevelThreshold(for level: Int) -> Int {
        TerraTreadRules.levelThresholds[max(0, level - 1)]
    }

    private static func nextLevelThreshold(for level: Int) -> Int? {
        level < TerraTreadRules.levelThresholds.count ? TerraTreadRules.levelThresholds[level] : nil
    }

    private static func cityStage(for level: Int) -> CityStage {
        switch level {
        case ...1:
            .homestead
        case 2...3:
            .village
        case 4...5:
            .township
        case 6...7:
            .borough
        default:
            .city
        }
    }

    private static func cityNarrative(
        for stage: CityStage,
        stats: EffectTotals,
        buildings: [PlacedBuilding],
        nextUnlock: BuildingType?
    ) -> CityNarrative {
        let themePrefix: String = switch dominantMetric(for: stats) {
        case .commerce:
            "Market"
        case .ecology:
            "Garden"
        case .happiness:
            "Lantern"
        default:
            "Neighborly"
        }

        let title = "\(themePrefix) \(stage.settlementNoun)"
        let subtitle: String = switch stage {
        case .homestead:
            "A tiny settlement is forming from your first consistent walks."
        case .village:
            "The town is spreading into a recognizable village of homes, greens, and routines."
        case .township:
            "Older lanes and newer public spaces are starting to layer into a real town."
        case .borough:
            "Dense districts are emerging, but the earlier streets still shape the city's character."
        case .city:
            "The settlement now feels like a lived-in city with history visible in every district."
        }

        let atmosphere: String = switch dominantMetric(for: stats) {
        case .population:
            "The strongest feeling right now is neighborhood life: homes, familiar routes, and steady daily use."
        case .commerce:
            "The city is developing a main-street rhythm, with busier corners and denser activity."
        case .happiness:
            "The map leans warm and welcoming, with public spaces doing a lot of emotional work."
        case .ecology:
            "Green space is defining the tone, keeping the settlement soft, calm, and grounded."
        default:
            "Each walk is adding another quiet layer to a city that feels personal rather than optimized."
        }

        let heritage: String
        if buildings.isEmpty {
            heritage = "Your first few placements will become the founding district that later growth builds around."
        } else {
            let foundingTypes = buildings
                .sorted { buildingAgeRank(for: $0) < buildingAgeRank(for: $1) }
                .prefix(3)
                .map { buildingDefinition(for: $0.type).label.lowercased() }
            let foundingLabel = ListFormatter.localizedString(byJoining: foundingTypes)

            if buildings.count <= 3 {
                heritage = "The founding \(foundingLabel) already set the tone for the whole settlement."
            } else {
                heritage = "The founding \(foundingLabel) still sit inside newer blocks, giving the city a sense of history."
            }
        }

        let nextChapter: String
        if let nextUnlock {
            let definition = buildingDefinition(for: nextUnlock)
            nextChapter = "Keep walking to unlock the \(definition.label.lowercased()) and widen the city's next district."
        } else {
            nextChapter = "Future walks can thicken older neighborhoods with upgrades while preserving their original character."
        }

        return CityNarrative(
            title: title,
            subtitle: subtitle,
            atmosphere: atmosphere,
            heritage: heritage,
            nextChapter: nextChapter
        )
    }

    private static func dominantMetric(for stats: EffectTotals) -> ContractMetric {
        let ordered: [(ContractMetric, Int)] = [
            (.population, stats.population),
            (.commerce, stats.commerce),
            (.happiness, stats.happiness),
            (.ecology, stats.ecology),
        ]

        return ordered.max { lhs, rhs in
            if lhs.1 == rhs.1 {
                return lhs.0.rawValue > rhs.0.rawValue
            }
            return lhs.1 < rhs.1
        }?.0 ?? .population
    }

    private static func buildingAgeRank(for building: PlacedBuilding) -> Int {
        let numericParts = building.id.split(whereSeparator: { !$0.isNumber })
        guard let last = numericParts.last,
              let rank = Int(last) else {
            return .max
        }
        return rank
    }

    private static func pickContractTemplate(for slot: ContractSlot, state: GameState, summary: CitySummary, date: Date) -> ContractTemplate {
        let templates = slot == .weekly ? weeklyContractTemplates : dailyContractTemplates
        let eligibleTemplates = templates.filter { $0.isAvailable(state, summary) }
        let pool = eligibleTemplates.isEmpty ? templates : eligibleTemplates
        let cycleKey = contractCycleKey(for: slot, date: date)
        let hash = textHash("\(slot.rawValue):\(cycleKey):\(summary.level):\(summary.buildingCount)")
        return pool[hash % pool.count]
    }

    private static func hasOpenPlot(_ buildings: [PlacedBuilding]) -> Bool {
        let occupied = Set(sanitizedBuildings(buildings).flatMap(footprint(for:)))

        for row in TerraTreadRules.initialBuildMinCoordinate...TerraTreadRules.initialBuildMaxCoordinate {
            for col in TerraTreadRules.initialBuildMinCoordinate...TerraTreadRules.initialBuildMaxCoordinate where !occupied.contains(GridPoint(row: row, col: col)) {
                return true
            }
        }

        return false
    }

    private static func textHash(_ value: String) -> Int {
        value.unicodeScalars.reduce(into: 7) { hash, scalar in
            hash = (hash * 31 + Int(scalar.value)) % 2_147_483_647
        }
    }

    private static func isFootprintWithinBuildBounds(row: Int, col: Int, width: Int, height: Int) -> Bool {
        row >= TerraTreadRules.worldMinCoordinate &&
        col >= TerraTreadRules.worldMinCoordinate &&
        row + height <= TerraTreadRules.worldMaxCoordinate + 1 &&
        col + width <= TerraTreadRules.worldMaxCoordinate + 1
    }

    private static func ignoring(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dailyContractTemplates: [ContractTemplate] = [
        ContractTemplate(
            id: "builder-sprint",
            title: "Builder Sprint",
            isAvailable: { state, _ in hasOpenPlot(state.buildings) },
            create: { _, summary in
                let targetDelta = summary.level >= 5 ? 3 : 2
                return (.built, targetDelta, 150 + max(0, summary.level - 1) * 10, "Place \(targetDelta) new buildings today.")
            }
        ),
        ContractTemplate(
            id: "upgrade-push",
            title: "Upgrade Push",
            isAvailable: { state, _ in !state.buildings.isEmpty },
            create: { _, summary in
                (.upgraded, 1, 165 + max(0, summary.level - 1) * 8, "Upgrade 1 building today.")
            }
        ),
        ContractTemplate(
            id: "joy-drive",
            title: "Joy Drive",
            isAvailable: { _, _ in true },
            create: { _, summary in
                let targetDelta = summary.level >= 4 ? 8 : 6
                return (.happiness, targetDelta, 170, "Gain \(targetDelta) Happiness today.")
            }
        ),
        ContractTemplate(
            id: "green-sweep",
            title: "Green Sweep",
            isAvailable: { _, _ in true },
            create: { _, summary in
                let targetDelta = summary.level >= 4 ? 10 : 7
                return (.ecology, targetDelta, 170, "Gain \(targetDelta) Ecology today.")
            }
        ),
        ContractTemplate(
            id: "reshuffle",
            title: "Reshuffle",
            isAvailable: { state, _ in !state.buildings.isEmpty },
            create: { _, summary in
                (.moved, 1, 145 + max(0, summary.level - 1) * 6, "Move 1 building to a better plot.")
            }
        ),
    ]

    private static let weeklyContractTemplates: [ContractTemplate] = [
        ContractTemplate(
            id: "district-plan",
            title: "District Plan",
            isAvailable: { state, _ in hasOpenPlot(state.buildings) },
            create: { _, summary in
                let targetDelta = summary.level >= 6 ? 7 : 5
                return (.built, targetDelta, 420 + max(0, summary.level - 1) * 20, "Place \(targetDelta) new buildings this week.")
            }
        ),
        ContractTemplate(
            id: "renovation-week",
            title: "Renovation Week",
            isAvailable: { state, _ in !state.buildings.isEmpty },
            create: { _, summary in
                let targetDelta = summary.level >= 6 ? 4 : 3
                return (.upgraded, targetDelta, 470 + max(0, summary.level - 1) * 18, "Upgrade \(targetDelta) buildings this week.")
            }
        ),
        ContractTemplate(
            id: "prosperity-drive",
            title: "Prosperity Drive",
            isAvailable: { _, _ in true },
            create: { _, summary in
                let targetDelta = summary.level >= 6 ? 55 : 38
                return (.prosperity, targetDelta, 520, "Grow city prosperity by \(targetDelta) this week.")
            }
        ),
        ContractTemplate(
            id: "trade-wave",
            title: "Trade Wave",
            isAvailable: { _, _ in true },
            create: { _, summary in
                let targetDelta = summary.level >= 6 ? 24 : 16
                return (.commerce, targetDelta, 480, "Gain \(targetDelta) Commerce this week.")
            }
        ),
        ContractTemplate(
            id: "city-lift",
            title: "City Lift",
            isAvailable: { _, summary in summary.level < TerraTreadRules.levelThresholds.count },
            create: { _, summary in
                (.cityLevel, 1, 560 + max(0, summary.level - 1) * 20, "Reach the next city level this week.")
            }
        ),
    ]
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
