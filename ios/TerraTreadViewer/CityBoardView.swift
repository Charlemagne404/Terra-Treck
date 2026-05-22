import SwiftUI

private enum CityHUDSheet: String, Identifiable {
    case overview
    case selection

    var id: String { rawValue }
}

private let hudSurfaceFill = Color(red: 0.08, green: 0.11, blue: 0.10).opacity(0.84)
private let hudControlFill = Color(red: 0.06, green: 0.09, blue: 0.08).opacity(0.78)
private let hudStrokeColor = Color.white.opacity(0.10)
private let lightCardFill = Color(red: 0.96, green: 0.95, blue: 0.91)
private let lightCardTrack = Color.black.opacity(0.10)
private let boardTileSpacing: CGFloat = 1
private let boardBaseTileSize: CGFloat = 34
private let boardMinZoom: CGFloat = 0.35
private let boardMaxZoom: CGFloat = 2.2
private let boardCameraPaddingTiles = 8
private let boardTileOverscan = 3
private let boardInitialFocusPadding = 4

private func plotCoordinateLabel(row: Int, col: Int) -> String {
    "Plot \(row), \(col)"
}

private enum BoardRenderDetail {
    case far
    case medium
    case close

    init(tileSize: CGFloat) {
        switch tileSize {
        case ..<14:
            self = .far
        case ..<22:
            self = .medium
        default:
            self = .close
        }
    }

    var terrainPatchSize: Int {
        switch self {
        case .far: 4
        case .medium: 2
        case .close: 1
        }
    }

    var overscan: Int {
        switch self {
        case .far: 1
        case .medium: 2
        case .close: boardTileOverscan
        }
    }

    var showsTileStroke: Bool { self == .close }
    var showsRoadHints: Bool { self != .far }
    var showsGroundAccent: Bool { self == .close }
    var showsDetailedBuildings: Bool { self == .close }
    var showsDetailedTrees: Bool { self == .close }
}

private struct BoardStageInputs: Equatable {
    let buildings: [PlacedBuilding]
    let trees: [TreeTile]
    let isBuildMode: Bool
    let selectedBuildingID: String?
    let relocationBuildingID: String?
    let pendingPlacement: PendingPlacement?
}

@MainActor
private struct BoardRenderSnapshot {
    let initialFocusRect: BoardRect
    let buildingLookup: [GridPoint: PlacedBuilding]
    let buildingAnchors: [GridPoint: PlacedBuilding]
    let treeLookup: [GridPoint: TreeTile]
    let selectedTiles: Set<GridPoint>
    let movingOriginTiles: Set<GridPoint>
    let pendingTiles: Set<GridPoint>
    let pendingValid: Bool
    let isBuildMode: Bool

    init(
        initialFocusRect: BoardRect,
        buildingLookup: [GridPoint: PlacedBuilding],
        buildingAnchors: [GridPoint: PlacedBuilding],
        treeLookup: [GridPoint: TreeTile],
        selectedTiles: Set<GridPoint>,
        movingOriginTiles: Set<GridPoint>,
        pendingTiles: Set<GridPoint>,
        pendingValid: Bool,
        isBuildMode: Bool
    ) {
        self.initialFocusRect = initialFocusRect
        self.buildingLookup = buildingLookup
        self.buildingAnchors = buildingAnchors
        self.treeLookup = treeLookup
        self.selectedTiles = selectedTiles
        self.movingOriginTiles = movingOriginTiles
        self.pendingTiles = pendingTiles
        self.pendingValid = pendingValid
        self.isBuildMode = isBuildMode
    }

    static let empty = BoardRenderSnapshot(
        initialFocusRect: BoardRect.buildable,
        buildingLookup: [:],
        buildingAnchors: [:],
        treeLookup: [:],
        selectedTiles: [],
        movingOriginTiles: [],
        pendingTiles: [],
        pendingValid: false,
        isBuildMode: false
    )

    init(inputs: BoardStageInputs) {
        initialFocusRect = Self.initialFocusRect(buildings: inputs.buildings, trees: inputs.trees)

        buildingAnchors = Dictionary(
            uniqueKeysWithValues: inputs.buildings.map { (GridPoint(row: $0.row, col: $0.col), $0) }
        )
        treeLookup = Dictionary(
            uniqueKeysWithValues: inputs.trees.map { (GridPoint(row: $0.row, col: $0.col), $0) }
        )
        buildingLookup = inputs.buildings.reduce(into: [:]) { partialResult, building in
            for tile in GameEngine.footprint(for: building) {
                partialResult[tile] = building
            }
        }

        if let selectedBuildingID = inputs.selectedBuildingID,
           let building = GameEngine.building(id: selectedBuildingID, buildings: inputs.buildings) {
            selectedTiles = Set(GameEngine.footprint(for: building))
        } else {
            selectedTiles = []
        }

        if let relocationBuildingID = inputs.relocationBuildingID,
           let building = GameEngine.building(id: relocationBuildingID, buildings: inputs.buildings) {
            movingOriginTiles = Set(GameEngine.footprint(for: building))
        } else {
            movingOriginTiles = []
        }

        pendingTiles = Set(inputs.pendingPlacement?.tiles ?? [])
        pendingValid = inputs.pendingPlacement?.isValid ?? false
        isBuildMode = inputs.isBuildMode
    }

    private static func initialFocusRect(buildings: [PlacedBuilding], trees: [TreeTile]) -> BoardRect {
        let buildingTiles = GameEngine.sanitizedBuildings(buildings).flatMap(GameEngine.footprint(for:))
        let treeTiles = GameEngine.sanitizedTrees(trees).map { GridPoint(row: $0.row, col: $0.col) }
        let occupiedTiles = buildingTiles + treeTiles

        guard let first = occupiedTiles.first else {
            let defaultRect = BoardRect(
                minRow: TerraTreadRules.startingTerrainOrigin,
                maxRow: TerraTreadRules.startingTerrainOrigin + TerraTreadRules.gridSize - 1,
                minCol: TerraTreadRules.startingTerrainOrigin,
                maxCol: TerraTreadRules.startingTerrainOrigin + TerraTreadRules.gridSize - 1
            )
            return defaultRect.expanded(by: boardInitialFocusPadding).clamped(to: .buildable)
        }

        var minRow = first.row
        var maxRow = first.row
        var minCol = first.col
        var maxCol = first.col

        for point in occupiedTiles.dropFirst() {
            minRow = min(minRow, point.row)
            maxRow = max(maxRow, point.row)
            minCol = min(minCol, point.col)
            maxCol = max(maxCol, point.col)
        }

        return BoardRect(minRow: minRow, maxRow: maxRow, minCol: minCol, maxCol: maxCol)
            .expanded(by: boardInitialFocusPadding)
            .clamped(to: .buildable)
    }
}

@MainActor
private func boardStageInputs(from store: GameStore) -> BoardStageInputs {
    BoardStageInputs(
        buildings: store.state.buildings,
        trees: store.state.trees,
        isBuildMode: store.isBuildMode,
        selectedBuildingID: store.selectedBuildingID,
        relocationBuildingID: store.relocationBuildingID,
        pendingPlacement: store.pendingPlacement
    )
}

private struct BoardRect {
    let minRow: Int
    let maxRow: Int
    let minCol: Int
    let maxCol: Int

    var width: Int { maxCol - minCol + 1 }
    var height: Int { maxRow - minRow + 1 }
    var midX: CGFloat { (CGFloat(minCol) + CGFloat(maxCol) + 1) / 2 }
    var midY: CGFloat { (CGFloat(minRow) + CGFloat(maxRow) + 1) / 2 }

    func contains(row: Int, col: Int) -> Bool {
        row >= minRow && row <= maxRow && col >= minCol && col <= maxCol
    }

    func contains(_ point: GridPoint) -> Bool {
        contains(row: point.row, col: point.col)
    }

    func expanded(by padding: Int) -> BoardRect {
        BoardRect(
            minRow: minRow - padding,
            maxRow: maxRow + padding,
            minCol: minCol - padding,
            maxCol: maxCol + padding
        )
    }

    func clamped(to bounds: BoardRect) -> BoardRect {
        BoardRect(
            minRow: max(bounds.minRow, minRow),
            maxRow: min(bounds.maxRow, maxRow),
            minCol: max(bounds.minCol, minCol),
            maxCol: min(bounds.maxCol, maxCol)
        )
    }

