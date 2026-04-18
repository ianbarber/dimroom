import AppKit
import Catalog
import CoreImage
import EditEngine
import Foundation
import Previews

@MainActor
public final class DevelopViewModel: ObservableObject {
    @Published public private(set) var editState: EditState = EditState()
    @Published public private(set) var renderedImage: NSImage?
    @Published public private(set) var isRendering: Bool = false
    public private(set) var currentAssetId: UUID?

    private var catalog: CatalogDatabase
    private var previewStore: PreviewStore
    private var sourceImage: CIImage?
    private let ciContext = CIContext()
    private var renderTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    public init(catalog: CatalogDatabase, previewStore: PreviewStore) {
        self.catalog = catalog
        self.previewStore = previewStore
    }

    public func configure(catalog: CatalogDatabase, previewStore: PreviewStore) {
        self.catalog = catalog
        self.previewStore = previewStore
    }

    public func activate(assetId: UUID?) async {
        guard let assetId else { return }
        guard let asset = try? catalog.fetchAsset(id: assetId) else { return }

        let previewURL = previewStore.previewURL(for: asset)
        guard let url = previewURL,
              let source = CIImage(contentsOf: url) else {
            currentAssetId = assetId
            editState = (try? catalog.latestEditState(for: assetId)) ?? EditState()
            return
        }

        sourceImage = source
        currentAssetId = assetId
        editState = (try? catalog.latestEditState(for: assetId)) ?? EditState()
        triggerRender()
    }

    public func deactivate() {
        renderTask?.cancel()
        saveTask?.cancel()
        renderTask = nil
        saveTask = nil
        sourceImage = nil
        renderedImage = nil
        currentAssetId = nil
        editState = EditState()
    }

    public func setParameter(_ keyPath: WritableKeyPath<EditState, Double>, value: Double) {
        editState[keyPath: keyPath] = value
        scheduleRender()
        scheduleSave()
    }

    public func resetParameter(_ keyPath: WritableKeyPath<EditState, Double>) {
        let identity = Self.identityValue(for: keyPath)
        setParameter(keyPath, value: identity)
    }

    nonisolated public static func keyPath(forParameter name: String) -> WritableKeyPath<EditState, Double>? {
        switch name {
        case "exposure": return \.exposure
        case "contrast": return \.contrast
        case "highlights": return \.highlights
        case "shadows": return \.shadows
        case "whites": return \.whites
        case "blacks": return \.blacks
        case "temperature": return \.temperature
        case "tint": return \.tint
        case "clarity": return \.clarity
        case "vibrance": return \.vibrance
        case "saturation": return \.saturation
        default: return nil
        }
    }

    // MARK: - Private

    private static func identityValue(for keyPath: WritableKeyPath<EditState, Double>) -> Double {
        if keyPath == \EditState.temperature { return 6500 }
        return 0
    }

    private func scheduleRender() {
        renderTask?.cancel()
        renderTask = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            await performRender()
        }
    }

    private func triggerRender() {
        renderTask?.cancel()
        renderTask = Task {
            await performRender()
        }
    }

    private func performRender() async {
        guard let source = sourceImage else { return }
        let state = editState
        isRendering = true

        let result: NSImage? = await Task.detached(priority: .userInitiated) { [ciContext] in
            let output = Renderer.render(source: source, editState: state)
            guard let cgImage = ciContext.createCGImage(output, from: output.extent) else {
                return nil
            }
            let size = NSSize(width: cgImage.width, height: cgImage.height)
            return NSImage(cgImage: cgImage, size: size)
        }.value

        guard !Task.isCancelled else { return }
        renderedImage = result
        isRendering = false
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            guard let assetId = currentAssetId else { return }
            _ = try? catalog.saveEditState(editState, for: assetId)
        }
    }
}
