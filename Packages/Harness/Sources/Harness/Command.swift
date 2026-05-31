import Foundation

/// Commands sent to the harness over the Unix socket.
/// JSON uses a `type` discriminator key, e.g. `{"type":"navigate","route":"library"}`.
public enum Command: Codable, Sendable, Equatable {
    case navigate(Route)
    case screenshot(path: String)
    case state
    case quit
    case importFolder(path: String)
    case listAssets
    case selectAsset(id: UUID)
    case setRating(assetId: UUID, rating: Int)
    case rotate(assetId: UUID, direction: String)
    case goBack
    case setFilter(minRating: Int)
    case copyEdit(assetId: UUID)
    case pasteEdit(assetId: UUID, includeCrop: Bool)
    case setEdit(assetId: UUID, stateJSON: String)
    case getEdit(assetId: UUID)
    case setCrop(assetId: UUID, x: Double, y: Double, width: Double, height: Double, angle: Double)
    case setScope(importSessionId: UUID?)
    case setScopeRecentlyDeleted
    case listImportSessions
    case selectNext
    case selectPrevious
    case selectUp
    case selectDown
    case zoomToggle
    case zoomReset
    case toggleHistogram
    case export(destinationPath: String, format: String, applyEdits: Bool)
    case fetchOriginal(assetId: UUID)
    case setEditParameter(assetId: UUID, parameter: String, value: Double)
    case resetEditParameter(assetId: UUID, parameter: String)
    case setEditFlag(assetId: UUID, parameter: String, value: Bool)
    case resetEditFlag(assetId: UUID, parameter: String)
    /// Set a single index of an array-valued edit parameter (e.g.
    /// `hueShift`, `hslSaturation`, `hslLuminance`). Separate from
    /// `setEditParameter` because the keypath surface only addresses
    /// scalar `Double` fields; an array index needs an explicit `index`
    /// payload to stay statically typed.
    case setEditArrayParameter(assetId: UUID, parameter: String, index: Int, value: Double)
    case resetEditArrayParameter(assetId: UUID, parameter: String, index: Int)
    /// Replace the curve points for a single channel on an asset.
    /// `pointsJSON` is a JSON-encoded `[[Double, Double]]` array
    /// (e.g. `"[[0,0],[0.5,0.6],[1,1]]"`). Matches the wire convention
    /// used by `setEdit.stateJSON` so the protocol doesn't need a
    /// CGPoint type.
    case setCurvePoints(assetId: UUID, channel: String, pointsJSON: String)
    case resetCurve(assetId: UUID, channel: String)
    /// Switch the Develop curve-editor channel picker
    /// (Luminance / Red / Green / Blue). Affects which curve is rendered
    /// on the editor canvas; does not mutate `EditState`.
    case selectCurveChannel(channel: String)
    case undo
    case redo
    case selectAssets(ids: [UUID])
    case deleteAssets(ids: [UUID])
    case restoreAssets(ids: [UUID])
    case permanentlyDeleteAssets(ids: [UUID])
    case uploadToDrive(assetId: UUID)
    case getPreviewSignature(assetId: UUID)
    case enterCropMode(assetId: UUID)
    case commitCrop
    case cancelCrop
    case setCropPreset(name: String)
    case resetCrop
    case inspectMenu(title: String)
    case publishCatalog
    case connectDrive
    case disconnectDrive
    case driveAuthState
    /// Test hook that injects the same `DriveAuthState` transition the
    /// real refresh-failure stream observer would, without requiring a
    /// revoked-token round-trip against Google. Used by Layer C flows
    /// that exercise the stale-token recovery path (issue #195).
    case simulateDriveAuthFailure
    /// Posts a `Notification.Name` matching `name` on the app's main
    /// `NotificationCenter`. The app exposes a fixed whitelist of menu
    /// actions (mode switch, ratings, zoom, histogram, arrow nav, etc.)
    /// so harness flows can exercise menu-attached keyboard shortcuts
    /// without synthesising NSEvents. Unknown names are rejected by the
    /// handler at runtime.
    case postMenuAction(name: String)
    /// Releases every pending download currently parked in the
    /// `hold-until-released` harness stub downloader. Each held call
    /// then writes its synthetic payload and returns, draining the
    /// in-flight set so the flow can verify late-tail behaviour.
    /// No-op outside harness mode with `DIMROOM_HARNESS_STUB_DOWNLOADER=hold-until-released`.
    case releaseHeldDownloads
    /// Read a value from the `SettingsStore` by its short wire key
    /// (e.g. "libraryGridColumns"). Returns the value as `AnyCodableValue`
    /// under the `value` field, or an error response for unknown keys.
    case getSetting(key: String)
    /// Write a value into the `SettingsStore`. `valueJSON` is a JSON-
    /// encoded scalar (`"4"`, `"true"`, `"\"text\""`). The handler
    /// decodes it, type-checks against the key, and pushes the change
    /// through the same `@Published` path the UI uses.
    case setSetting(key: String, valueJSON: String)
    /// Wipe every cached original on disk and clear the in-memory
    /// index. Mirrors the "Clear originals cache" button in Settings.
    case clearOriginalsCache
    /// Wipe every cached preview JPEG (both master and display tiers).
    /// Mirrors the "Clear preview cache" button in Settings.
    case clearPreviewCache
    /// Force a single Drive `changes.list` poll and return the
    /// classified outcome. Used by Layer C delta-sync flows so they
    /// don't have to wait for the periodic 5-minute tick.
    case syncFromDrive
    /// Run the one-shot, idempotent backfill that walks every file under
    /// the Drive `/PhotoTool/` root and PATCHes the shared
    /// `appProperties.dimroom` marker onto any that lack it (#328).
    /// Files uploaded before #310 don't carry the marker, so the change
    /// poller's scope filter would silently drop them. Returns
    /// `{scanned, patched, skipped}`. No associated values.
    case backfillDriveMarkers
    /// Runs `CatalogPublisher.restoreIfNeeded` against the live
    /// uploader (or the local-file stub when
    /// `DIMROOM_HARNESS_STUB_REMOTE_CATALOG` is set). `confirm`
    /// controls the prompt's reply (`true` ≡ Restore, `false` ≡ Start
    /// Fresh). Returns the outcome + `photoCount` + `downloadedBytes`
    /// in the response payload so flows can assert on the restore
    /// shape (issue #234).
    case restoreCatalogFromDrive(confirm: Bool)
    /// Runs the in-place hot-reload orchestration the
    /// `catalogChanged` delta-sync alert dispatches when the user
    /// clicks "Reload Now". Downloads `driveFileId` through the same
    /// catalog uploader the `restoreCatalogFromDrive` command uses
    /// (real `DriveCatalogUploader` outside the harness; the local-
    /// file stub when `DIMROOM_HARNESS_STUB_REMOTE_CATALOG` is set),
    /// atomically replaces the local catalog, then re-wires the
    /// view models / publisher / poller against the freshly-opened
    /// `CatalogDatabase`. `modifiedTime` and `pageToken` come from
    /// the prior `syncFromDrive` `catalogChanged` payload so the new
    /// catalog's `sync_state` resumes from the right cursor (#259).
    case reloadCatalogFromDrive(driveFileId: String, modifiedTime: String?, pageToken: String)
    /// Posts the same `.showExportSheet` notification the File → Export…
    /// menu item does, exercising the SwiftUI sheet presentation path
    /// end-to-end. Returns the post-tick value of
    /// `AppDelegate.isExportSheetVisible` so flows can assert the sheet
    /// actually mounted before firing `completeExportSheet`. Added for
    /// #242 so a regression in the menu → notification → sheet hop is
    /// caught by Layer C.
    case triggerExportMenu
    /// Drives the export sheet's `onExport` callback with the supplied
    /// destination + format + applyEdits values, dismissing the sheet
    /// and entering the coordinator through the same
    /// `AppDelegate.startExport` entry point the UI uses. Errors out if
    /// the sheet isn't currently visible (i.e. `triggerExportMenu`
    /// wasn't called or the confirmation policy diverted into the
    /// dialog branch). NSOpenPanel can't be driven from the harness, so
    /// `destinationPath` substitutes for the panel's URL output (#242).
    case completeExportSheet(destinationPath: String, format: String, applyEdits: Bool)
    /// Clears the Library filter bar's "N new on Drive" badge, mirroring
    /// the badge's own X dismiss button (added in #311). The badge is
    /// persistent — it does not auto-dismiss like `undoToast`/`ratingToast`
    /// — so this is the only way to exercise the dismiss path at Layer C
    /// (#313).
    case dismissRemoteAdditionsBadge
    /// Drives the `ColorWheelControl` keyboard path (#305) without
    /// synthesising NSEvents — the harness has no reliable way to land
    /// SwiftUI focus on a child view (see `postMenuAction`). The handler
    /// reads the wheel's current hue/saturation off the live edit state,
    /// applies `ColorWheelKeyboardModel.nudge` (the same function the
    /// view's `onKeyPress` calls), and writes the changed axis back
    /// through `DevelopViewModel.setParameter`. The two wheels are
    /// addressed by their hue/saturation parameter names (e.g.
    /// `splitToneHighlightHue` / `splitToneHighlightSaturation`). `key`
    /// is `left`/`right`/`up`/`down` (plain → hue, shift → saturation)
    /// or `reset` (→ identity). `shift` is ignored for `reset`.
    case nudgeColorWheel(assetId: UUID, hueParameter: String, saturationParameter: String, key: String, shift: Bool)
    /// Drive the Develop pixel magnifier (#324). Routes to Develop
    /// (activating the selected asset if needed) and sets visibility,
    /// the normalised sample point, and the zoom factor. `samplePointX`,
    /// `samplePointY`, and `zoom` are optional — omit them to toggle
    /// visibility without moving the sample point or changing zoom.
    case setMagnifier(visible: Bool, samplePointX: Double?, samplePointY: Double?, zoom: Int?)
    /// Set the floating magnifier window's drag offset directly (#377).
    /// The real move is a pointer drag the harness cannot synthesise (see
    /// #348), so this routes to Develop and calls the same clamping
    /// `setMagnifierWindowOffset` path the drag gesture uses — letting Layer
    /// C verify the offset is clamped on-screen. `x`/`y` are the desired
    /// offset in points from the default top-trailing anchor; the handler
    /// clamps them so the whole window stays within the preview bounds.
    case setMagnifierWindowOffset(x: Double, y: Double)
    /// Drives the crop overlay's drag-to-rotate handles (#323) without
    /// synthesising a pointer drag. The handler errors unless crop mode is
    /// active, then adds `angleDelta` (degrees) to the live `cropAngle`
    /// through the same `setCropAngleLive` path the on-screen handle drag
    /// and the straighten slider use. `corner` is validated against the
    /// four corner names for protocol fidelity; rotation is always about
    /// the crop centre, so the corner does not change the result.
    case dragRotateHandle(corner: String, angleDelta: Double)