    static let buildable = BoardRect(
        minRow: TerraTreadRules.worldMinCoordinate,
        maxRow: TerraTreadRules.worldMaxCoordinate,
        minCol: TerraTreadRules.worldMinCoordinate,
        maxCol: TerraTreadRules.worldMaxCoordinate
    )

    static let currentBuildZone = BoardRect(
        minRow: TerraTreadRules.initialBuildMinCoordinate,
        maxRow: TerraTreadRules.initialBuildMaxCoordinate,
        minCol: TerraTreadRules.initialBuildMinCoordinate,
        maxCol: TerraTreadRules.initialBuildMaxCoordinate
    )

    static let camera = BoardRect(
        minRow: TerraTreadRules.worldMinCoordinate - boardCameraPaddingTiles,
        maxRow: TerraTreadRules.worldMaxCoordinate + boardCameraPaddingTiles,
        minCol: TerraTreadRules.worldMinCoordinate - boardCameraPaddingTiles,
        maxCol: TerraTreadRules.worldMaxCoordinate + boardCameraPaddingTiles
    )
}

struct CitySceneView: View {
    let store: GameStore

    @State private var showingResetConfirmation = false
    @State private var showingDemolishConfirmation = false
    @State private var activeSheet: CityHUDSheet?

    var body: some View {
        ZStack {
            BoardStageView(store: store)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                CityTopHUD(
                    store: store,
                    openOverview: { activeSheet = .overview },
                    showResetConfirmation: { showingResetConfirmation = true }
                )

                if let pendingPlacement = store.pendingPlacement {
                    PlacementHUD(
                        pendingPlacement: pendingPlacement,
                        cancel: { store.clearPendingPlacement() },
                        confirm: { store.confirmPendingPlacement() }
                    )
                }

                Spacer(minLength: 0)

                CityBottomHUD(
                    store: store,
                    openOverview: { activeSheet = .overview },
                    openSelectionDetails: { activeSheet = .selection },
                    showResetConfirmation: { showingResetConfirmation = true },
                    showDemolishConfirmation: { showingDemolishConfirmation = true }
                )
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .overview:
                CityOverviewSheet(store: store)
            case .selection:
                CitySelectionSheet(store: store)
            }
        }
        .confirmationDialog(
            "Reset your city?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset City", role: .destructive) {
                store.resetCity()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All placed districts will be removed and their full investment will be refunded.")
        }
        .confirmationDialog(
            "Demolish this district?",
            isPresented: $showingDemolishConfirmation,
            titleVisibility: .visible
        ) {
            Button("Demolish", role: .destructive) {
                store.demolishSelectedBuilding()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will receive a partial step refund for the selected district.")
        }
    }
}

private struct BoardStageView: View {
    let store: GameStore

    @State private var cameraCenter = CGPoint.zero
    @State private var zoomScale: CGFloat = 0.75
    @State private var dragStartCenter: CGPoint?
    @State private var zoomStartScale: CGFloat?
    @State private var didConfigureInitialViewport = false
    @State private var renderSnapshot = BoardRenderSnapshot.empty

    init(store: GameStore) {
        self.store = store
        _renderSnapshot = State(initialValue: BoardRenderSnapshot(inputs: boardStageInputs(from: store)))
    }

    var body: some View {
        GeometryReader { proxy in
            let viewportSize = proxy.size
            let tileSize = tileSide(for: zoomScale)
            let tilePitch = tileSize + boardTileSpacing
            let renderDetail = BoardRenderDetail(tileSize: tileSize)
            let visibleRows = visibleRange(
                center: cameraCenter.y,
                span: viewportSize.height / tilePitch,
                lowerBound: BoardRect.camera.minRow,
                upperBound: BoardRect.camera.maxRow,
                overscan: renderDetail.overscan
            )
            let visibleColumns = visibleRange(
                center: cameraCenter.x,
                span: viewportSize.width / tilePitch,
                lowerBound: BoardRect.camera.minCol,
                upperBound: BoardRect.camera.maxCol,
                overscan: renderDetail.overscan
            )
            let boardInputs = boardStageInputs(from: store)

            ZStack {
                BoardBackdrop()
                if renderSnapshot.isBuildMode {
                    buildLimitOverlay(in: viewportSize, tilePitch: tilePitch)
                }
                BoardTileCanvas(
                    snapshot: renderSnapshot,
                    viewportSize: viewportSize,
                    tileSize: tileSize,
                    tilePitch: tilePitch,
                    cameraCenter: cameraCenter,
                    visibleRows: visibleRows,
                    visibleColumns: visibleColumns
                )
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(tapGesture(viewportSize: viewportSize, tilePitch: tilePitch))
            .simultaneousGesture(dragGesture(viewportSize: viewportSize, tilePitch: tilePitch))
            .simultaneousGesture(magnificationGesture(viewportSize: viewportSize))
            .onAppear {
                syncRenderSnapshot(with: boardInputs)
                configureInitialViewportIfNeeded(in: viewportSize)
            }
            .onChange(of: boardInputs) { _, newInputs in
                syncRenderSnapshot(with: newInputs)
            }
            .onChange(of: viewportSize) { _, newSize in
                guard newSize != .zero else { return }

                if didConfigureInitialViewport {
                    cameraCenter = clampedCameraCenter(
                        cameraCenter,
                        viewportSize: newSize,
                        tilePitch: tilePitchForZoom(zoomScale)
                    )
                } else {
                    configureInitialViewportIfNeeded(in: newSize)
                }
            }
        }
    }

    private func configureInitialViewportIfNeeded(in viewportSize: CGSize) {
        guard !didConfigureInitialViewport, viewportSize != .zero else { return }

        let focusRect = renderSnapshot.initialFocusRect
        let fittedZoom = fittedZoomScale(for: focusRect, in: viewportSize)

        zoomScale = fittedZoom
        cameraCenter = clampedCameraCenter(
            CGPoint(x: focusRect.midX, y: focusRect.midY),
            viewportSize: viewportSize,
            tilePitch: tilePitchForZoom(fittedZoom)
        )
        didConfigureInitialViewport = true
    }

    private func tileSide(for zoomScale: CGFloat) -> CGFloat {
        boardBaseTileSize * clampedZoom(zoomScale)
    }

    private func tilePitchForZoom(_ zoomScale: CGFloat) -> CGFloat {
        tileSide(for: zoomScale) + boardTileSpacing
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(boardMaxZoom, max(boardMinZoom, value))
    }

    private func fittedZoomScale(for focusRect: BoardRect, in viewportSize: CGSize) -> CGFloat {
        let basePitch = boardBaseTileSize + boardTileSpacing
        let widthScale = viewportSize.width / (CGFloat(max(1, focusRect.width)) * basePitch)
        let heightScale = viewportSize.height / (CGFloat(max(1, focusRect.height)) * basePitch)
        return clampedZoom(min(widthScale, heightScale) * 0.92)
    }

    private func visibleRange(center: CGFloat, span: CGFloat, lowerBound: Int, upperBound: Int, overscan: Int) -> ClosedRange<Int> {
        let halfSpan = span / 2
        let lower = max(lowerBound, Int(floor(center - halfSpan)) - overscan)
        let upper = min(upperBound, Int(ceil(center + halfSpan)) + overscan - 1)
        return lower...max(lower, upper)
    }

    private func clampedCameraCenter(_ proposed: CGPoint, viewportSize: CGSize, tilePitch: CGFloat) -> CGPoint {
        let halfWidth = viewportSize.width / (2 * tilePitch)
        let halfHeight = viewportSize.height / (2 * tilePitch)

        let minX = CGFloat(BoardRect.camera.minCol) + halfWidth
        let maxX = CGFloat(BoardRect.camera.maxCol + 1) - halfWidth
        let minY = CGFloat(BoardRect.camera.minRow) + halfHeight
        let maxY = CGFloat(BoardRect.camera.maxRow + 1) - halfHeight

        return CGPoint(
            x: clampedCoordinate(proposed.x, min: minX, max: maxX, fallback: BoardRect.buildable.midX),
            y: clampedCoordinate(proposed.y, min: minY, max: maxY, fallback: BoardRect.buildable.midY)
        )
    }

    private func clampedCoordinate(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat, fallback: CGFloat) -> CGFloat {
        guard lower <= upper else { return fallback }
        return Swift.min(Swift.max(value, lower), upper)
    }

    private func buildLimitOverlay(in viewportSize: CGSize, tilePitch: CGFloat) -> some View {
        let width = CGFloat(BoardRect.currentBuildZone.width) * tilePitch - boardTileSpacing
        let height = CGFloat(BoardRect.currentBuildZone.height) * tilePitch - boardTileSpacing

        return RoundedRectangle(cornerRadius: max(18, tilePitch * 0.8), style: .continuous)
            .strokeBorder(
                Color(red: 0.98, green: 0.86, blue: 0.42).opacity(0.88),
                style: StrokeStyle(
                    lineWidth: max(2, tilePitch * 0.06),
                    dash: [max(6, tilePitch * 0.55), max(4, tilePitch * 0.28)]
                )
            )
            .frame(width: width, height: height)
            .position(
                x: viewportSize.width / 2 + ((BoardRect.currentBuildZone.midX - cameraCenter.x) * tilePitch),
                y: viewportSize.height / 2 + ((BoardRect.currentBuildZone.midY - cameraCenter.y) * tilePitch)
            )
            .blendMode(.screen)
    }

    private func syncRenderSnapshot(with inputs: BoardStageInputs) {
        renderSnapshot = BoardRenderSnapshot(inputs: inputs)
    }

    private func pointAtTapLocation(_ location: CGPoint, viewportSize: CGSize, tilePitch: CGFloat) -> GridPoint? {
        guard viewportSize != .zero else { return nil }

        let col = Int(floor(cameraCenter.x + ((location.x - (viewportSize.width / 2)) / tilePitch)))
        let row = Int(floor(cameraCenter.y + ((location.y - (viewportSize.height / 2)) / tilePitch)))
        guard row >= BoardRect.camera.minRow, row <= BoardRect.camera.maxRow else { return nil }
        guard col >= BoardRect.camera.minCol, col <= BoardRect.camera.maxCol else { return nil }
        return GridPoint(row: row, col: col)
    }

    private func tapGesture(viewportSize: CGSize, tilePitch: CGFloat) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard let point = pointAtTapLocation(value.location, viewportSize: viewportSize, tilePitch: tilePitch) else {
                    return
                }
                store.handleTileTap(row: point.row, col: point.col)
            }
    }

    private func dragGesture(viewportSize: CGSize, tilePitch: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragStartCenter == nil {
                    dragStartCenter = cameraCenter
                }

                guard let dragStartCenter else { return }

                let proposed = CGPoint(
                    x: dragStartCenter.x - (value.translation.width / tilePitch),
                    y: dragStartCenter.y - (value.translation.height / tilePitch)
                )
                cameraCenter = clampedCameraCenter(proposed, viewportSize: viewportSize, tilePitch: tilePitch)
            }
            .onEnded { _ in
                dragStartCenter = nil
            }
    }

    private func magnificationGesture(viewportSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if zoomStartScale == nil {
                    zoomStartScale = zoomScale
                }

                guard let zoomStartScale else { return }

                let nextZoom = clampedZoom(zoomStartScale * value)
                zoomScale = nextZoom
                cameraCenter = clampedCameraCenter(
                    cameraCenter,
                    viewportSize: viewportSize,
                    tilePitch: tilePitchForZoom(nextZoom)
                )
            }
            .onEnded { _ in
                zoomStartScale = nil
        }
    }
}

