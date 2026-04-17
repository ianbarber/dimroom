import AppIcon
import Foundation

struct IconSetEntry {
    let baseName: String
    let pixelSize: Int
}

let iconSetEntries: [IconSetEntry] = [
    .init(baseName: "icon_16x16", pixelSize: 16),
    .init(baseName: "icon_16x16@2x", pixelSize: 32),
    .init(baseName: "icon_32x32", pixelSize: 32),
    .init(baseName: "icon_32x32@2x", pixelSize: 64),
    .init(baseName: "icon_128x128", pixelSize: 128),
    .init(baseName: "icon_128x128@2x", pixelSize: 256),
    .init(baseName: "icon_256x256", pixelSize: 256),
    .init(baseName: "icon_256x256@2x", pixelSize: 512),
    .init(baseName: "icon_512x512", pixelSize: 512),
    .init(baseName: "icon_512x512@2x", pixelSize: 1024),
]

func parseArguments() -> URL {
    let args = CommandLine.arguments
    guard let idx = args.firstIndex(of: "--output"), idx + 1 < args.count else {
        fputs("Usage: dimroom-icongen --output <directory>\n", stderr)
        exit(1)
    }
    return URL(fileURLWithPath: args[idx + 1])
}

let outputDir = parseArguments()

let fm = FileManager.default
try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

for entry in iconSetEntries {
    let image = AppIconRenderer.render(pixelSize: entry.pixelSize)
    let url = outputDir.appendingPathComponent("\(entry.baseName).png")
    try IconWriter.writePNG(image, to: url)
    print("  \(entry.baseName).png (\(entry.pixelSize)x\(entry.pixelSize))")
}

let masterImage = AppIconRenderer.render(pixelSize: 1024)
let masterURL = outputDir.appendingPathComponent("icon_1024.png")
try IconWriter.writePNG(masterImage, to: masterURL)
print("  icon_1024.png (1024x1024 master)")

print("Done. \(iconSetEntries.count + 1) files written to \(outputDir.path)")
