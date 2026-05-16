import Catalog
import CoreGraphics
import Foundation

/// Pure point-manipulation helpers for the curve editor. Lifted out of
/// `CurveEditorView` so Layer A can cover insert / move / remove without
/// having to build an `NSHostingView`. All functions operate on
/// normalised `[0, 1]` coordinates — the view does the canvas-to-curve
/// conversion before calling in.
public enum CurveEditorLogic {

    /// Distance below which a click on the curve is treated as "on top
    /// of an existing handle" rather than "insert a new point here".
    public static let handleHitRadius: CGFloat = 0.03

    /// Add a point at `point.x`, snapping y onto the curve so the new
    /// point sits exactly on the existing line (lets the user drag it
    /// off afterwards without an initial visible jump). x is clamped
    /// into `(prev.x, next.x)` so monotonicity is preserved. Endpoints
    /// at x = 0 and x = 1 are never inserted next to — clicks too close
    /// to them are rejected and return the array unchanged.
    public static func insertPoint(
        into points: [CGPoint],
        at x: CGFloat
    ) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        let first = points[0]
        let last = points[points.count - 1]
        // Reject inserts too close to an endpoint — the user probably
        // meant to drag the endpoint, not create a hairline-wide segment.
        if x <= first.x + 0.001 { return points }
        if x >= last.x - 0.001 { return points }

        // Find segment, snap y to the line between p0 and p1.
        for i in 0..<(points.count - 1) {
            let p0 = points[i]
            let p1 = points[i + 1]
            if x > p0.x && x < p1.x {
                let span = p1.x - p0.x
                let t = (x - p0.x) / span
                let y = p0.y + (p1.y - p0.y) * t
                var out = points
                out.insert(CGPoint(x: x, y: y), at: i + 1)
                return out
            }
        }
        return points
    }

    /// Move the point at `index` to `target`, clamping y to `[0, 1]`
    /// and x to a value that keeps the array strictly monotonic in x.
    /// Endpoints (`index == 0` or `index == points.count - 1`) are
    /// locked in x — they only move in y.
    public static func movePoint(
        in points: [CGPoint],
        at index: Int,
        to target: CGPoint
    ) -> [CGPoint] {
        guard index >= 0, index < points.count else { return points }
        var out = points
        let y = max(0, min(1, target.y))
        if index == 0 {
            out[0] = CGPoint(x: out[0].x, y: y)
        } else if index == points.count - 1 {
            out[index] = CGPoint(x: out[index].x, y: y)
        } else {
            let prevX = out[index - 1].x
            let nextX = out[index + 1].x
            // Keep a hair gap so a future linear interpolation never
            // divides by zero on a degenerate segment.
            let eps: CGFloat = 0.001
            let clampedX = max(prevX + eps, min(nextX - eps, target.x))
            out[index] = CGPoint(x: clampedX, y: y)
        }
        return out
    }

    /// Remove the point at `index`. Endpoints (`index == 0` or
    /// `index == points.count - 1`) are protected and the array is
    /// returned unchanged.
    public static func removePoint(
        from points: [CGPoint],
        at index: Int
    ) -> [CGPoint] {
        guard points.count > 2 else { return points }
        guard index > 0, index < points.count - 1 else { return points }
        var out = points
        out.remove(at: index)
        return out
    }

    /// Find the index of the existing handle nearest to `point` whose
    /// distance is within `handleHitRadius`, or `nil` if none.
    public static func nearestHandle(
        in points: [CGPoint],
        to point: CGPoint,
        within radius: CGFloat = handleHitRadius
    ) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (i, p) in points.enumerated() {
            let dx = p.x - point.x
            let dy = p.y - point.y
            let d = sqrt(dx * dx + dy * dy)
            if d <= radius {
                if let current = best {
                    if d < current.distance {
                        best = (i, d)
                    }
                } else {
                    best = (i, d)
                }
            }
        }
        return best?.index
    }
}