@MainActor
private struct BoardTileCanvas: View {
    let snapshot: BoardRenderSnapshot
    let viewportSize: CGSize
    let tileSize: CGFloat
    let tilePitch: CGFloat
    let cameraCenter: CGPoint
    let visibleRows: ClosedRange<Int>
    let visibleColumns: ClosedRange<Int>

    var body: some View {
        let renderDetail = BoardRenderDetail(tileSize: tileSize)

        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, _ in
            drawTerrain(detail: renderDetail, context: &context)

            for row in visibleRows {
                for col in visibleColumns {
                    let point = GridPoint(row: row, col: col)
                    let tileRect = tileRect(for: point)
                    let tilePath = Path(tileRect)
                    let isBuildable = BoardRect.buildable.contains(point)

                    if renderDetail.showsTileStroke {
                        context.stroke(tilePath, with: .color(Color.black.opacity(isBuildable ? 0.05 : 0.09)), lineWidth: max(0.35, tileSize * 0.013))
                    }

                    if let building = snapshot.buildingLookup[point] {
                        drawBuildingTile(
                            for: building,
                            at: point,
                            in: tileRect,
                            moving: snapshot.movingOriginTiles.contains(point),
                            detail: renderDetail,
                            context: &context
                        )
                    } else if let tree = snapshot.treeLookup[point] {
                        drawTreeMarker(for: tree, in: tileRect, detail: renderDetail, context: &context)
                    } else if isBuildable {
                        if renderDetail.showsRoadHints {
                            drawRoadTile(at: point, in: tileRect, detail: renderDetail, context: &context)
                        }
                        if renderDetail.showsGroundAccent {
                            drawGroundAccent(at: point, in: tileRect, context: &context)
                        }
                    } else {
                        drawFrontierTile(at: point, in: tileRect, detail: renderDetail, context: &context)
                    }

                    if snapshot.isBuildMode && !BoardRect.currentBuildZone.contains(point) {
                        context.fill(tilePath, with: .color(Color(red: 0.12, green: 0.15, blue: 0.16).opacity(0.52)))
                    }

                    if snapshot.selectedTiles.contains(point) {
                        context.stroke(tilePath, with: .color(Color.white.opacity(0.95)), lineWidth: max(2, tileSize * 0.08))
                    }

                    if snapshot.pendingTiles.contains(point) {
                        context.stroke(
                            tilePath,
                            with: .color(snapshot.pendingValid ? Color(red: 0.98, green: 0.86, blue: 0.42) : Color(red: 0.84, green: 0.26, blue: 0.23)),
                            lineWidth: max(2.5, tileSize * 0.09)
                        )
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("City map")
        .accessibilityHint("Pan to move around the city and tap a plot to interact with it.")
    }

    private func tileOrigin(for point: GridPoint) -> CGPoint {
        CGPoint(
            x: viewportSize.width / 2 + ((CGFloat(point.col) - cameraCenter.x) * tilePitch) + (boardTileSpacing / 2),
            y: viewportSize.height / 2 + ((CGFloat(point.row) - cameraCenter.y) * tilePitch) + (boardTileSpacing / 2)
        )
    }

    private func tileRect(for point: GridPoint) -> CGRect {
        CGRect(origin: tileOrigin(for: point), size: CGSize(width: tileSize, height: tileSize))
    }

    private func drawTerrain(detail: BoardRenderDetail, context: inout GraphicsContext) {
        let patchSize = detail.terrainPatchSize
        let alignedMinRow = floorDiv(visibleRows.lowerBound, by: patchSize) * patchSize
        let alignedMinCol = floorDiv(visibleColumns.lowerBound, by: patchSize) * patchSize

        for row in stride(from: alignedMinRow, through: visibleRows.upperBound, by: patchSize) {
            let patchMinRow = max(row, visibleRows.lowerBound)
            let patchMaxRow = min(row + patchSize - 1, visibleRows.upperBound)

            for col in stride(from: alignedMinCol, through: visibleColumns.upperBound, by: patchSize) {
                let patchMinCol = max(col, visibleColumns.lowerBound)
                let patchMaxCol = min(col + patchSize - 1, visibleColumns.upperBound)
                let spanRows = patchMaxRow - patchMinRow + 1
                let spanCols = patchMaxCol - patchMinCol + 1
                let samplePoint = GridPoint(row: row, col: col)
                let origin = tileOrigin(for: GridPoint(row: patchMinRow, col: patchMinCol))
                let patchRect = CGRect(
                    x: origin.x,
                    y: origin.y,
                    width: (CGFloat(spanCols) * tilePitch) - boardTileSpacing,
                    height: (CGFloat(spanRows) * tilePitch) - boardTileSpacing
                )

                context.fill(
                    Path(patchRect),
                    with: .color(boardTileBackground(for: samplePoint, sampleScale: patchSize))
                )
            }
        }
    }

    private func drawBuildingTile(
        for building: PlacedBuilding,
        at point: GridPoint,
        in tileRect: CGRect,
        moving: Bool,
        detail: BoardRenderDetail,
        context: inout GraphicsContext
    ) {
        let palette = boardBuildingPalette(for: building.type, level: building.level)
        let opacity = moving ? 0.54 : 1.0
        let localRow = point.row - building.row
        let localCol = point.col - building.col
        let outerRect = tileRect.insetBy(dx: max(1.1, tileSize * 0.05), dy: max(1.1, tileSize * 0.05))
        let innerRect = outerRect.insetBy(dx: max(0.9, tileSize * 0.07), dy: max(0.9, tileSize * 0.07))
        let isAnchor = snapshot.buildingAnchors[point] != nil

        context.fill(
            RoundedRectangle(cornerRadius: max(4, tileSize * 0.18), style: .continuous).path(in: outerRect),
            with: .color(palette.foundation.opacity(opacity))
        )

        guard detail.showsDetailedBuildings else {
            drawSimplifiedBuildingTile(
                type: building.type,
                in: innerRect,
                palette: palette,
                opacity: opacity,
                anchor: isAnchor,
                context: &context
            )
            return
        }

        let definition = GameEngine.buildingDefinition(for: building.type)

        switch building.type {
        case .park:
            drawParkTile(in: innerRect, localRow: localRow, localCol: localCol, palette: palette, context: &context, opacity: opacity)
        case .orchard:
            drawOrchardTile(in: innerRect, localRow: localRow, localCol: localCol, palette: palette, context: &context, opacity: opacity)
        case .plaza:
            drawPlazaTile(in: innerRect, palette: palette, context: &context, opacity: opacity)
        default:
            drawBuiltStructureTile(
                for: building,
                definition: definition,
                in: innerRect,
                context: &context,
                palette: palette,
                opacity: opacity,
                anchor: isAnchor
            )
        }

        if isAnchor {
            drawBuildingBadge(
                for: building,
                definition: definition,
                in: outerRect,
                palette: palette,
                context: &context,
                opacity: opacity
            )
        }
    }

    private func drawTreeMarker(
        for tree: TreeTile,
        in tileRect: CGRect,
        detail: BoardRenderDetail,
        context: inout GraphicsContext
    ) {
        guard detail.showsDetailedTrees else {
            let canopyColor = tree.imageIndex % 2 == 0 ? Color(red: 0.20, green: 0.42, blue: 0.22) : Color(red: 0.29, green: 0.50, blue: 0.26)
            let canopyRect = tileRect.insetBy(dx: tileSize * 0.20, dy: tileSize * 0.20)
            context.fill(Path(ellipseIn: canopyRect), with: .color(canopyColor.opacity(0.92)))
            return
        }

        let trunkRect = CGRect(
            x: tileRect.midX - (tileSize * 0.07),
            y: tileRect.midY - (tileSize * 0.02),
            width: tileSize * 0.14,
            height: tileSize * 0.26
        )
        context.fill(RoundedRectangle(cornerRadius: tileSize * 0.05).path(in: trunkRect), with: .color(Color(red: 0.39, green: 0.25, blue: 0.16)))

        let canopyColor = tree.imageIndex % 2 == 0 ? Color(red: 0.17, green: 0.43, blue: 0.22) : Color(red: 0.26, green: 0.51, blue: 0.24)
        let canopyOffsets: [CGPoint] = [
            CGPoint(x: -0.15, y: -0.08),
            CGPoint(x: 0.16, y: -0.10),
            CGPoint(x: 0.00, y: -0.24),
        ]

        for offset in canopyOffsets {
            let canopyRect = CGRect(
                x: tileRect.midX + (tileSize * offset.x) - (tileSize * 0.18),
                y: tileRect.midY + (tileSize * offset.y) - (tileSize * 0.18),
                width: tileSize * 0.36,
                height: tileSize * 0.36
            )
            context.fill(Path(ellipseIn: canopyRect), with: .color(canopyColor))
        }
    }

    private func drawRoadTile(at point: GridPoint, in tileRect: CGRect, detail: BoardRenderDetail, context: inout GraphicsContext) {
        let connections = roadConnections(for: point)
        guard connections.count > 0 else { return }

        let roadColor = Color(red: 0.63, green: 0.56, blue: 0.47).opacity(detail == .medium ? 0.52 : 0.68)
        let coreRect = CGRect(
            x: tileRect.midX - (tileSize * 0.14),
            y: tileRect.midY - (tileSize * 0.14),
            width: tileSize * 0.28,
            height: tileSize * 0.28
        )
        context.fill(Path(ellipseIn: coreRect), with: .color(roadColor))

        if connections.north {
            context.fill(Path(CGRect(x: tileRect.midX - (tileSize * 0.08), y: tileRect.minY, width: tileSize * 0.16, height: tileSize * 0.50)), with: .color(roadColor))
        }
        if connections.south {
            context.fill(Path(CGRect(x: tileRect.midX - (tileSize * 0.08), y: tileRect.midY, width: tileSize * 0.16, height: tileSize * 0.50)), with: .color(roadColor))
        }
        if connections.west {
            context.fill(Path(CGRect(x: tileRect.minX, y: tileRect.midY - (tileSize * 0.08), width: tileSize * 0.50, height: tileSize * 0.16)), with: .color(roadColor))
        }
        if connections.east {
            context.fill(Path(CGRect(x: tileRect.midX, y: tileRect.midY - (tileSize * 0.08), width: tileSize * 0.50, height: tileSize * 0.16)), with: .color(roadColor))
        }
    }

    private func drawGroundAccent(at point: GridPoint, in tileRect: CGRect, context: inout GraphicsContext) {
        let seed = abs((point.row * 31) + (point.col * 17))
        guard seed % 5 == 0 else { return }

        let accentRect = CGRect(
            x: tileRect.minX + (tileSize * 0.16),
            y: tileRect.minY + (tileSize * 0.18),
            width: tileSize * 0.18,
            height: tileSize * 0.10
        )
        context.fill(
            RoundedRectangle(cornerRadius: tileSize * 0.05, style: .continuous).path(in: accentRect),
            with: .color(Color.white.opacity(0.08))
        )
    }

    private func drawFrontierTile(at point: GridPoint, in tileRect: CGRect, detail: BoardRenderDetail, context: inout GraphicsContext) {
        guard detail != .far else { return }

        let hueShift = Double(((point.row * 7) + (point.col * 5)) % 6) * 0.003
        let wash = Color(hue: 0.54 + hueShift, saturation: 0.26, brightness: 0.34)
        context.fill(
            RoundedRectangle(cornerRadius: max(3, tileSize * 0.14), style: .continuous).path(in: tileRect.insetBy(dx: tileSize * 0.12, dy: tileSize * 0.12)),
            with: .color(wash.opacity(detail == .medium ? 0.22 : 0.35))
        )
    }

    private func drawSimplifiedBuildingTile(
        type: BuildingType,
        in rect: CGRect,
        palette: BoardBuildingPalette,
        opacity: Double,
        anchor: Bool,
        context: inout GraphicsContext
    ) {
        let bodyRect = rect.insetBy(dx: tileSize * 0.03, dy: tileSize * 0.03)
        context.fill(
            RoundedRectangle(cornerRadius: max(2, tileSize * 0.10), style: .continuous).path(in: bodyRect),
            with: .color(palette.wall.opacity(opacity))
        )

        switch type {
        case .park, .orchard:
            let canopyRect = bodyRect.insetBy(dx: bodyRect.width * 0.18, dy: bodyRect.height * 0.18)
            context.fill(Path(ellipseIn: canopyRect), with: .color(palette.roof.opacity(opacity)))
        case .plaza:
            let plazaRect = bodyRect.insetBy(dx: bodyRect.width * 0.20, dy: bodyRect.height * 0.20)
            context.fill(RoundedRectangle(cornerRadius: tileSize * 0.06, style: .continuous).path(in: plazaRect), with: .color(palette.accent.opacity(opacity)))
        default:
            let roofRect = CGRect(
                x: bodyRect.minX + bodyRect.width * 0.10,
                y: bodyRect.minY + bodyRect.height * 0.12,
                width: bodyRect.width * 0.80,
                height: bodyRect.height * 0.24
            )
            context.fill(RoundedRectangle(cornerRadius: tileSize * 0.08, style: .continuous).path(in: roofRect), with: .color(palette.roof.opacity(opacity)))
        }

        if anchor && tileSize >= 14 {
            let accentRect = CGRect(
                x: bodyRect.minX + bodyRect.width * 0.14,
                y: bodyRect.maxY - (bodyRect.height * 0.18),
                width: bodyRect.width * 0.72,
                height: bodyRect.height * 0.10
            )
            context.fill(RoundedRectangle(cornerRadius: tileSize * 0.05, style: .continuous).path(in: accentRect), with: .color(Color.white.opacity(0.16 * opacity)))
        }
    }

    private func drawParkTile(
        in rect: CGRect,
        localRow: Int,
        localCol: Int,
        palette: BoardBuildingPalette,
        context: inout GraphicsContext,
        opacity: Double
    ) {
        context.fill(RoundedRectangle(cornerRadius: tileSize * 0.18, style: .continuous).path(in: rect), with: .color(palette.wall.opacity(opacity)))

        let canopyRadius = tileSize * 0.11
        let treeCenters = [
            CGPoint(x: rect.minX + rect.width * 0.34, y: rect.minY + rect.height * 0.36),
            CGPoint(x: rect.minX + rect.width * 0.68, y: rect.minY + rect.height * 0.62),
        ]
        for center in treeCenters {
            let canopyRect = CGRect(x: center.x - canopyRadius, y: center.y - canopyRadius, width: canopyRadius * 2, height: canopyRadius * 2)
            context.fill(Path(ellipseIn: canopyRect), with: .color(palette.roof.opacity(opacity)))
        }

        if localRow == 0 && localCol == 0 {
            let pathRect = CGRect(x: rect.minX + rect.width * 0.22, y: rect.midY - (tileSize * 0.04), width: rect.width * 0.56, height: tileSize * 0.08)
            context.fill(RoundedRectangle(cornerRadius: tileSize * 0.04).path(in: pathRect), with: .color(palette.accent.opacity(opacity)))
        }
    }

    private func drawOrchardTile(
        in rect: CGRect,
        localRow: Int,
        localCol: Int,
        palette: BoardBuildingPalette,
        context: inout GraphicsContext,
        opacity: Double
    ) {
        context.fill(RoundedRectangle(cornerRadius: tileSize * 0.18, style: .continuous).path(in: rect), with: .color(palette.wall.opacity(opacity)))

        let centers = [
            CGPoint(x: rect.minX + rect.width * 0.32, y: rect.minY + rect.height * 0.34),
            CGPoint(x: rect.minX + rect.width * 0.68, y: rect.minY + rect.height * 0.34),
            CGPoint(x: rect.minX + rect.width * 0.32, y: rect.minY + rect.height * 0.68),
            CGPoint(x: rect.minX + rect.width * 0.68, y: rect.minY + rect.height * 0.68),
        ]
        for center in centers {
            let canopyRect = CGRect(x: center.x - (tileSize * 0.085), y: center.y - (tileSize * 0.085), width: tileSize * 0.17, height: tileSize * 0.17)
            context.fill(Path(ellipseIn: canopyRect), with: .color(palette.roof.opacity(opacity)))
        }

        if localRow == 0 && localCol == 0 {
            let pathRect = CGRect(x: rect.midX - (tileSize * 0.03), y: rect.minY, width: tileSize * 0.06, height: rect.height)
            context.fill(RoundedRectangle(cornerRadius: tileSize * 0.03).path(in: pathRect), with: .color(palette.accent.opacity(opacity)))
        }
    }

    private func drawPlazaTile(
        in rect: CGRect,
        palette: BoardBuildingPalette,
        context: inout GraphicsContext,
        opacity: Double
    ) {
        context.fill(RoundedRectangle(cornerRadius: tileSize * 0.18, style: .continuous).path(in: rect), with: .color(palette.wall.opacity(opacity)))

        let fountainRect = CGRect(
            x: rect.midX - (tileSize * 0.10),
            y: rect.midY - (tileSize * 0.10),
            width: tileSize * 0.20,
            height: tileSize * 0.20
        )
        context.fill(Path(ellipseIn: fountainRect), with: .color(palette.roof.opacity(opacity)))
        context.stroke(Path(ellipseIn: fountainRect), with: .color(Color.white.opacity(0.35 * opacity)), lineWidth: max(0.8, tileSize * 0.025))
    }

    private func drawBuiltStructureTile(
        for building: PlacedBuilding,
        definition: BuildingDefinition,
        in rect: CGRect,
        context: inout GraphicsContext,
        palette: BoardBuildingPalette,
        opacity: Double,
        anchor: Bool
    ) {
        context.fill(RoundedRectangle(cornerRadius: tileSize * 0.16, style: .continuous).path(in: rect), with: .color(palette.wall.opacity(opacity)))

        let roofRect = CGRect(
            x: rect.minX + rect.width * 0.08,
            y: rect.minY + rect.height * 0.08,
            width: rect.width * 0.84,
            height: rect.height * 0.30
        )
        context.fill(RoundedRectangle(cornerRadius: tileSize * 0.12, style: .continuous).path(in: roofRect), with: .color(palette.roof.opacity(opacity)))

        let windowCount = tileSize > 24 ? max(1, min(3, definition.width + definition.height - 1)) : 1
        for index in 0..<windowCount {
            let offset = CGFloat(index) - CGFloat(windowCount - 1) / 2
            let windowRect = CGRect(
                x: rect.midX + (offset * tileSize * 0.16) - (tileSize * 0.04),
                y: rect.midY - (tileSize * 0.03),
                width: tileSize * 0.08,
                height: tileSize * 0.11
            )
            context.fill(RoundedRectangle(cornerRadius: tileSize * 0.025, style: .continuous).path(in: windowRect), with: .color(palette.light.opacity(opacity)))
        }

        let doorRect = CGRect(
            x: rect.midX - (tileSize * 0.045),
            y: rect.maxY - (tileSize * 0.18),
            width: tileSize * 0.09,
            height: tileSize * 0.16
        )
        context.fill(RoundedRectangle(cornerRadius: tileSize * 0.03, style: .continuous).path(in: doorRect), with: .color(palette.accent.opacity(opacity)))

        if anchor && tileSize > 22 {
            let awningRect = CGRect(
                x: rect.minX + rect.width * 0.14,
                y: rect.minY + rect.height * 0.38,
                width: rect.width * 0.72,
                height: tileSize * 0.06
            )
            context.fill(RoundedRectangle(cornerRadius: tileSize * 0.03, style: .continuous).path(in: awningRect), with: .color(Color.white.opacity(0.18 * opacity)))
        }
    }

    private func drawBuildingBadge(
        for building: PlacedBuilding,
        definition: BuildingDefinition,
        in rect: CGRect,
        palette: BoardBuildingPalette,
        context: inout GraphicsContext,
        opacity: Double
    ) {
        let badgeRect = CGRect(
            x: rect.minX + (tileSize * 0.10),
            y: rect.minY + (tileSize * 0.10),
            width: tileSize * 0.26,
            height: tileSize * 0.26
        )
        context.fill(
            Path(ellipseIn: badgeRect),
            with: .color(Color.black.opacity(0.18 * opacity))
        )

        var icon = context.resolve(
            Text(Image(systemName: definition.icon))
                .font(.system(size: max(7, tileSize * 0.12), weight: .black))
        )
        icon.shading = .color(.white.opacity(opacity))
        context.draw(icon, at: CGPoint(x: badgeRect.midX, y: badgeRect.midY), anchor: .center)

        for levelIndex in 0..<max(0, building.level - 1) {
            let pipRect = CGRect(
                x: rect.maxX - (tileSize * 0.13) - (CGFloat(levelIndex) * tileSize * 0.10),
                y: rect.minY + (tileSize * 0.12),
                width: tileSize * 0.06,
                height: tileSize * 0.06
            )
            context.fill(Path(ellipseIn: pipRect), with: .color(palette.light.opacity(opacity)))
        }
    }

    private func roadConnections(for point: GridPoint) -> RoadConnections {
        RoadConnections(
            north: snapshot.buildingLookup[GridPoint(row: point.row - 1, col: point.col)] != nil,
            south: snapshot.buildingLookup[GridPoint(row: point.row + 1, col: point.col)] != nil,
            east: snapshot.buildingLookup[GridPoint(row: point.row, col: point.col + 1)] != nil,
            west: snapshot.buildingLookup[GridPoint(row: point.row, col: point.col - 1)] != nil
        )
    }
}

private struct BoardBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.31, green: 0.24, blue: 0.18),
                    Color(red: 0.43, green: 0.35, blue: 0.24),
                    Color(red: 0.63, green: 0.55, blue: 0.38),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color(red: 0.99, green: 0.89, blue: 0.70).opacity(0.28),
                    Color.clear,
                ],
                center: .top,
                startRadius: 0,
                endRadius: 420
            )

            LinearGradient(
                colors: [
                    Color.black.opacity(0.16),
                    Color.clear,
                    Color.black.opacity(0.28),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

private struct RoadConnections {
    let north: Bool
    let south: Bool
    let east: Bool
    let west: Bool

    var count: Int {
        [north, south, east, west].filter(\.self).count
    }
}

private struct BoardBuildingPalette {
    let foundation: Color
    let wall: Color
    let roof: Color
    let accent: Color
    let light: Color
}

@MainActor
private func boardTileBackground(for point: GridPoint, sampleScale: Int = 1) -> Color {
    let macroScale = max(4, sampleScale * 5)
    let microScale = max(2, sampleScale * 2)
    let macroNoise = boardNoise(row: floorDiv(point.row, by: macroScale), col: floorDiv(point.col, by: macroScale), salt: 17)
    let microNoise = boardNoise(row: floorDiv(point.row, by: microScale), col: floorDiv(point.col, by: microScale), salt: 59)

    guard BoardRect.buildable.contains(point) else {
        let brightness = 0.25 + ((macroNoise - 0.5) * 0.05) + ((microNoise - 0.5) * 0.02)
        let saturation = 0.19 + ((microNoise - 0.5) * 0.03)
        return Color(hue: 0.56, saturation: saturation, brightness: brightness)
    }

    let brightness = 0.57 + ((macroNoise - 0.5) * 0.08) + ((microNoise - 0.5) * 0.03)
    let saturation = 0.30 + ((microNoise - 0.5) * 0.04)
    return Color(hue: 0.27, saturation: saturation, brightness: brightness)
}

private func floorDiv(_ value: Int, by divisor: Int) -> Int {
    precondition(divisor > 0, "Divisor must be positive.")
    let quotient = value / divisor
    let remainder = value % divisor
    return remainder == 0 || value >= 0 ? quotient : quotient - 1
}

private func boardNoise(row: Int, col: Int, salt: Int) -> Double {
    var hash = UInt64(bitPattern: Int64(row &* 374_761_393))
    hash ^= UInt64(bitPattern: Int64(col &* 668_265_263))
    hash ^= UInt64(bitPattern: Int64(salt &* 2_147_483_647))
    hash = (hash ^ (hash >> 13)) &* 1_274_126_177
    hash ^= hash >> 16
    return Double(hash & 0xffff) / Double(0xffff)
}

@MainActor
private func boardBuildingPalette(for type: BuildingType, level: Int) -> BoardBuildingPalette {
    let upgradeShift = Double(max(0, level - 1)) * 0.04

    let base: BoardBuildingPalette = switch type {
    case .house:
        BoardBuildingPalette(
            foundation: Color(red: 0.55, green: 0.41, blue: 0.30),
            wall: Color(red: 0.85, green: 0.69, blue: 0.52),
            roof: Color(red: 0.70, green: 0.37, blue: 0.28),
            accent: Color(red: 0.47, green: 0.26, blue: 0.18),
            light: Color(red: 0.98, green: 0.85, blue: 0.58)
        )
    case .park:
        BoardBuildingPalette(
            foundation: Color(red: 0.31, green: 0.48, blue: 0.26),
            wall: Color(red: 0.56, green: 0.74, blue: 0.45),
            roof: Color(red: 0.26, green: 0.46, blue: 0.24),
            accent: Color(red: 0.74, green: 0.67, blue: 0.50),
            light: Color(red: 0.88, green: 0.92, blue: 0.71)
        )
    case .shop:
        BoardBuildingPalette(
            foundation: Color(red: 0.46, green: 0.34, blue: 0.26),
            wall: Color(red: 0.70, green: 0.61, blue: 0.52),
            roof: Color(red: 0.34, green: 0.47, blue: 0.61),
            accent: Color(red: 0.82, green: 0.53, blue: 0.34),
            light: Color(red: 0.97, green: 0.83, blue: 0.58)
        )
    case .plaza:
        BoardBuildingPalette(
            foundation: Color(red: 0.54, green: 0.51, blue: 0.46),
            wall: Color(red: 0.83, green: 0.79, blue: 0.71),
            roof: Color(red: 0.53, green: 0.63, blue: 0.69),
            accent: Color(red: 0.70, green: 0.58, blue: 0.42),
            light: Color(red: 0.96, green: 0.90, blue: 0.78)
        )
    case .orchard:
        BoardBuildingPalette(
            foundation: Color(red: 0.41, green: 0.35, blue: 0.22),
            wall: Color(red: 0.70, green: 0.76, blue: 0.45),
            roof: Color(red: 0.32, green: 0.54, blue: 0.25),
            accent: Color(red: 0.86, green: 0.62, blue: 0.30),
            light: Color(red: 0.99, green: 0.84, blue: 0.55)
        )
    case .school:
        BoardBuildingPalette(
            foundation: Color(red: 0.47, green: 0.33, blue: 0.25),
            wall: Color(red: 0.80, green: 0.73, blue: 0.61),
            roof: Color(red: 0.48, green: 0.29, blue: 0.25),
            accent: Color(red: 0.28, green: 0.52, blue: 0.46),
            light: Color(red: 0.99, green: 0.87, blue: 0.62)
        )
    case .market:
        BoardBuildingPalette(
            foundation: Color(red: 0.49, green: 0.34, blue: 0.25),
            wall: Color(red: 0.80, green: 0.67, blue: 0.51),
            roof: Color(red: 0.66, green: 0.28, blue: 0.22),
            accent: Color(red: 0.84, green: 0.61, blue: 0.31),
            light: Color(red: 0.98, green: 0.84, blue: 0.55)
        )
    case .library:
        BoardBuildingPalette(
            foundation: Color(red: 0.42, green: 0.34, blue: 0.29),
            wall: Color(red: 0.73, green: 0.69, blue: 0.63),
            roof: Color(red: 0.31, green: 0.36, blue: 0.49),
            accent: Color(red: 0.55, green: 0.42, blue: 0.30),
            light: Color(red: 0.99, green: 0.88, blue: 0.68)
        )
    case .workshop:
        BoardBuildingPalette(
            foundation: Color(red: 0.38, green: 0.33, blue: 0.29),
            wall: Color(red: 0.66, green: 0.61, blue: 0.56),
            roof: Color(red: 0.41, green: 0.42, blue: 0.38),
            accent: Color(red: 0.67, green: 0.49, blue: 0.30),
            light: Color(red: 0.95, green: 0.82, blue: 0.60)
        )
    }

    return BoardBuildingPalette(
        foundation: base.foundation.opacity(0.88 + upgradeShift),
        wall: base.wall.opacity(0.96 + (upgradeShift * 0.6)),
        roof: base.roof.opacity(0.94 + (upgradeShift * 0.4)),
        accent: base.accent.opacity(0.90 + (upgradeShift * 0.5)),
        light: base.light
    )
}

private struct CityTopHUD: View {
    let store: GameStore
    let openOverview: () -> Void
    let showResetConfirmation: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HUDCompactSurface {
                HStack(spacing: 10) {
                    Label(store.citySummary.stage.label, systemImage: "leaf.circle.fill")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.white)

                    HUDProgressBar(progress: store.citySummary.progressPercent / 100)
                        .frame(width: 82, height: 6)

                    if let nextUnlock = store.citySummary.nextUnlock {
                        Image(systemName: GameEngine.buildingDefinition(for: nextUnlock).icon)
                            .font(.caption.weight(.black))
                            .foregroundStyle(Color(red: 0.98, green: 0.86, blue: 0.49))
                            .accessibilityLabel("Next unlock")
                    }
                }
            }

            Spacer(minLength: 0)

            StepBankChip(steps: store.state.availableSteps)

            Menu {
                Button {
                    openOverview()
                } label: {
                    Label("City Details", systemImage: "chart.bar.fill")
                }

                Button(role: .destructive) {
                    showResetConfirmation()
                } label: {
                    Label("Reset City", systemImage: "trash")
                }
            } label: {
                HUDIconButtonChrome(symbol: "ellipsis.circle.fill")
            }
        }
    }
}

