import CoreGraphics
import Foundation
import GRDB

/// Reconstruct the pixel size of the master preview an asset's crop was
/// authored against, from catalog dimensions alone — no image decode.
///
/// `EditState.cropRect` is authored in the coordinate space of the
/// ~2048px master preview, and `DevelopViewModel.commitCrop` records that
/// preview's extent verbatim as `cropReferenceSize` (#320). For rows
/// written before that field existed, `cropReferenceSize` is `nil`, so a
/// fresh export rescales the crop by a 1.0 factor and corner-crops the
/// full-resolution original (#352).
///
/// The master preview's size is fully reconstructable from data already in
/// the catalog. This mirrors the preview-generation path in
/// `PreviewStore.generate`:
///
/// 1. `applyRotation(natural, rotation)` rotates a 90°/270° asset, which
///    swaps its width and height. 0°/180° leave the axes unchanged.
/// 2. `scale(longEdge:)` fits the long edge to the preview ceiling,
///    never upscaling.
///
/// The `2048` ceiling is hardcoded here on purpose: a migration must
/// capture the value in effect when the crops were authored, and Catalog
/// must not depend on the Previews package (layering). Keep in sync with
/// `PreviewKind.preview.maxEdge`.
///
/// Returns `nil` for degenerate (≤0) dimensions so the caller can skip
/// the row rather than write a meaningless reference size.
func legacyCropReferenceSize(
    width: Int,
    height: Int,
    rotation: Int,
    previewMaxEdge: CGFloat = 2048
) -> CGSize? {
    guard width > 0, height > 0 else { return nil }

    // Normalise to 0/90/180/270 and swap the axes for a quarter turn,
    // matching `PreviewStore.applyRotation`. Any non-multiple-of-90 is
    // treated as no rotation there, so it falls through to "no swap" here.
    let normalised = ((rotation % 360) + 360) % 360
    let w: CGFloat
    let h: CGFloat
    if normalised == 90 || normalised == 270 {
        w = CGFloat(height)
        h = CGFloat(width)
    } else {
        w = CGFloat(width)
        h = CGFloat(height)
    }

    // Fit the long edge to the preview ceiling, never upscaling — exactly
    // `PreviewStore.scale(_:longEdge:)`.
    let scale = min(1, previewMaxEdge / max(w, h))
    return CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
}

/// One-shot migration body: backfill `cropReferenceSize` on every
/// already-cropped `edit_states` row written before #351.
///
/// For each row whose decoded `EditState` has a `cropRect` but no
/// `cropReferenceSize`, reconstruct the authoring preview size from the
/// asset's natural dimensions and rotation (`legacyCropReferenceSize`),
/// set it, and rewrite the row's `state` JSON in place. This is the value
/// a manual re-commit would have written, so legacy rows then export at
/// the correct full-resolution framing without user intervention.
///
/// Properties:
/// - **No version churn.** Each touched row is updated in place
///   (`UPDATE`, not `INSERT`), so no new edit-history versions appear for
///   assets the user never opens.
/// - **Idempotent.** The `cropReferenceSize == nil` guard skips rows that
///   already carry the field, so re-running the migration is a no-op.
/// - **All versions.** Every matching version row for an asset is
///   backfilled, leaving no partially-corrected history.
func backfillCropReferenceSizes(in db: Database) throws {
    let rows = try Row.fetchAll(db, sql: """
        SELECT e.*, a.width, a.height, a.rotation
        FROM edit_states e
        JOIN assets a ON a.id = e.assetId
        """)

    for row in rows {
        let record = try EditStateRecord(row: row)
        var editState = try record.decodeState()

        guard editState.cropRect != nil, editState.cropReferenceSize == nil else {
            continue
        }

        let width: Int = row["width"]
        let height: Int = row["height"]
        let rotation: Int = row["rotation"]
        guard let referenceSize = legacyCropReferenceSize(
            width: width,
            height: height,
            rotation: rotation
        ) else {
            continue
        }

        editState.cropReferenceSize = referenceSize
        let updatedJSON = try EditStateRecord.encode(editState)
        try db.execute(
            sql: "UPDATE edit_states SET state = ? WHERE id = ?",
            arguments: [updatedJSON, record.id]
        )
    }
}
