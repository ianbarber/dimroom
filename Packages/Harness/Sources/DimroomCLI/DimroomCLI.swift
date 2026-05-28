import ArgumentParser
import Foundation
import Harness

@main
struct DimroomCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dimroom-cli",
        abstract: "Command-line interface for the Dimroom harness socket.",
        subcommands: [
            Navigate.self,
            Screenshot.self,
            State.self,
            Quit.self,
            ImportFolder.self,
            ListAssets.self,
            SelectAsset.self,
            SetRating.self,
            Rotate.self,
            GoBack.self,
            SetFilter.self,
            CopyEdit.self,
            PasteEdit.self,
            SetEdit.self,
            GetEdit.self,
            SetCrop.self,
            SetScope.self,
            ListImportSessions.self,
            SelectNext.self,
            SelectPrevious.self,
            SelectUp.self,
            SelectDown.self,
            ZoomToggle.self,
            ZoomReset.self,
            ToggleHistogram.self,
            Export.self,
            SetEditParameter.self,
            ResetEditParameter.self,
            SetEditFlag.self,
            ResetEditFlag.self,
            SetEditArrayParameter.self,
            ResetEditArrayParameter.self,
            SetCurvePoints.self,
            ResetCurve.self,
            SelectCurveChannel.self,
            Undo.self,
            Redo.self,
            SelectAssets.self,
            DeleteAssets.self,
            RestoreAssets.self,
            PermanentlyDeleteAssets.self,
            SetScopeRecentlyDeleted.self,
            GetPreviewSignature.self,
            EnterCrop.self,
            CommitCrop.self,
            CancelCrop.self,
            SetCropPreset.self,
            ResetCrop.self,
            InspectMenu.self,
            ConnectDrive.self,
            DisconnectDrive.self,
            DriveAuthStateCmd.self,
            SimulateDriveAuthFailure.self,
            PostMenuAction.self,
            ReleaseHeldDownloads.self,
            GetSetting.self,
            SetSetting.self,
            ClearOriginalsCache.self,
            ClearPreviewCache.self,
            SyncFromDrive.self,
            RestoreCatalogFromDrive.self,
            ReloadCatalogFromDrive.self,
            TriggerExportMenu.self,
            CompleteExportSheet.self,
            DismissRemoteAdditionsBadge.self,
        ]
    )
}

extension DimroomCLI {
    struct Navigate: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Navigate to a route.")

        @Argument(help: "The route to navigate to (library, loupe, develop).")
        var route: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            guard let r = Route(rawValue: route) else {
                throw ValidationError("Invalid route '\(route)'. Valid: \(Route.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            try runCommand(.navigate(r), socket: socket)
        }
    }

    struct Screenshot: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Capture a screenshot.")