private struct CityBottomHUD: View {
    let store: GameStore
    let openOverview: () -> Void
    let openSelectionDetails: () -> Void
    let showResetConfirmation: () -> Void
    let showDemolishConfirmation: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if store.isBuildMode {
                BuildModeHUD(
                    store: store,
                    openSelectionDetails: openSelectionDetails
                )
            } else if store.selectedBuilding != nil {
                CompactInspectorHUD(
                    store: store,
                    openSelectionDetails: openSelectionDetails,
                    showDemolishConfirmation: showDemolishConfirmation
                )
            }

            ActionDock(
                store: store,
                openOverview: openOverview,
                openSelectionDetails: openSelectionDetails,
                showResetConfirmation: showResetConfirmation
            )
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CompactInspectorHUD: View {
    let store: GameStore
    let openSelectionDetails: () -> Void
    let showDemolishConfirmation: () -> Void

    var body: some View {
        HUDCompactSurface {
            if let building = store.selectedBuilding {
                let definition = GameEngine.buildingDefinition(for: building.type)
                let upgradeCost = GameEngine.buildingUpgradeCost(building)
                let effectText = (
                    store.selectedBuildingBreakdown?.totalEffects ??
                        definition.baseEffects.scaled(
                            multiplier: GameEngine.buildingLevelMultiplier(building.level)
                        )
                ).formatted(short: true)

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: definition.icon)
                                .font(.caption.weight(.black))
                                .foregroundStyle(Color(red: 0.98, green: 0.86, blue: 0.49))

                            Text(definition.label)
                                .font(.subheadline.weight(.black))
                                .foregroundStyle(.white)

                            Text("Lv\(building.level)")
                                .font(.caption2.weight(.black))
                                .foregroundStyle(.white.opacity(0.72))
                        }

                        Text(effectText)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Button {
                        store.upgradeSelectedBuilding()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.circle.fill")

                            if upgradeCost > 0 {
                                Text("\(upgradeCost)")
                            }
                        }
                    }
                    .buttonStyle(HUDPillButtonStyle(tone: .accent))
                    .disabled(upgradeCost == 0 || store.state.availableSteps < upgradeCost || store.pendingPlacement != nil)
                    .accessibilityLabel(upgradeCost > 0 ? "Upgrade for \(upgradeCost) steps" : "Upgrade unavailable")

                    Menu {
                        Button {
                            openSelectionDetails()
                        } label: {
                            Label("District Details", systemImage: "info.circle")
                        }

                        Button {
                            store.beginRelocationForSelectedBuilding()
                        } label: {
                            Label(
                                store.relocationBuildingID == building.id ? "Cancel Move" : "Move",
                                systemImage: "arrow.up.left.and.arrow.down.right"
                            )
                        }

                        Button(role: .destructive) {
                            showDemolishConfirmation()
                        } label: {
                            Label("Demolish", systemImage: "trash")
                        }
                    } label: {
                        HUDIconButtonChrome(symbol: "ellipsis")
                    }
                }
            }
        }
    }
}