    private enum CodingKeys: String, CodingKey {
        case type
        case route
        case path
        case id
        case ids
        case assetId
        case rating
        case direction
        case minRating
        case includeCrop
        case stateJSON
        case importSessionId
        case destinationPath
        case format
        case applyEdits
        case parameter
        case value
        case flagValue
        case index
        case channel
        case pointsJSON
        case x
        case y
        case width
        case height
        case angle
        case name
        case title
        case key
        case valueJSON
        case confirm
        case driveFileId
        case modifiedTime
        case pageToken
        case hueParameter
        case saturationParameter
        case shift
        case visible
        case samplePointX
        case samplePointY
        case zoom
        case corner
        case angleDelta
    }

    private enum CommandType: String, Codable {
        case navigate
        case screenshot
        case state
        case quit
        case importFolder
        case listAssets
        case selectAsset
        case setRating
        case rotate
        case goBack
        case setFilter
        case copyEdit
        case pasteEdit
        case setEdit
        case getEdit
        case setCrop
        case setScope
        case setScopeRecentlyDeleted
        case listImportSessions
        case selectNext
        case selectPrevious
        case selectUp
        case selectDown
        case zoomToggle
        case zoomReset
        case toggleHistogram
        case export
        case fetchOriginal
        case setEditParameter
        case resetEditParameter
        case setEditFlag
        case resetEditFlag
        case setEditArrayParameter
        case resetEditArrayParameter
        case setCurvePoints
        case resetCurve
        case selectCurveChannel
        case undo
        case redo
        case selectAssets
        case deleteAssets
        case restoreAssets
        case permanentlyDeleteAssets
        case uploadToDrive
        case getPreviewSignature
        case enterCropMode
        case commitCrop
        case cancelCrop
        case setCropPreset
        case resetCrop
        case inspectMenu
        case publishCatalog
        case connectDrive
        case disconnectDrive
        case driveAuthState
        case simulateDriveAuthFailure
        case postMenuAction
        case releaseHeldDownloads
        case getSetting
        case setSetting
        case clearOriginalsCache
        case clearPreviewCache
        case syncFromDrive
        case backfillDriveMarkers
        case restoreCatalogFromDrive
        case reloadCatalogFromDrive
        case triggerExportMenu
        case completeExportSheet
        case dismissRemoteAdditionsBadge
        case nudgeColorWheel
        case setMagnifier
        case setMagnifierWindowOffset
        case dragRotateHandle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(CommandType.self, forKey: .type)
        switch type {
        case .navigate:
            let route = try container.decode(Route.self, forKey: .route)
            self = .navigate(route)
        case .screenshot:
            let path = try container.decode(String.self, forKey: .path)
            self = .screenshot(path: path)
        case .state:
            self = .state
        case .quit:
            self = .quit
        case .importFolder:
            let path = try container.decode(String.self, forKey: .path)
            self = .importFolder(path: path)
        case .listAssets:
            self = .listAssets
        case .selectAsset:
            let id = try container.decode(UUID.self, forKey: .id)
            self = .selectAsset(id: id)
        case .setRating:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            let rating = try container.decode(Int.self, forKey: .rating)
            self = .setRating(assetId: assetId, rating: rating)
        case .rotate:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            let direction = try container.decodeIfPresent(String.self, forKey: .direction) ?? "cw"
            self = .rotate(assetId: assetId, direction: direction)
        case .goBack:
            self = .goBack
        case .setFilter:
            let minRating = try container.decode(Int.self, forKey: .minRating)
            self = .setFilter(minRating: minRating)
        case .copyEdit:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            self = .copyEdit(assetId: assetId)
        case .pasteEdit:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            let includeCrop = try container.decode(Bool.self, forKey: .includeCrop)
            self = .pasteEdit(assetId: assetId, includeCrop: includeCrop)
        case .setEdit:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            let stateJSON = try container.decode(String.self, forKey: .stateJSON)
            self = .setEdit(assetId: assetId, stateJSON: stateJSON)
        case .getEdit:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            self = .getEdit(assetId: assetId)
        case .setCrop:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            let x = try container.decode(Double.self, forKey: .x)
            let y = try container.decode(Double.self, forKey: .y)
            let width = try container.decode(Double.self, forKey: .width)
            let height = try container.decode(Double.self, forKey: .height)
            let angle = try container.decode(Double.self, forKey: .angle)
            self = .setCrop(
                assetId: assetId,
                x: x,
                y: y,
                width: width,
                height: height,
                angle: angle
            )
        case .setScope:
            let sessionId = try container.decodeIfPresent(UUID.self, forKey: .importSessionId)
            self = .setScope(importSessionId: sessionId)
        case .setScopeRecentlyDeleted:
            self = .setScopeRecentlyDeleted
        case .listImportSessions:
            self = .listImportSessions
        case .selectNext:
            self = .selectNext
        case .selectPrevious:
            self = .selectPrevious
        case .selectUp:
            self = .selectUp
        case .selectDown:
            self = .selectDown
        case .zoomToggle:
            self = .zoomToggle
        case .zoomReset:
            self = .zoomReset
        case .toggleHistogram:
            self = .toggleHistogram
        case .export:
            let destinationPath = try container.decode(String.self, forKey: .destinationPath)
            let format = try container.decode(String.self, forKey: .format)
            let applyEdits = try container.decode(Bool.self, forKey: .applyEdits)
            self = .export(destinationPath: destinationPath, format: format, applyEdits: applyEdits)
        case .fetchOriginal:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            self = .fetchOriginal(assetId: assetId)
        case .setEditParameter:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            let parameter = try container.decode(String.self, forKey: .parameter)
            let value = try container.decode(Double.self, forKey: .value)
            self = .setEditParameter(assetId: assetId, parameter: parameter, value: value)
        case .resetEditParameter:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            let parameter = try container.decode(String.self, forKey: .parameter)
            self = .resetEditParameter(assetId: assetId, parameter: parameter)
        case .setEditFlag:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            let parameter = try container.decode(String.self, forKey: .parameter)
            let value = try container.decode(Bool.self, forKey: .flagValue)
            self = .setEditFlag(assetId: assetId, parameter: parameter, value: value)
        case .resetEditFlag:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            let parameter = try container.decode(String.self, forKey: .parameter)
            self = .resetEditFlag(assetId: assetId, parameter: parameter)
        case .setEditArrayParameter:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            let parameter = try container.decode(String.self, forKey: .parameter)
            let index = try container.decode(Int.self, forKey: .index)
            let value = try container.decode(Double.self, forKey: .value)
            self = .setEditArrayParameter(assetId: assetId, parameter: parameter, index: index, value: value)
        case .resetEditArrayParameter:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            let parameter = try container.decode(String.self, forKey: .parameter)
            let index = try container.decode(Int.self, forKey: .index)
            self = .resetEditArrayParameter(assetId: assetId, parameter: parameter, index: index)
        case .setCurvePoints:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            let channel = try container.decode(String.self, forKey: .channel)
            let pointsJSON = try container.decode(String.self, forKey: .pointsJSON)
            self = .setCurvePoints(assetId: assetId, channel: channel, pointsJSON: pointsJSON)
        case .resetCurve:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            let channel = try container.decode(String.self, forKey: .channel)
            self = .resetCurve(assetId: assetId, channel: channel)
        case .selectCurveChannel:
            let channel = try container.decode(String.self, forKey: .channel)
            self = .selectCurveChannel(channel: channel)
        case .undo:
            self = .undo
        case .redo:
            self = .redo
        case .selectAssets:
            let ids = try container.decode([UUID].self, forKey: .ids)
            self = .selectAssets(ids: ids)
        case .deleteAssets:
            let ids = try container.decode([UUID].self, forKey: .ids)
            self = .deleteAssets(ids: ids)
        case .restoreAssets:
            let ids = try container.decode([UUID].self, forKey: .ids)
            self = .restoreAssets(ids: ids)
        case .permanentlyDeleteAssets:
            let ids = try container.decode([UUID].self, forKey: .ids)
            self = .permanentlyDeleteAssets(ids: ids)
        case .uploadToDrive:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            self = .uploadToDrive(assetId: assetId)
        case .getPreviewSignature:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            self = .getPreviewSignature(assetId: assetId)
        case .enterCropMode:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            self = .enterCropMode(assetId: assetId)
        case .commitCrop:
            self = .commitCrop
        case .cancelCrop:
            self = .cancelCrop
        case .setCropPreset:
            let name = try container.decode(String.self, forKey: .name)
            self = .setCropPreset(name: name)
        case .resetCrop:
            self = .resetCrop
        case .inspectMenu:
            let title = try container.decode(String.self, forKey: .title)
            self = .inspectMenu(title: title)
        case .publishCatalog:
            self = .publishCatalog
        case .connectDrive:
            self = .connectDrive
        case .disconnectDrive:
            self = .disconnectDrive
        case .driveAuthState:
            self = .driveAuthState
        case .simulateDriveAuthFailure:
            self = .simulateDriveAuthFailure
        case .postMenuAction:
            let name = try container.decode(String.self, forKey: .name)
            self = .postMenuAction(name: name)
        case .releaseHeldDownloads:
            self = .releaseHeldDownloads
        case .getSetting:
            let key = try container.decode(String.self, forKey: .key)
            self = .getSetting(key: key)
        case .setSetting:
            let key = try container.decode(String.self, forKey: .key)
            let valueJSON = try container.decode(String.self, forKey: .valueJSON)
            self = .setSetting(key: key, valueJSON: valueJSON)
        case .clearOriginalsCache:
            self = .clearOriginalsCache
        case .clearPreviewCache:
            self = .clearPreviewCache
        case .syncFromDrive:
            self = .syncFromDrive
        case .backfillDriveMarkers:
            self = .backfillDriveMarkers
        case .restoreCatalogFromDrive:
            let confirm = try container.decodeIfPresent(Bool.self, forKey: .confirm) ?? true
            self = .restoreCatalogFromDrive(confirm: confirm)
        case .reloadCatalogFromDrive:
            let driveFileId = try container.decode(String.self, forKey: .driveFileId)
            let modifiedTime = try container.decodeIfPresent(String.self, forKey: .modifiedTime)
            let pageToken = try container.decode(String.self, forKey: .pageToken)
            self = .reloadCatalogFromDrive(
                driveFileId: driveFileId,
                modifiedTime: modifiedTime,
                pageToken: pageToken
            )
        case .triggerExportMenu:
            self = .triggerExportMenu
        case .completeExportSheet:
            let destinationPath = try container.decode(String.self, forKey: .destinationPath)
            let format = try container.decode(String.self, forKey: .format)
            let applyEdits = try container.decode(Bool.self, forKey: .applyEdits)
            self = .completeExportSheet(destinationPath: destinationPath, format: format, applyEdits: applyEdits)
        case .dismissRemoteAdditionsBadge:
            self = .dismissRemoteAdditionsBadge
        case .nudgeColorWheel:
            let assetId = try container.decode(UUID.self, forKey: .assetId)
            let hueParameter = try container.decode(String.self, forKey: .hueParameter)
            let saturationParameter = try container.decode(String.self, forKey: .saturationParameter)
            let key = try container.decode(String.self, forKey: .key)
            let shift = try container.decodeIfPresent(Bool.self, forKey: .shift) ?? false
            self = .nudgeColorWheel(
                assetId: assetId,
                hueParameter: hueParameter,
                saturationParameter: saturationParameter,
                key: key,
                shift: shift
            )
        case .setMagnifier:
            let visible = try container.decode(Bool.self, forKey: .visible)
            let samplePointX = try container.decodeIfPresent(Double.self, forKey: .samplePointX)
            let samplePointY = try container.decodeIfPresent(Double.self, forKey: .samplePointY)
            let zoom = try container.decodeIfPresent(Int.self, forKey: .zoom)
            self = .setMagnifier(
                visible: visible,
                samplePointX: samplePointX,
                samplePointY: samplePointY,
                zoom: zoom
            )
        case .setMagnifierWindowOffset:
            let x = try container.decode(Double.self, forKey: .x)
            let y = try container.decode(Double.self, forKey: .y)
            self = .setMagnifierWindowOffset(x: x, y: y)
        case .dragRotateHandle:
            let corner = try container.decode(String.self, forKey: .corner)
            let angleDelta = try container.decode(Double.self, forKey: .angleDelta)
            self = .dragRotateHandle(corner: corner, angleDelta: angleDelta)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .navigate(let route):
            try container.encode(CommandType.navigate, forKey: .type)
            try container.encode(route, forKey: .route)
        case .screenshot(let path):
            try container.encode(CommandType.screenshot, forKey: .type)
            try container.encode(path, forKey: .path)
        case .state:
            try container.encode(CommandType.state, forKey: .type)
        case .quit:
            try container.encode(CommandType.quit, forKey: .type)
        case .importFolder(let path):
            try container.encode(CommandType.importFolder, forKey: .type)
            try container.encode(path, forKey: .path)
        case .listAssets:
            try container.encode(CommandType.listAssets, forKey: .type)
        case .selectAsset(let id):
            try container.encode(CommandType.selectAsset, forKey: .type)
            try container.encode(id, forKey: .id)
        case .setRating(let assetId, let rating):
            try container.encode(CommandType.setRating, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(rating, forKey: .rating)
        case .rotate(let assetId, let direction):
            try container.encode(CommandType.rotate, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(direction, forKey: .direction)
        case .goBack:
            try container.encode(CommandType.goBack, forKey: .type)
        case .setFilter(let minRating):
            try container.encode(CommandType.setFilter, forKey: .type)
            try container.encode(minRating, forKey: .minRating)
        case .copyEdit(let assetId):
            try container.encode(CommandType.copyEdit, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
        case .pasteEdit(let assetId, let includeCrop):
            try container.encode(CommandType.pasteEdit, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(includeCrop, forKey: .includeCrop)
        case .setEdit(let assetId, let stateJSON):
            try container.encode(CommandType.setEdit, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(stateJSON, forKey: .stateJSON)
        case .getEdit(let assetId):
            try container.encode(CommandType.getEdit, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
        case .setCrop(let assetId, let x, let y, let width, let height, let angle):
            try container.encode(CommandType.setCrop, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
            try container.encode(width, forKey: .width)
            try container.encode(height, forKey: .height)
            try container.encode(angle, forKey: .angle)
        case .setScope(let sessionId):
            try container.encode(CommandType.setScope, forKey: .type)
            try container.encodeIfPresent(sessionId, forKey: .importSessionId)
        case .setScopeRecentlyDeleted:
            try container.encode(CommandType.setScopeRecentlyDeleted, forKey: .type)
        case .listImportSessions:
            try container.encode(CommandType.listImportSessions, forKey: .type)
        case .selectNext:
            try container.encode(CommandType.selectNext, forKey: .type)
        case .selectPrevious:
            try container.encode(CommandType.selectPrevious, forKey: .type)
        case .selectUp:
            try container.encode(CommandType.selectUp, forKey: .type)
        case .selectDown:
            try container.encode(CommandType.selectDown, forKey: .type)
        case .zoomToggle:
            try container.encode(CommandType.zoomToggle, forKey: .type)
        case .zoomReset:
            try container.encode(CommandType.zoomReset, forKey: .type)
        case .toggleHistogram:
            try container.encode(CommandType.toggleHistogram, forKey: .type)
        case .export(let destinationPath, let format, let applyEdits):
            try container.encode(CommandType.export, forKey: .type)
            try container.encode(destinationPath, forKey: .destinationPath)
            try container.encode(format, forKey: .format)
            try container.encode(applyEdits, forKey: .applyEdits)
        case .fetchOriginal(let assetId):
            try container.encode(CommandType.fetchOriginal, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
        case .setEditParameter(let assetId, let parameter, let value):
            try container.encode(CommandType.setEditParameter, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(parameter, forKey: .parameter)
            try container.encode(value, forKey: .value)
        case .resetEditParameter(let assetId, let parameter):
            try container.encode(CommandType.resetEditParameter, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(parameter, forKey: .parameter)
        case .setEditFlag(let assetId, let parameter, let value):
            try container.encode(CommandType.setEditFlag, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(parameter, forKey: .parameter)
            try container.encode(value, forKey: .flagValue)
        case .resetEditFlag(let assetId, let parameter):
            try container.encode(CommandType.resetEditFlag, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(parameter, forKey: .parameter)
        case .setEditArrayParameter(let assetId, let parameter, let index, let value):
            try container.encode(CommandType.setEditArrayParameter, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(parameter, forKey: .parameter)
            try container.encode(index, forKey: .index)
            try container.encode(value, forKey: .value)
        case .resetEditArrayParameter(let assetId, let parameter, let index):
            try container.encode(CommandType.resetEditArrayParameter, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(parameter, forKey: .parameter)
            try container.encode(index, forKey: .index)
        case .setCurvePoints(let assetId, let channel, let pointsJSON):
            try container.encode(CommandType.setCurvePoints, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(channel, forKey: .channel)
            try container.encode(pointsJSON, forKey: .pointsJSON)
        case .resetCurve(let assetId, let channel):
            try container.encode(CommandType.resetCurve, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(channel, forKey: .channel)
        case .selectCurveChannel(let channel):
            try container.encode(CommandType.selectCurveChannel, forKey: .type)
            try container.encode(channel, forKey: .channel)
        case .undo:
            try container.encode(CommandType.undo, forKey: .type)
        case .redo:
            try container.encode(CommandType.redo, forKey: .type)
        case .selectAssets(let ids):
            try container.encode(CommandType.selectAssets, forKey: .type)
            try container.encode(ids, forKey: .ids)
        case .deleteAssets(let ids):
            try container.encode(CommandType.deleteAssets, forKey: .type)
            try container.encode(ids, forKey: .ids)
        case .restoreAssets(let ids):
            try container.encode(CommandType.restoreAssets, forKey: .type)
            try container.encode(ids, forKey: .ids)
        case .permanentlyDeleteAssets(let ids):
            try container.encode(CommandType.permanentlyDeleteAssets, forKey: .type)
            try container.encode(ids, forKey: .ids)
        case .uploadToDrive(let assetId):
            try container.encode(CommandType.uploadToDrive, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
        case .getPreviewSignature(let assetId):
            try container.encode(CommandType.getPreviewSignature, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
        case .enterCropMode(let assetId):
            try container.encode(CommandType.enterCropMode, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
        case .commitCrop:
            try container.encode(CommandType.commitCrop, forKey: .type)
        case .cancelCrop:
            try container.encode(CommandType.cancelCrop, forKey: .type)
        case .setCropPreset(let name):
            try container.encode(CommandType.setCropPreset, forKey: .type)
            try container.encode(name, forKey: .name)
        case .resetCrop:
            try container.encode(CommandType.resetCrop, forKey: .type)
        case .inspectMenu(let title):
            try container.encode(CommandType.inspectMenu, forKey: .type)
            try container.encode(title, forKey: .title)
        case .publishCatalog:
            try container.encode(CommandType.publishCatalog, forKey: .type)
        case .connectDrive:
            try container.encode(CommandType.connectDrive, forKey: .type)
        case .disconnectDrive:
            try container.encode(CommandType.disconnectDrive, forKey: .type)
        case .driveAuthState:
            try container.encode(CommandType.driveAuthState, forKey: .type)
        case .simulateDriveAuthFailure:
            try container.encode(CommandType.simulateDriveAuthFailure, forKey: .type)
        case .postMenuAction(let name):
            try container.encode(CommandType.postMenuAction, forKey: .type)
            try container.encode(name, forKey: .name)
        case .releaseHeldDownloads:
            try container.encode(CommandType.releaseHeldDownloads, forKey: .type)
        case .getSetting(let key):
            try container.encode(CommandType.getSetting, forKey: .type)
            try container.encode(key, forKey: .key)
        case .setSetting(let key, let valueJSON):
            try container.encode(CommandType.setSetting, forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encode(valueJSON, forKey: .valueJSON)
        case .clearOriginalsCache:
            try container.encode(CommandType.clearOriginalsCache, forKey: .type)
        case .clearPreviewCache:
            try container.encode(CommandType.clearPreviewCache, forKey: .type)
        case .syncFromDrive:
            try container.encode(CommandType.syncFromDrive, forKey: .type)
        case .backfillDriveMarkers:
            try container.encode(CommandType.backfillDriveMarkers, forKey: .type)
        case .restoreCatalogFromDrive(let confirm):
            try container.encode(CommandType.restoreCatalogFromDrive, forKey: .type)
            try container.encode(confirm, forKey: .confirm)
        case .reloadCatalogFromDrive(let driveFileId, let modifiedTime, let pageToken):
            try container.encode(CommandType.reloadCatalogFromDrive, forKey: .type)
            try container.encode(driveFileId, forKey: .driveFileId)
            try container.encodeIfPresent(modifiedTime, forKey: .modifiedTime)
            try container.encode(pageToken, forKey: .pageToken)
        case .triggerExportMenu:
            try container.encode(CommandType.triggerExportMenu, forKey: .type)
        case .completeExportSheet(let destinationPath, let format, let applyEdits):
            try container.encode(CommandType.completeExportSheet, forKey: .type)
            try container.encode(destinationPath, forKey: .destinationPath)
            try container.encode(format, forKey: .format)
            try container.encode(applyEdits, forKey: .applyEdits)
        case .dismissRemoteAdditionsBadge:
            try container.encode(CommandType.dismissRemoteAdditionsBadge, forKey: .type)
        case .nudgeColorWheel(let assetId, let hueParameter, let saturationParameter, let key, let shift):
            try container.encode(CommandType.nudgeColorWheel, forKey: .type)
            try container.encode(assetId, forKey: .assetId)
            try container.encode(hueParameter, forKey: .hueParameter)
            try container.encode(saturationParameter, forKey: .saturationParameter)
            try container.encode(key, forKey: .key)
            try container.encode(shift, forKey: .shift)
        case .setMagnifier(let visible, let samplePointX, let samplePointY, let zoom):
            try container.encode(CommandType.setMagnifier, forKey: .type)
            try container.encode(visible, forKey: .visible)
            try container.encodeIfPresent(samplePointX, forKey: .samplePointX)
            try container.encodeIfPresent(samplePointY, forKey: .samplePointY)
            try container.encodeIfPresent(zoom, forKey: .zoom)
        case .setMagnifierWindowOffset(let x, let y):
            try container.encode(CommandType.setMagnifierWindowOffset, forKey: .type)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
        case .dragRotateHandle(let corner, let angleDelta):
            try container.encode(CommandType.dragRotateHandle, forKey: .type)
            try container.encode(corner, forKey: .corner)
            try container.encode(angleDelta, forKey: .angleDelta)
        }
    }
}