        @Argument(help: "File path to write the PNG screenshot.")
        var path: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.screenshot(path: path), socket: socket)
        }
    }

    struct State: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Get current app state.")

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.state, socket: socket)
        }
    }

    struct Quit: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Quit the app.")

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.quit, socket: socket)
        }
    }

    struct ImportFolder: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import-folder",
            abstract: "Import all supported files from a folder into the catalog."
        )

        @Argument(help: "Absolute path to the folder to import.")
        var path: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.importFolder(path: path), socket: socket)
        }
    }

    struct ListAssets: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list-assets",
            abstract: "List all assets currently in the catalog."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.listAssets, socket: socket)
        }
    }

    struct SelectAsset: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "select-asset",
            abstract: "Set the library's single-selection to the given asset UUID."
        )

        @Argument(help: "The UUID of the asset to select.")
        var id: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("Invalid UUID '\(id)'.")
            }
            try runCommand(.selectAsset(id: uuid), socket: socket)
        }
    }

    struct SetRating: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-rating",
            abstract: "Set the star rating (0–5) for the asset with the given UUID."
        )

        @Argument(help: "The UUID of the asset to rate.")
        var id: String

        @Argument(help: "Rating value (0 clears, 1–5 set stars).")
        var rating: Int

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("Invalid UUID '\(id)'.")
            }
            guard (0...5).contains(rating) else {
                throw ValidationError("Rating must be in 0...5, got \(rating).")
            }
            try runCommand(.setRating(assetId: uuid, rating: rating), socket: socket)
        }
    }

    struct Rotate: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rotate",
            abstract: "Rotate the given asset 90° (non-destructive). Default clockwise."
        )

        @Argument(help: "The UUID of the asset to rotate.")
        var id: String

        @Option(name: .long, help: "Rotation direction: cw (clockwise) or ccw (counter-clockwise).")
        var direction: String = "cw"

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("Invalid UUID '\(id)'.")
            }
            guard direction == "cw" || direction == "ccw" else {
                throw ValidationError("direction must be 'cw' or 'ccw', got '\(direction)'.")
            }
            try runCommand(.rotate(assetId: uuid, direction: direction), socket: socket)
        }
    }

    struct GoBack: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "go-back",
            abstract: "Navigate one level up (Develop → Loupe → Library)."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.goBack, socket: socket)
        }
    }

    struct SetFilter: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-filter",
            abstract: "Set the minimum-rating filter (0 = show everything, 1–5 = show >= N stars)."
        )

        @Argument(help: "Minimum rating to show (0–5).")
        var minRating: Int

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            guard (0...5).contains(minRating) else {
                throw ValidationError("minRating must be in 0...5, got \(minRating).")
            }
            try runCommand(.setFilter(minRating: minRating), socket: socket)
        }
    }

    struct CopyEdit: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "copy-edit",
            abstract: "Copy the edit state of the given asset to the internal clipboard."
        )

        @Argument(help: "The UUID of the asset whose edit state to copy.")
        var id: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("Invalid UUID '\(id)'.")
            }
            try runCommand(.copyEdit(assetId: uuid), socket: socket)
        }
    }

    struct PasteEdit: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "paste-edit",
            abstract: "Paste the clipboard's edit state onto the given asset."
        )

        @Argument(help: "The UUID of the asset to paste the edit state onto.")
        var id: String

        @Flag(name: .long, help: "Include crop rect and crop angle in the paste.")
        var includeCrop: Bool = false

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("Invalid UUID '\(id)'.")
            }
            try runCommand(.pasteEdit(assetId: uuid, includeCrop: includeCrop), socket: socket)
        }
    }

    struct SetEdit: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-edit",
            abstract: "Set an edit state on an asset from a JSON string."
        )

        @Argument(help: "The UUID of the asset.")
        var id: String

        @Option(name: .long, help: "JSON string representing the EditState.")
        var json: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("Invalid UUID '\(id)'.")
            }
            try runCommand(.setEdit(assetId: uuid, stateJSON: json), socket: socket)
        }
    }

    struct GetEdit: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get-edit",
            abstract: "Get the latest edit state for an asset as JSON."
        )

        @Argument(help: "The UUID of the asset.")
        var id: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("Invalid UUID '\(id)'.")
            }
            try runCommand(.getEdit(assetId: uuid), socket: socket)
        }
    }

    struct SetCrop: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-crop",
            abstract: "Set the crop rect (normalised 0…1) and straighten angle on an asset."
        )

        @Argument(help: "The UUID of the asset.")
        var id: String

        @Option(name: .long, help: "Left edge of the crop rect in 0…1 normalised space.")
        var x: Double

        @Option(name: .long, help: "Top edge of the crop rect in 0…1 normalised space.")
        var y: Double

        @Option(name: .long, help: "Width of the crop rect in 0…1 normalised space.")
        var width: Double

        @Option(name: .long, help: "Height of the crop rect in 0…1 normalised space.")
        var height: Double

        @Option(name: .long, help: "Straighten angle in degrees (-45…+45).")
        var angle: Double = 0

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("Invalid UUID '\(id)'.")
            }
            try runCommand(
                .setCrop(
                    assetId: uuid,
                    x: x,
                    y: y,
                    width: width,
                    height: height,
                    angle: angle
                ),
                socket: socket
            )
        }
    }

    struct SetScope: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-scope",
            abstract: "Scope the library to an import session (omit id for All Photos)."
        )

        @Argument(help: "The UUID of the import session, or omit for All Photos.")
        var id: String?

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            let sessionId: UUID?
            if let id {
                guard let uuid = UUID(uuidString: id) else {
                    throw ValidationError("Invalid UUID '\(id)'.")
                }
                sessionId = uuid
            } else {
                sessionId = nil
            }
            try runCommand(.setScope(importSessionId: sessionId), socket: socket)
        }
    }

    struct ListImportSessions: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list-import-sessions",
            abstract: "List recent import sessions with display names and asset counts."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.listImportSessions, socket: socket)
        }
    }

    struct SelectNext: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "select-next",
            abstract: "Move selection to the next asset in the library grid."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.selectNext, socket: socket)
        }
    }

    struct SelectPrevious: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "select-previous",
            abstract: "Move selection to the previous asset in the library grid."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.selectPrevious, socket: socket)
        }
    }

    struct SelectUp: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "select-up",
            abstract: "Move selection up one row in the library grid."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.selectUp, socket: socket)
        }
    }

    struct SelectDown: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "select-down",
            abstract: "Move selection down one row in the library grid."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.selectDown, socket: socket)
        }
    }

    struct ZoomToggle: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "zoom-toggle",
            abstract: "Toggle zoom in the loupe view."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.zoomToggle, socket: socket)
        }
    }

    struct ZoomReset: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "zoom-reset",
            abstract: "Reset zoom to fit in the loupe view."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.zoomReset, socket: socket)
        }
    }

    struct ToggleHistogram: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "toggle-histogram",
            abstract: "Toggle the Develop histogram overlay visibility."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.toggleHistogram, socket: socket)
        }
    }

    struct SetEditParameter: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-edit-parameter",
            abstract: "Set a single edit parameter on an asset (e.g. exposure, contrast)."
        )

        @Argument(help: "The UUID of the asset.")
        var id: String

        @Argument(help: "Parameter name (exposure, contrast, highlights, shadows, whites, blacks, temperature, tint, clarity, sharpening, vibrance, saturation, luminanceNoiseReduction, chrominanceNoiseReduction, splitToneHighlightHue, splitToneHighlightSaturation, splitToneShadowHue, splitToneShadowSaturation, splitToneBalance, vignetteAmount, vignetteRoundness, vignetteSoftness, perspectiveVertical, perspectiveHorizontal, perspectiveRotation).")
        var parameter: String

        @Argument(help: "The value to set.")
        var value: Double

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("Invalid UUID '\(id)'.")
            }
            try runCommand(.setEditParameter(assetId: uuid, parameter: parameter, value: value), socket: socket)
        }
    }

    struct ResetEditParameter: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "reset-edit-parameter",
            abstract: "Reset a single edit parameter on an asset to its identity value."
        )

        @Argument(help: "The UUID of the asset.")
        var id: String

        @Argument(help: "Parameter name (exposure, contrast, highlights, shadows, whites, blacks, temperature, tint, clarity, sharpening, vibrance, saturation, luminanceNoiseReduction, chrominanceNoiseReduction, splitToneHighlightHue, splitToneHighlightSaturation, splitToneShadowHue, splitToneShadowSaturation, splitToneBalance, vignetteAmount, vignetteRoundness, vignetteSoftness, perspectiveVertical, perspectiveHorizontal, perspectiveRotation).")
        var parameter: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("Invalid UUID '\(id)'.")
            }
            try runCommand(.resetEditParameter(assetId: uuid, parameter: parameter), socket: socket)
        }
    }

    struct SetEditFlag: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-edit-flag",
            abstract: "Set a boolean edit flag on an asset (chromaticAberration, lensVignette)."
        )

        @Argument(help: "The UUID of the asset.")
        var id: String

        @Argument(help: "Flag name (chromaticAberration, lensVignette).")
        var parameter: String

        @Argument(help: "The value to set (true or false).")
        var value: Bool

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("Invalid UUID '\(id)'.")
            }
            try runCommand(.setEditFlag(assetId: uuid, parameter: parameter, value: value), socket: socket)
        }
    }

    struct ResetEditFlag: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "reset-edit-flag",
            abstract: "Reset a boolean edit flag on an asset to false."
        )

        @Argument(help: "The UUID of the asset.")
        var id: String

        @Argument(help: "Flag name (chromaticAberration, lensVignette).")
        var parameter: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("Invalid UUID '\(id)'.")
            }
            try runCommand(.resetEditFlag(assetId: uuid, parameter: parameter), socket: socket)
        }
    }

    struct SetEditArrayParameter: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-edit-array-parameter",
            abstract: "Set a single index of an array-valued edit parameter (e.g. hueShift, hslSaturation, hslLuminance)."
        )

        @Argument(help: "The UUID of the asset.")
        var id: String

        @Argument(help: "Parameter name (hueShift, hslSaturation, hslLuminance).")
        var parameter: String

        @Argument(help: "Array index (0…7 for HSL: red, orange, yellow, green, aqua, blue, purple, magenta).")
        var index: Int

        @Argument(help: "The value to set.")
        var value: Double

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("Invalid UUID '\(id)'.")
            }
            try runCommand(.setEditArrayParameter(assetId: uuid, parameter: parameter, index: index, value: value), socket: socket)
        }
    }

    struct ResetEditArrayParameter: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "reset-edit-array-parameter",
            abstract: "Reset a single index of an array-valued edit parameter to its identity value (0)."
        )

        @Argument(help: "The UUID of the asset.")
        var id: String

        @Argument(help: "Parameter name (hueShift, hslSaturation, hslLuminance).")
        var parameter: String

        @Argument(help: "Array index (0…7).")
        var index: Int

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("Invalid UUID '\(id)'.")
            }
            try runCommand(.resetEditArrayParameter(assetId: uuid, parameter: parameter, index: index), socket: socket)
        }
    }

    struct SetCurvePoints: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-curve-points",
            abstract: "Set the tone-curve points for a channel (luminance, red, green, blue) on an asset."
        )

        @Argument(help: "The UUID of the asset.")
        var id: String

        @Argument(help: "Channel name: luminance, red, green, blue.")
        var channel: String

        @Argument(help: #"Curve points as JSON array of [x, y] pairs, e.g. "[[0,0],[0.5,0.6],[1,1]]"."#)
        var pointsJSON: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("Invalid UUID '\(id)'.")
            }
            try runCommand(
                .setCurvePoints(assetId: uuid, channel: channel, pointsJSON: pointsJSON),
                socket: socket
            )
        }
    }

    struct ResetCurve: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "reset-curve",
            abstract: "Reset the tone curve for a channel (luminance, red, green, blue) to identity [(0,0),(1,1)]."
        )

        @Argument(help: "The UUID of the asset.")
        var id: String

        @Argument(help: "Channel name: luminance, red, green, blue.")
        var channel: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("Invalid UUID '\(id)'.")
            }
            try runCommand(.resetCurve(assetId: uuid, channel: channel), socket: socket)
        }
    }

    struct SelectCurveChannel: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "select-curve-channel",
            abstract: "Switch the Develop curve-editor channel picker (luminance, red, green, blue)."
        )

        @Argument(help: "Channel name: luminance, red, green, blue.")
        var channel: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.selectCurveChannel(channel: channel), socket: socket)
        }
    }

    struct Export: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Export visible/selected assets to a local folder."
        )

        @Argument(help: "Absolute path to the destination directory.")
        var destinationPath: String

        @Option(name: .long, help: "Export format: original, jpeg, or tiff.")
        var format: String = "jpeg"

        @Flag(name: .long, help: "Apply edits to exported files.")
        var applyEdits: Bool = false

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            let validFormats = ["original", "jpeg", "tiff"]
            guard validFormats.contains(format) else {
                throw ValidationError("format must be one of \(validFormats.joined(separator: ", ")), got '\(format)'.")
            }
            try runCommand(.export(destinationPath: destinationPath, format: format, applyEdits: applyEdits), socket: socket)
        }
    }

    struct TriggerExportMenu: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "trigger-export-menu",
            abstract: "Post the same .showExportSheet notification the File → Export… menu does, exercising the SwiftUI sheet path. Returns isExportSheetVisible so the caller can assert the sheet mounted (#242)."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.triggerExportMenu, socket: socket)
        }
    }

    struct CompleteExportSheet: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "complete-export-sheet",
            abstract: "Drive the export sheet's onExport callback (substitutes for the NSOpenPanel that the harness can't drive) and enter the unified AppDelegate.startExport entry point. Fails if the sheet isn't currently visible (#242)."
        )

        @Argument(help: "Absolute path to the destination directory (substitutes for NSOpenPanel).")
        var destinationPath: String

        @Option(name: .long, help: "Export format: original, jpeg, or tiff.")
        var format: String = "jpeg"

        @Flag(name: .long, help: "Apply edits to exported files.")
        var applyEdits: Bool = false

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            let validFormats = ["original", "jpeg", "tiff"]
            guard validFormats.contains(format) else {
                throw ValidationError("format must be one of \(validFormats.joined(separator: ", ")), got '\(format)'.")
            }
            try runCommand(
                .completeExportSheet(destinationPath: destinationPath, format: format, applyEdits: applyEdits),
                socket: socket
            )
        }
    }

    struct Undo: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "undo",
            abstract: "Undo the most recent undoable action (rating, rotation, edit, delete)."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.undo, socket: socket)
        }
    }

    struct Redo: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "redo",
            abstract: "Redo the most recently undone action."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.redo, socket: socket)
        }
    }

    struct SelectAssets: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "select-assets",
            abstract: "Replace the library multi-selection with the given UUIDs."
        )

        @Argument(help: "One or more asset UUIDs to select.")
        var ids: [String]

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            let uuids = try ids.map { str -> UUID in
                guard let u = UUID(uuidString: str) else {
                    throw ValidationError("Invalid UUID '\(str)'.")
                }
                return u
            }
            try runCommand(.selectAssets(ids: uuids), socket: socket)
        }
    }

    struct DeleteAssets: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete-assets",
            abstract: "Soft-delete one or more assets (move to Recently Deleted)."
        )

        @Argument(help: "One or more asset UUIDs to soft-delete.")
        var ids: [String]

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            let uuids = try ids.map { str -> UUID in
                guard let u = UUID(uuidString: str) else {
                    throw ValidationError("Invalid UUID '\(str)'.")
                }
                return u
            }
            try runCommand(.deleteAssets(ids: uuids), socket: socket)
        }
    }

    struct RestoreAssets: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "restore-assets",
            abstract: "Restore previously soft-deleted assets back into the library."
        )

        @Argument(help: "One or more asset UUIDs to restore.")
        var ids: [String]

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            let uuids = try ids.map { str -> UUID in
                guard let u = UUID(uuidString: str) else {
                    throw ValidationError("Invalid UUID '\(str)'.")
                }
                return u
            }
            try runCommand(.restoreAssets(ids: uuids), socket: socket)
        }
    }

    struct PermanentlyDeleteAssets: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "permanently-delete-assets",
            abstract: "Permanently remove soft-deleted assets, including cached files."
        )

        @Argument(help: "One or more asset UUIDs to permanently delete.")
        var ids: [String]

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            let uuids = try ids.map { str -> UUID in
                guard let u = UUID(uuidString: str) else {
                    throw ValidationError("Invalid UUID '\(str)'.")
                }
                return u
            }
            try runCommand(.permanentlyDeleteAssets(ids: uuids), socket: socket)
        }
    }

    struct GetPreviewSignature: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get-preview-signature",
            abstract: "Get the SHA-256 of the cached thumbnail JPEG for an asset (hash + bytes)."
        )

        @Argument(help: "The UUID of the asset.")
        var id: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("Invalid UUID '\(id)'.")
            }
            try runCommand(.getPreviewSignature(assetId: uuid), socket: socket)
        }
    }

    struct SetScopeRecentlyDeleted: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-scope-recently-deleted",
            abstract: "Scope the library to the Recently Deleted trash."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.setScopeRecentlyDeleted, socket: socket)
        }
    }

    struct EnterCrop: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "enter-crop",
            abstract: "Activate the interactive crop overlay on the given asset."
        )

        @Argument(help: "The UUID of the asset to enter crop mode on.")
        var id: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("Invalid UUID '\(id)'.")
            }
            try runCommand(.enterCropMode(assetId: uuid), socket: socket)
        }
    }

    struct CommitCrop: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "commit-crop",
            abstract: "Commit the active crop overlay's rect and angle to EditState."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.commitCrop, socket: socket)
        }
    }

    struct CancelCrop: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "cancel-crop",
            abstract: "Exit crop mode and revert to the pre-activate crop state."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.cancelCrop, socket: socket)
        }
    }

    struct SetCropPreset: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-crop-preset",
            abstract: "Select an aspect-ratio preset on the active crop overlay."
        )

        @Option(name: .long, help: "Preset name (free, original, oneToOne, fourToThree, threeToTwo, sixteenToNine, fiveToFour).")
        var preset: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.setCropPreset(name: preset), socket: socket)
        }
    }

    struct ResetCrop: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "reset-crop",
            abstract: "Reset the active crop overlay's rect back to the full frame."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.resetCrop, socket: socket)
        }
    }

    struct InspectMenu: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "inspect-menu",
            abstract: "Inspect a top-level main-menu submenu and return each item's title, key equivalent, modifier mask, and enabled state."
        )

        @Argument(help: "The title of the top-level menu to inspect (e.g. 'Edit', 'File').")
        var title: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.inspectMenu(title: title), socket: socket)
        }
    }

    struct ConnectDrive: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "connect-drive",
            abstract: "Trigger the Google Drive OAuth connect flow (same path as the menu)."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.connectDrive, socket: socket)
        }
    }

    struct DisconnectDrive: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "disconnect-drive",
            abstract: "Clear the stored Drive refresh token and revert the UI to disconnected."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.disconnectDrive, socket: socket)
        }
    }

    struct DriveAuthStateCmd: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "drive-auth-state",
            abstract: "Return the current Drive auth status (disconnected/connecting/connected) and email."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.driveAuthState, socket: socket)
        }
    }

    struct SimulateDriveAuthFailure: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "simulate-drive-auth-failure",
            abstract: "Inject a DriveAuthState transition equivalent to a refresh-token failure (issue #195). For deterministic Layer C tests of the stale-token recovery path."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.simulateDriveAuthFailure, socket: socket)
        }
    }

    struct ReleaseHeldDownloads: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "release-held-downloads",
            abstract: "Drain every parked download in the hold-until-released harness stub (paired with DIMROOM_HARNESS_STUB_DOWNLOADER=hold-until-released)."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.releaseHeldDownloads, socket: socket)
        }
    }

    struct GetSetting: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get-setting",
            abstract: "Read a SettingsStore value by short wire key (e.g. libraryGridColumns)."
        )

        @Argument(help: "Setting key (short name, without dimroom.settings. prefix).")
        var key: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.getSetting(key: key), socket: socket)
        }
    }

    struct SetSetting: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-setting",
            abstract: "Write a SettingsStore value. valueJSON is a JSON scalar (e.g. 4, true, \"text\")."
        )

        @Argument(help: "Setting key (short name).")
        var key: String

        @Argument(help: "JSON-encoded value: 4, true, \"text\", etc.")
        var valueJSON: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.setSetting(key: key, valueJSON: valueJSON), socket: socket)
        }
    }

    struct ClearOriginalsCache: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clear-originals-cache",
            abstract: "Wipe every cached original on disk."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.clearOriginalsCache, socket: socket)
        }
    }

    struct ClearPreviewCache: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clear-preview-cache",
            abstract: "Wipe every cached preview JPEG (master + display tiers)."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.clearPreviewCache, socket: socket)
        }
    }

    struct DismissRemoteAdditionsBadge: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "dismiss-remote-additions-badge",
            abstract: "Clear the Library filter bar's 'N new on Drive' badge (mirrors its X button)."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.dismissRemoteAdditionsBadge, socket: socket)
        }
    }

    struct SyncFromDrive: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sync-from-drive",
            abstract: "Force a single Drive changes-list poll and return the classified outcome."
        )

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.syncFromDrive, socket: socket)
        }
    }

    struct RestoreCatalogFromDrive: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "restore-catalog-from-drive",
            abstract: "Run the first-launch catalog-restore probe against Drive (or the local-file stub) and return the outcome (#234)."
        )

        @Flag(name: .long, help: "Confirm the restore prompt (default).")
        var confirm: Bool = false

        @Flag(name: .long, help: "Decline the restore prompt — equivalent to clicking 'Start Fresh'.")
        var decline: Bool = false

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            if confirm && decline {
                throw ValidationError("--confirm and --decline are mutually exclusive")
            }
            // Default is confirm so the no-flag invocation matches the
            // launch-time auto-confirm path used by the Layer C flow.
            let approve = !decline
            try runCommand(.restoreCatalogFromDrive(confirm: approve), socket: socket)
        }
    }

    struct ReloadCatalogFromDrive: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "reload-catalog-from-drive",
            abstract: "Hot-reload the local catalog from the published remote (#259). Same path the 'Reload Now' button in the catalog-changed alert dispatches."
        )

        @Option(name: .long, help: "Drive file id from the prior syncFromDrive catalogChanged payload.")
        var driveFileId: String

        @Option(name: .long, help: "ISO-8601 modifiedTime from the syncFromDrive payload (optional).")
        var modifiedTime: String?

        @Option(name: .long, help: "Page token from the syncFromDrive payload, persisted on the new catalog.")
        var pageToken: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(
                .reloadCatalogFromDrive(
                    driveFileId: driveFileId,
                    modifiedTime: modifiedTime,
                    pageToken: pageToken
                ),
                socket: socket
            )
        }
    }

    struct PostMenuAction: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "post-menu-action",
            abstract: "Fire one of the app's menu-attached keyboard actions by name (mode-library, mode-loupe, mode-develop, set-rating-1…5, clear-rating, rotate-cw, rotate-ccw, zoom-toggle, zoom-reset, toggle-histogram, select-next, select-previous, select-up, select-down, select-all-visible)."
        )

        @Argument(help: "Action name; see abstract for the whitelist.")
        var name: String

        @Option(name: .long, help: "Path to the harness socket.")
        var socket: String = HarnessServer.defaultSocketPath

        func run() throws {
            try runCommand(.postMenuAction(name: name), socket: socket)
        }
    }
}

private func runCommand(_ command: Command, socket: String) throws {
    let semaphore = DispatchSemaphore(value: 0)
    let box = SendableBox<Result<Response, Error>>()

    Task {
        do {
            let client = HarnessClient(socketPath: socket)
            try await client.connect()
            let response = try await client.send(command)
            client.disconnect()
            box.value = .success(response)
        } catch {
            box.value = .failure(error)
        }
        semaphore.signal()
    }

    semaphore.wait()

    switch box.value! {
    case .success(let response):
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(response)
        print(String(data: data, encoding: .utf8)!)
    case .failure(let error):
        throw error
    }
}

/// Thread-safe box for capturing values in Sendable closures.
private final class SendableBox<T>: @unchecked Sendable {
    var value: T?
}