private struct BuildModeHUD: View {
    let store: GameStore
    let openSelectionDetails: () -> Void

    private var unlockedDefinitions: [BuildingDefinition] {
        GameEngine.buildingEntries().filter {
            GameEngine.isBuildingUnlocked($0.type, level: store.citySummary.level)
        }
    }

    var body: some View {
        HUDCompactSurface {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Label("Build Mode", systemImage: "hammer.fill")
                        .font(.caption.weight(.black))
                        .foregroundStyle(.white)

                    Spacer(minLength: 0)

                    if store.selectedBuildType != nil {
                        Button {
                            openSelectionDetails()
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(HUDIconButtonStyle(tone: .glass))
                        .accessibilityLabel("Selection details")
                    }

                    Button {
                        store.exitBuildMode()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(HUDIconButtonStyle(tone: .glass))
                    .accessibilityLabel("Exit build mode")
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(unlockedDefinitions) { definition in
                            BuildOptionChip(
                                definition: definition,
                                isSelected: store.selectedBuildType == definition.type,
                                isAffordable: store.state.availableSteps >= definition.cost,
                                select: { store.startBuilding(definition.type) }
                            )
                        }
                    }
                    .padding(.horizontal, 1)
                }

                Text(buildModeHint)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(2)
            }
        }
    }

    private var buildModeHint: String {
        if let selectedBuildType = store.selectedBuildType {
            let definition = GameEngine.buildingDefinition(for: selectedBuildType)
            let missingSteps = max(0, definition.cost - store.state.availableSteps)
            if missingSteps > 0 {
                return "\(definition.label) costs \(definition.cost) steps. Need \(missingSteps) more before you can place it."
            }
            return "\(definition.label) selected. Tap inside the highlighted 20×20 core to preview a placement."
        }

        return "Choose a district, then tap inside the highlighted 20×20 core to place it."
    }
}

