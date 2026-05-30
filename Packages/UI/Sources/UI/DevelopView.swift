import Catalog
import EditEngine
import SwiftUI

public struct DevelopView: View {
    @ObservedObject private var viewModel: DevelopViewModel
    @ObservedObject private var cropViewModel: CropViewModel

    public init(viewModel: DevelopViewModel) {
        self.viewModel = viewModel
        self.cropViewModel = viewModel.cropViewModel
    }

    public var body: some View {
        Group {
            if viewModel.currentAssetId != nil {
                HStack(spacing: 0) {
                    sliderSidebar
                    preview
                }
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.05))
        .focusable()
        .onKeyPress(.return) {
            if cropViewModel.isActive {
                viewModel.commitCropFromViewModel()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.escape) {
            if cropViewModel.isActive {
                viewModel.cancelCrop()
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Sidebar

    private var sliderSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    cropToggle
                    magnifierToggle
                }

                if cropViewModel.isActive {
                    cropSection
                }

                sliderColumn
            }
            .padding(12)
        }
        .frame(width: 280)
        .background(Color(white: 0.1))
        .disabled(viewModel.isDownloadingOriginal)
    }

    /// Toggle the floating pixel magnifier. Sits next to the crop button so
    /// the two workspace tools share a row at the top of the sidebar.
    private var magnifierToggle: some View {
        Button {
            viewModel.toggleMagnifier()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.magnifyingglass")
                Text("Magnifier")
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .tint(viewModel.magnifierVisible ? .accentColor : Color(white: 0.3))
        .accessibilityIdentifier("magnifier-toggle")
    }

    /// Tone + White Balance + Presence slider stack. Animated on
    /// `replaySequence` so undo/redo tweens the bound values, while
    /// interactive drags (which do not bump `replaySequence`) stay
    /// instant.
    private var sliderColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            sliderSection("Tone") {
                slider("Exposure", keyPath: \.exposure, range: -5.0...5.0, step: 0.01, identity: 0)
                slider("Contrast", keyPath: \.contrast, range: -100...100, step: 1, identity: 0)
                slider("Highlights", keyPath: \.highlights, range: -100...100, step: 1, identity: 0)
                slider("Shadows", keyPath: \.shadows, range: -100...100, step: 1, identity: 0)
                slider("Whites", keyPath: \.whites, range: -100...100, step: 1, identity: 0)
                slider("Blacks", keyPath: \.blacks, range: -100...100, step: 1, identity: 0)
            }

            sliderSection("White Balance") {
                slider("Temperature", keyPath: \.temperature, range: 2000...12000, step: 50, identity: 6500)
                slider("Tint", keyPath: \.tint, range: -150...150, step: 1, identity: 0)
            }

            sliderSection("Presence") {
                slider("Clarity", keyPath: \.clarity, range: -100...100, step: 1, identity: 0)
                slider("Sharpening", keyPath: \.sharpening, range: 0...100, step: 1, identity: 0)
                slider("Vibrance", keyPath: \.vibrance, range: -100...100, step: 1, identity: 0)
                slider("Saturation", keyPath: \.saturation, range: -100...100, step: 1, identity: 0)
            }

            curvesSection

            sliderSection("Noise Reduction") {
                slider("Luminance", keyPath: \.luminanceNoiseReduction, range: 0...100, step: 1, identity: 0)
                slider("Chrominance", keyPath: \.chrominanceNoiseReduction, range: 0...100, step: 1, identity: 0)
            }

            hslSection

            sliderSection("Split Toning") {
                slider("Balance", keyPath: \.splitToneBalance, range: -100...100, step: 1, identity: 0)
                splitToneWheel(
                    label: "Highlights",
                    hueKey: \.splitToneHighlightHue,
                    satKey: \.splitToneHighlightSaturation
                )
                splitToneWheel(
                    label: "Shadows",
                    hueKey: \.splitToneShadowHue,
                    satKey: \.splitToneShadowSaturation
                )
            }

            sliderSection("Vignette") {
                slider("Amount", keyPath: \.vignetteAmount, range: -100...100, step: 1, identity: 0)
                slider("Roundness", keyPath: \.vignetteRoundness, range: 0...100, step: 1, identity: 50)
                slider("Softness", keyPath: \.vignetteSoftness, range: 0...100, step: 1, identity: 50)
            }

            sliderSection("Geometry") {
                slider("Vertical", keyPath: \.perspectiveVertical, range: -100...100, step: 1, identity: 0)
                slider("Horizontal", keyPath: \.perspectiveHorizontal, range: -100...100, step: 1, identity: 0)
                slider("Rotation", keyPath: \.perspectiveRotation, range: -180...180, step: 0.1, identity: 0)
                flagToggle("Chromatic Aberration", keyPath: \.chromaticAberration)
                flagToggle("Lens Vignette", keyPath: \.lensVignette)
            }
        }
        .animation(.easeOut(duration: 0.25), value: viewModel.replaySequence)
    }

    private var hslSection: some View {
        HSLPanelView(
            value: { axis, index in viewModel.hslValue(axis: axis, rangeIndex: index) },
            setValue: { axis, index, value in
                viewModel.setHSLParameter(axis: axis, rangeIndex: index, value: value)
            },
            reset: { axis, index in
                viewModel.resetHSLParameter(axis: axis, rangeIndex: index)
            }
        )
    }

    private var cropToggle: some View {
        Button {
            if cropViewModel.isActive {
                viewModel.commitCropFromViewModel()
            } else {
                viewModel.enterCropMode()
            }
        } label: {
            // Why: `.foregroundStyle(.white)` must sit on each child here —
            // not on the enclosing HStack — because a `.bordered` Button on a
            // dark `.tint` renders its label in the (dark) tint colour, which
            // is the black-on-dark-gray bug. `ImageRenderer` propagates a
            // container-level foreground into the label subtree, so an offline
            // snapshot can't catch a regression; CropControlsStructureTests is
            // the structural guard. Same class as #74 (scope picker) / #241.
            HStack(spacing: 6) {
                Image(systemName: "crop.rotate")
                    .foregroundStyle(.white)
                Text(cropViewModel.isActive ? "Done" : "Crop")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .tint(cropViewModel.isActive ? .accentColor : Color(white: 0.3))
    }

    private var cropSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Crop")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(white: 0.5))
                .textCase(.uppercase)

            Picker(
                "Aspect",
                selection: Binding(
                    get: { cropViewModel.selectedPreset },
                    set: { cropViewModel.applyPreset($0) }
                )
            ) {
                ForEach(AspectRatioPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            // `.tint(.white)` lights the popup's chevron / selection indicator
            // and `.foregroundStyle(.white)` the selected-value label, both of
            // which otherwise inherit a near-black colour against the dark
            // sidebar (#319). Same residual-AppKit-control class as #74 / #241.
            .tint(.white)
            .foregroundStyle(.white)
            .accessibilityIdentifier("crop-aspect-picker")

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Straighten")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.7))
                    Spacer()
                    Text(String(format: "%+.1f°", cropViewModel.cropAngle))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(white: 0.5))
                }
                Slider(
                    value: Binding(
                        get: { cropViewModel.cropAngle },
                        set: { viewModel.setCropAngleLive($0) }
                    ),
                    in: -45...45,
                    step: 0.1
                )
            }
        }
    }

    // MARK: - Curves

    /// Curves group with Luminance / R / G / B channel switcher and a
    /// canvas editor for the active channel. Positioned between
    /// Presence and Vignette so the visually heavy editor sits below
    /// the lightweight slider groups while still preceding Vignette in
    /// the chain order ("after contrast/clarity, before vignette").
    private var curvesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Curves")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(white: 0.5))
                .textCase(.uppercase)

            Picker(
                "Channel",
                selection: Binding(
                    get: { viewModel.selectedCurveChannel },
                    set: { viewModel.selectedCurveChannel = $0 }
                )
            ) {
                ForEach(CurveChannel.allCases, id: \.self) { channel in
                    Text(channel.displayName).tag(channel)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("curve-channel-picker")

            CurveEditorView(
                channel: viewModel.selectedCurveChannel,
                points: viewModel.editState[keyPath: viewModel.selectedCurveChannel.keyPath],
                histogram: viewModel.histogram,
                onChange: { newPoints in
                    viewModel.setCurvePoints(viewModel.selectedCurveChannel, points: newPoints)
                },
                onReset: {
                    viewModel.resetCurve(viewModel.selectedCurveChannel)
                }
            )
        }
    }

    private func sliderSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(white: 0.5))
                .textCase(.uppercase)
            content()
        }
    }

    private func slider(
        _ label: String,
        keyPath: WritableKeyPath<EditState, Double>,
        range: ClosedRange<Double>,
        step: Double,
        identity: Double
    ) -> some View {
        ParameterSlider(
            label: label,
            range: range,
            step: step,
            identity: identity,
            value: Binding(
                get: { viewModel.editState[keyPath: keyPath] },
                set: { viewModel.setParameter(keyPath, value: $0) }
            ),
            onReset: { viewModel.resetParameter(keyPath) }
        )
    }

    private func splitToneWheel(
        label: String,
        hueKey: WritableKeyPath<EditState, Double>,
        satKey: WritableKeyPath<EditState, Double>
    ) -> some View {
        ColorWheelControl(
            label: label,
            hue: viewModel.editState[keyPath: hueKey],
            saturation: viewModel.editState[keyPath: satKey],
            onHueChange: { viewModel.setParameter(hueKey, value: $0) },
            onSaturationChange: { viewModel.setParameter(satKey, value: $0) },
            onReset: {
                viewModel.resetParameter(hueKey)
                viewModel.resetParameter(satKey)
            }
        )
    }

    private func flagToggle(
        _ label: String,
        keyPath: WritableKeyPath<EditState, Bool>
    ) -> some View {
        Toggle(
            isOn: Binding(
                get: { viewModel.editState[keyPath: keyPath] },
                set: { viewModel.setFlag(keyPath, value: $0) }
            )
        ) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.85))
        }
        .toggleStyle(.checkbox)
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack(alignment: .bottomLeading) {
            Color(white: 0.05)
                .ignoresSafeArea()

            if let image = viewModel.renderedImage {
                GeometryReader { geo in
                    let imageRect = Self.fittedRect(
                        frame: geo.size,
                        sourceAspect: previewSourceAspect(fallback: image)
                    )
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: imageRect.width, height: imageRect.height)
                            .offset(x: imageRect.minX, y: imageRect.minY)
                            .overlay(alignment: .topLeading) {
                                if cropViewModel.isActive {
                                    CropOverlayView(
                                        viewModel: cropViewModel,
                                        // Route rotate-handle drags through the
                                        // same live-render path as the straighten
                                        // slider (line ~197) so the preview
                                        // updates and debounces identically.
                                        onAngleChange: { viewModel.setCropAngleLive($0) }
                                    )
                                    .frame(width: imageRect.width, height: imageRect.height)
                                    .offset(x: imageRect.minX, y: imageRect.minY)
                                }
                            }

                        // Magnifier sample-region reticle + click/drag to
                        // move the sample point. Suppressed while the crop
                        // overlay owns the preview's gestures.
                        if viewModel.magnifierVisible && !cropViewModel.isActive {
                            magnifierSampleLayer(imageRect: imageRect)
                        }
                    }
                }
            }

            if viewModel.showHistogram, let data = viewModel.histogram {
                HistogramOverlayView(data: data)
                    .padding(12)
            }

            if viewModel.isDownloadingOriginal {
                DownloadIndicatorView(progress: viewModel.downloadProgress)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            if viewModel.magnifierVisible {
                PixelMagnifierView(viewModel: viewModel)
                    .offset(
                        x: viewModel.magnifierWindowOffset.width,
                        y: viewModel.magnifierWindowOffset.height
                    )
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Transparent hit layer over the fitted image that maps a click or
    /// drag to a normalised sample point, plus the reticle showing the
    /// region the magnifier is currently sampling.
    private func magnifierSampleLayer(imageRect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: imageRect.width, height: imageRect.height)
                .offset(x: imageRect.minX, y: imageRect.minY)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard imageRect.width > 0, imageRect.height > 0 else { return }
                            let nx = (value.location.x - imageRect.minX) / imageRect.width
                            let ny = (value.location.y - imageRect.minY) / imageRect.height
                            viewModel.setMagnifierSamplePoint(CGPoint(x: nx, y: ny))
                        }
                )

            if let reticle = viewModel.magnifierReticleRect {
                Rectangle()
                    .stroke(Color.yellow, lineWidth: 1.5)
                    .background(Rectangle().stroke(Color.black.opacity(0.5), lineWidth: 3))
                    .frame(
                        width: max(reticle.width * imageRect.width, 6),
                        height: max(reticle.height * imageRect.height, 6)
                    )
                    .offset(
                        x: imageRect.minX + reticle.minX * imageRect.width,
                        y: imageRect.minY + reticle.minY * imageRect.height
                    )
                    .allowsHitTesting(false)
            }
        }
    }

    /// Aspect ratio of the source image the Develop pipeline is rendering
    /// from. Prefers `viewModel.sourceImageSize` (the CIImage extent the
    /// renderer is fed) because the rendered `NSImage` may already have
    /// been cropped by the EditState — falling back to the rendered image
    /// when the view model has no source set keeps the overlay sized
    /// sensibly during the brief window before the first preview load.
    private func previewSourceAspect(fallback image: NSImage) -> Double {
        if let size = viewModel.sourceImageSize, size.width > 0, size.height > 0 {
            return Double(size.width / size.height)
        }
        if image.size.width > 0, image.size.height > 0 {
            return Double(image.size.width / image.size.height)
        }
        return 1.0
    }

    /// Compute the `aspectRatio(.fit)` letterboxed rect for an image of
    /// `sourceAspect` inside `frame`. The crop overlay must bind to this
    /// rect (not the full frame) so normalised crop coordinates map onto
    /// the pixels the user actually sees — otherwise a 1:1 crop on a
    /// non-square frame would draw landscape (issue #239 bugs 1 & 3).
    static func fittedRect(frame: CGSize, sourceAspect: Double) -> CGRect {
        guard frame.width > 0, frame.height > 0, sourceAspect > 0 else {
            return CGRect(origin: .zero, size: frame)
        }
        let frameAspect = Double(frame.width / frame.height)
        let width: CGFloat
        let height: CGFloat
        if sourceAspect > frameAspect {
            width = frame.width
            height = CGFloat(Double(frame.width) / sourceAspect)
        } else {
            height = frame.height
            width = CGFloat(Double(frame.height) * sourceAspect)
        }
        let originX = (frame.width - width) / 2
        let originY = (frame.height - height) / 2
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    // MARK: - Placeholder

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color(white: 0.35))
            Text("Select a photo first")
                .font(.headline)
                .foregroundStyle(Color(white: 0.55))
        }
    }
}
