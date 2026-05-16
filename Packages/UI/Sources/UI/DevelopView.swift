import Catalog
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
                cropToggle

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

            sliderSection("Noise Reduction") {
                slider("Luminance", keyPath: \.luminanceNoiseReduction, range: 0...100, step: 1, identity: 0)
                slider("Chrominance", keyPath: \.chrominanceNoiseReduction, range: 0...100, step: 1, identity: 0)
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

    private var cropToggle: some View {
        Button {
            if cropViewModel.isActive {
                viewModel.commitCropFromViewModel()
            } else {
                viewModel.enterCropMode()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "crop.rotate")
                Text(cropViewModel.isActive ? "Done" : "Crop")
                    .font(.system(size: 12, weight: .medium))
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
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .center) {
                        if cropViewModel.isActive {
                            GeometryReader { geo in
                                CropOverlayView(viewModel: cropViewModel)
                                    .frame(width: geo.size.width, height: geo.size.height)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