private struct BuildOptionChip: View {
    let definition: BuildingDefinition
    let isSelected: Bool
    let isAffordable: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: definition.icon)
                        .font(.caption.weight(.black))
                    Text(definition.label)
                        .font(.caption.weight(.black))
                        .lineLimit(1)
                }

                Text("\(definition.cost) steps")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(foregroundColor.opacity(isAffordable || isSelected ? 0.82 : 0.62))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(minWidth: 108, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(borderColor)
            )
            .foregroundStyle(foregroundColor)
            .opacity(isAffordable || isSelected ? 1 : 0.72)
        }
        .buttonStyle(.plain)
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color(red: 0.96, green: 0.79, blue: 0.33)
        }
        return hudControlFill
    }

    private var foregroundColor: Color {
        if isSelected {
            return Color(red: 0.15, green: 0.18, blue: 0.16)
        }
        return .white
    }

    private var borderColor: Color {
        if isSelected {
            return Color.clear
        }
        return hudStrokeColor
    }
}

private struct PlacementHUD: View {
    let pendingPlacement: PendingPlacement
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        HUDCompactSurface {
            HStack(spacing: 10) {
                Label(placementText, systemImage: pendingPlacement.isValid ? "scope" : "xmark.octagon.fill")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button(action: cancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(HUDIconButtonStyle(tone: .glass))
                .accessibilityLabel("Cancel")

                Button(action: confirm) {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(HUDIconButtonStyle(tone: .accent))
                .disabled(!pendingPlacement.isValid)
                .accessibilityLabel("Confirm")
            }
        }
    }

    private var placementText: String {
        if pendingPlacement.isValid {
            switch pendingPlacement.mode {
            case .build(let type):
                return "\(GameEngine.buildingDefinition(for: type).label) • \(plotCoordinateLabel(row: pendingPlacement.row, col: pendingPlacement.col))"
            case .move:
                return "Move • \(plotCoordinateLabel(row: pendingPlacement.row, col: pendingPlacement.col))"
            }
        }

        switch pendingPlacement.blockedReason {
        case "occupied":
            return "Occupied"
        case "locked-area":
            return "Build zone"
        case "out-of-bounds":
            return "City limit"
        default:
            return "Blocked"
        }
    }
}

private struct ActionDock: View {
    let store: GameStore
    let openOverview: () -> Void
    let openSelectionDetails: () -> Void
    let showResetConfirmation: () -> Void

