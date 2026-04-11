# Previews

Thumbnail and preview generation for imported assets. Maintains a single decode-per-asset pipeline to efficiently produce display-ready images at multiple resolutions without re-reading originals from disk or Drive.

## Public API

- `PreviewStore(cacheDirectory:)` — an `actor` that owns a Core Image context and serialises preview generation against the supplied cache directory.
- `PreviewStore.generate(for:sourceURL:)` — decodes `sourceURL` once (via `CIRAWFilter` for RAW, `CIImage(contentsOf:)` otherwise), applies `Asset.rotation`, writes JPEGs for both sizes, and returns a `PreviewSet`. Idempotent: if both cached files already exist for the asset's `contentHash`, the call short-circuits without touching Core Image.
- `PreviewStore.thumbnailURL(for:)` / `previewURL(for:)` — `nonisolated` filesystem lookups that return the cached JPEG URL (or `nil` if not yet generated).

## Sizes

Two fixed sizes, chosen to serve the Library grid and Loupe view respectively:

| Kind      | Long edge | Filename tag |
|-----------|-----------|--------------|
| thumbnail | 256 px    | `thumb`      |
| preview   | 2048 px   | `preview`    |

Output is JPEG at quality 0.85, aspect ratio preserved, scaled with Lanczos. Cached files are **pre-rotated** to honour `Asset.rotation` so views never rotate on the render thread.

## Cache layout

```
<cacheDirectory>/
  <first-2-chars-of-contentHash>/
    <contentHash>.thumb.jpg
    <contentHash>.preview.jpg
```

The two-character shard keeps any single directory from accumulating tens of thousands of files.