    var body: some View {
        HUDDockSurface {
            HStack(spacing: 8) {
                Button {
                    store.toggleBuildMode()
                } label: {
                    Image(systemName: store.isBuildMode ? "xmark" : "hammer.fill")
                }
                .buttonStyle(HUDIconButtonStyle(tone: .accent))
                .accessibilityLabel(store.isBuildMode ? "Exit build mode" : "Build")

                Button {
                    store.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(HUDIconButtonStyle(tone: .glass))
                .disabled(!store.canUndo)
                .accessibilityLabel("Undo")

                Menu {
                    Button {
                        openOverview()
                    } label: {
                        Label("City Details", systemImage: "chart.bar.fill")
                    }

                    if (store.isBuildMode && store.selectedBuildType != nil) || store.selectedBuilding != nil {
                        Button {
                            openSelectionDetails()
                        } label: {
                            Label("Selection Details", systemImage: "info.circle")
                        }
                    }

                    Button(role: .destructive) {
                        showResetConfirmation()
                    } label: {
                        Label("Reset City", systemImage: "trash")
                    }
                } label: {
                    HUDIconButtonChrome(symbol: "ellipsis")
                }
            }
        }
    }
}

private struct StepBankChip: View {
    let steps: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "shoeprints.fill")
                .font(.caption.weight(.black))
            Text(steps.formatted())
                .font(.caption.weight(.black))
        }
        .foregroundStyle(Color(red: 0.15, green: 0.18, blue: 0.16))
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            Capsule(style: .continuous)
                .fill(Color(red: 0.96, green: 0.79, blue: 0.33))
        )
    }
}

private struct CityOverviewSheet: View {
    let store: GameStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    overviewCard
                    statsGrid
                    statusCard
                }
                .padding(16)
            }
            .background(Color(red: 0.84, green: 0.91, blue: 0.87).ignoresSafeArea())
            .navigationTitle("City")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.citySummary.narrative.title)
                        .font(.headline.weight(.black))
                    Text("Level \(store.citySummary.level) • \(store.citySummary.stage.label)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(Int(store.citySummary.progressPercent.rounded()))%")
                    .font(.caption.weight(.black))
            }

            HUDProgressBar(progress: store.citySummary.progressPercent / 100, trackColor: lightCardTrack)
                .frame(height: 10)

            HStack(spacing: 12) {
                OverviewMetric(symbol: "shoeprints.fill", title: "Steps", value: store.state.availableSteps.formatted())
                OverviewMetric(symbol: "sparkles", title: "Prosperity", value: store.citySummary.prosperity.formatted())
                OverviewMetric(symbol: "square.grid.3x3.fill", title: "Districts", value: store.citySummary.buildingCount.formatted())
            }

            Text(store.citySummary.narrative.atmosphere)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.18, green: 0.31, blue: 0.27))

            Text(store.citySummary.narrative.heritage)
                .font(.subheadline)
                .foregroundStyle(Color(red: 0.25, green: 0.35, blue: 0.31))

            Text(nextUnlockText)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color(red: 0.18, green: 0.31, blue: 0.27).opacity(0.82))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(lightCardFill)
        )
    }

    private var statsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            OverviewMetric(symbol: "person.3.fill", title: "Population", value: store.citySummary.stats.population.formatted())
            OverviewMetric(symbol: "bitcoinsign.bank.building.fill", title: "Trade", value: store.citySummary.stats.commerce.formatted())
            OverviewMetric(symbol: "face.smiling.fill", title: "Joy", value: store.citySummary.stats.happiness.formatted())
            OverviewMetric(symbol: "leaf.fill", title: "Green", value: store.citySummary.stats.ecology.formatted())
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            OverviewStatusRow(symbol: "person.fill", title: "Player", value: store.playerStatusText)
            OverviewStatusRow(symbol: "antenna.radiowaves.left.and.right", title: "Connection", value: store.connectionStatusText)
            OverviewStatusRow(symbol: "icloud.fill", title: "Cloud", value: store.cloudStatusText)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(lightCardFill)
        )
    }

    private var nextUnlockText: String {
        guard let nextUnlock = store.citySummary.nextUnlock else {
            return store.citySummary.narrative.nextChapter
        }

        let definition = GameEngine.buildingDefinition(for: nextUnlock)
        return "\(store.citySummary.narrative.nextChapter) Next unlock: \(definition.label) at level \(definition.unlockLevel)."
    }
}

private struct CitySelectionSheet: View {
    let store: GameStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let selectedBuildType = store.selectedBuildType {
                        let definition = GameEngine.buildingDefinition(for: selectedBuildType)

                        detailCard(
                            title: definition.label,
                            subtitle: definition.role,
                            body: [
                                "\(definition.cost) steps",
                                "\(definition.width)×\(definition.height) footprint",
                                definition.baseEffects.formatted(),
                                definition.flavor,
                                definition.synergies.map(\.label).joined(separator: " • "),
                            ]
                        )
                    } else if let building = store.selectedBuilding {
                        let definition = GameEngine.buildingDefinition(for: building.type)
                        let refundSteps = Int(
                            (
                                Double(GameEngine.buildingTotalInvestment(building)) *
                                    TerraTreadRules.demolishRefundRatio
                            ).rounded()
                        )
                        let effectText = (
                            store.selectedBuildingBreakdown?.totalEffects ??
                                definition.baseEffects.scaled(
                                    multiplier: GameEngine.buildingLevelMultiplier(building.level)
                                )
                        ).formatted()

                        detailCard(
                            title: definition.label,
                            subtitle: "Lv \(building.level)/\(GameEngine.buildingMaxLevel(for: building.type))",
                            body: [
                                plotCoordinateLabel(row: building.row, col: building.col),
                                "\(definition.width)×\(definition.height) footprint",
                                effectText,
                                definition.flavor,
                                "Refund \(refundSteps) steps",
                            ]
                        )
                    } else {
                        detailCard(
                            title: "No Selection",
                            subtitle: "Board Idle",
                            body: [
                                "Tap a district to inspect it or place a new one from the dock.",
                                "Older lanes matter. Let your first neighborhoods remain visible as the city grows around them."
                            ]
                        )
                    }
                }
                .padding(16)
            }
            .background(Color(red: 0.84, green: 0.91, blue: 0.87).ignoresSafeArea())
            .navigationTitle("Selection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func detailCard(title: String, subtitle: String, body: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline.weight(.black))

                Spacer()

                Text(subtitle)
                    .font(.caption.weight(.black))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.08), in: Capsule())
            }

            ForEach(body, id: \.self) { line in
                Text(line)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.18, green: 0.31, blue: 0.27))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(lightCardFill)
        )
    }
}

private struct OverviewMetric: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.headline.weight(.black))
                .foregroundStyle(Color(red: 0.18, green: 0.31, blue: 0.27))

            Text(value)
                .font(.headline.weight(.black))

            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(lightCardFill)
        )
    }
}

private struct OverviewStatusRow: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 22)

            Text(title)
                .font(.subheadline.weight(.bold))

            Spacer()

            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(Color(red: 0.18, green: 0.31, blue: 0.27))
    }
}

private struct HUDProgressBar: View {
    let progress: Double
    let trackColor: Color

    init(progress: Double, trackColor: Color = Color.white.opacity(0.16)) {
        self.progress = progress
        self.trackColor = trackColor
    }

    var body: some View {
        GeometryReader { proxy in
            let clamped = max(0, min(1, progress))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.97, green: 0.84, blue: 0.46),
                                Color(red: 0.43, green: 0.82, blue: 0.55),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * clamped)
            }
        }
        .frame(height: 10)
    }
}

private enum HUDButtonTone {
    case accent
    case glass
}

private struct HUDCompactSurface<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(hudSurfaceFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(hudStrokeColor)
            )
            .shadow(color: Color.black.opacity(0.24), radius: 16, x: 0, y: 8)
    }
}

private struct HUDDockSurface<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(hudSurfaceFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(hudStrokeColor)
            )
            .shadow(color: Color.black.opacity(0.26), radius: 18, x: 0, y: 10)
    }
}

private struct HUDIconButtonChrome: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.headline.weight(.black))
            .frame(width: 42, height: 42)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(hudControlFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(hudStrokeColor)
            )
            .foregroundStyle(.white)
            .shadow(color: Color.black.opacity(0.20), radius: 8, x: 0, y: 4)
    }
}

private struct HUDIconButtonStyle: ButtonStyle {
    let tone: HUDButtonTone

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.black))
            .frame(width: 42, height: 42)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(borderColor)
            )
            .foregroundStyle(foregroundColor)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }

    private var backgroundColor: Color {
        switch tone {
        case .accent:
            Color(red: 0.96, green: 0.79, blue: 0.33)
        case .glass:
            hudControlFill
        }
    }

    private var foregroundColor: Color {
        switch tone {
        case .accent:
            Color(red: 0.15, green: 0.18, blue: 0.16)
        case .glass:
            .white
        }
    }

    private var borderColor: Color {
        switch tone {
        case .accent:
            Color.clear
        case .glass:
            hudStrokeColor
        }
    }
}

private struct HUDPillButtonStyle: ButtonStyle {
    let tone: HUDButtonTone

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.black))
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(borderColor)
            )
            .foregroundStyle(foregroundColor)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }

    private var backgroundColor: Color {
        switch tone {
        case .accent:
            Color(red: 0.96, green: 0.79, blue: 0.33)
        case .glass:
            hudControlFill
        }
    }

    private var foregroundColor: Color {
        switch tone {
        case .accent:
            Color(red: 0.15, green: 0.18, blue: 0.16)
        case .glass:
            .white
        }
    }

    private var borderColor: Color {
        switch tone {
        case .accent:
            Color.clear
        case .glass:
            hudStrokeColor
        }
    }
}
