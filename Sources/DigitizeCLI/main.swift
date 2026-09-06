import Foundation
import StitchPilotCore

// A no-GUI harness around the exact digitizing pipeline the app uses --
// see Package.swift's comment on this target for why it exists. Renders a
// PNG approximation of the sewn-out result via StitchRenderer alongside a
// quality report, so digitizing quality can be inspected and regression-
// tested without driving the SwiftUI app itself.
//
// Usage: DigitizeCLI <input file> <output.png> [widthMM] [heightMM] [maxColors] [pixelsPerMM]

setbuf(stdout, nil)

let args = CommandLine.arguments

if args.count >= 3, args[1] == "--validate-formats" {
    // One-off cross-validation pass: read every real-world DST/PES file
    // under a directory (e.g. a clone of EmbroidePy/samples) with
    // StitchPilot's own readers and report which fail. Not the normal
    // digitize-artwork path this tool otherwise exercises -- see
    // ThirdPartySampleTests.swift for the permanent, vendored-fixture
    // version of this same idea.
    let dir = URL(fileURLWithPath: args[2])
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    var passed = 0, failed = 0
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let ext = file.pathExtension.lowercased()
        guard ext == "dst" || ext == "pes" else { continue }
        do {
            let data = try Data(contentsOf: file)
            let commands = ext == "dst" ? try DSTFormat.read(data).commands : try PESFormat.read(data).commands
            let stitchCount = commands.filter { if case .stitch = $0 { return true }; return false }.count
            let box = BoundingBox(points: commands.compactMap { $0.point })
            let sane = stitchCount > 0 && box.width > 0 && box.width < 1000 && box.height > 0 && box.height < 1000
            if sane {
                passed += 1
            } else {
                failed += 1
                print("SUSPECT \(file.lastPathComponent): stitches=\(stitchCount) box=\(box.width)x\(box.height)")
            }
        } catch {
            failed += 1
            print("FAIL \(file.lastPathComponent): \(error)")
        }
    }
    print("--- \(passed) passed, \(failed) failed/suspect ---")
    exit(failed == 0 ? 0 : 1)
}

guard args.count >= 3 else {
    print("Usage: DigitizeCLI <input> <output.png> [widthMM=100] [heightMM=100] [maxColors=8] [pixelsPerMM=12]")
    exit(1)
}

let startTime = Date()
func checkpoint(_ label: String) {
    print(String(format: "[%.2fs] %@", Date().timeIntervalSince(startTime), label))
}

let inputURL = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])
let widthMM = args.count > 3 ? (Double(args[3]) ?? 100) : 100
let heightMM = args.count > 4 ? (Double(args[4]) ?? 100) : 100
let maxColors = args.count > 5 ? (Int(args[5]) ?? 8) : 8
let pixelsPerMM = args.count > 6 ? (Double(args[6]) ?? 12) : 12

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

do {
    let data = try Data(contentsOf: inputURL)
    let isSVG = inputURL.pathExtension.lowercased() == "svg"

    let rawShapes: [VectorShape]
    let fillColors: [RGBColor?]
    if isSVG {
        let result = try SVGImporter.importShapes(from: data)
        rawShapes = result.shapes
        fillColors = result.fillColors
    } else {
        let result = try ImageImporter.importShapes(from: data, maxColors: maxColors)
        rawShapes = result.shapes
        fillColors = result.fillColors
    }
    guard !rawShapes.isEmpty else { fail("No usable shapes found in \(inputURL.lastPathComponent).") }
    checkpoint("Imported \(rawShapes.count) raw shapes")

    var combined = BoundingBox.empty
    for shape in rawShapes { combined = combined.union(shape.boundingBox) }

    var objects: [EmbroideryObject] = []
    for (i, shape) in rawShapes.enumerated() {
        let fitted = shape.fitToPhysicalSize(widthMM: widthMM, heightMM: heightMM, within: combined)
        let detectedRGB = (i < fillColors.count ? fillColors[i] : nil) ?? RGBColor(hex: 0x000000)
        let threadColor = ThreadLibrary.nearestMatch(to: detectedRGB) ?? .generic(detectedRGB)
        let parameters = StitchGenerationParameters()
        let stitchType = StitchTypeClassifier.classify(shape: fitted, parameters: parameters)
        objects.append(EmbroideryObject(name: "Object \(i + 1)", shape: fitted, stitchType: stitchType,
                                         threadColor: threadColor, parameters: parameters))
    }
    checkpoint("Built \(objects.count) objects")

    if let onlyStr = ProcessInfo.processInfo.environment["ONLY_OBJECT"], let only = Int(onlyStr), only >= 1, only <= objects.count {
        objects = [objects[only - 1]]
        print("Isolated Object \(only): \(objects[0].stitchType.rawValue), subPaths=\(objects[0].shape.subPaths.count)")
    }

    let document = StitchDocument(name: inputURL.deletingPathExtension().lastPathComponent,
                                   physicalWidthMM: widthMM, physicalHeightMM: heightMM, objects: objects)
    let (plan, colors) = try DigitizePipeline.flattenWithColors(document)
    checkpoint("Flattened plan: \(plan.stitchCount) stitches, \(colors.count) colors")
    let report = QualityAnalyzer.analyze(plan)
    checkpoint("Quality analysis done")

    print("=== \(inputURL.lastPathComponent) ===")
    print("Objects: \(objects.count)  Stitches: \(plan.stitchCount)  Colors: \(colors.count)  Color changes: \(plan.colorChangeCount)  Trims: \(plan.trimCount)")
    print("Max stitch length: \(String(format: "%.2f", plan.maxStitchLength()))mm  Total thread: \(String(format: "%.0f", plan.totalStitchLength))mm")
    print("Readiness: \(report.score)/100 (\(report.isReadyToSew ? "Ready to Sew" : "Review Recommended"))")
    for issue in report.issues {
        print("  [\(issue.severity.rawValue)] \(issue.message)")
    }
    // The longest few needle-penetrating segments, so a suspiciously large
    // `maxStitchLength()` (an unintended jump-as-stitch, not a real design
    // feature) can be traced back to *where* in the design it happens.
    do {
        var segments: [(from: Point2D, to: Point2D, length: Double)] = []
        var last: Point2D?
        for command in plan.commands {
            switch command {
            case .stitch(let p):
                if let l = last { segments.append((l, p, l.distance(to: p))) }
                last = p
            case .jump(let p):
                last = p
            case .colorChange, .trim, .stop:
                last = nil
            case .end:
                break
            }
        }
        let longest = segments.sorted { $0.length > $1.length }.prefix(5)
        if let worst = longest.first, worst.length > 12.5 {
            print("--- longest stitch segments ---")
            for s in longest {
                print(String(format: "  %.2fmm: (%.3f, %.3f) -> (%.3f, %.3f)", s.length, s.from.x, s.from.y, s.to.x, s.to.y))
            }
        }
    }
    for object in objects {
        print("  - \(object.name): \(object.stitchType.rawValue), color \(object.threadColor.name)")
    }

    var renderOptions = StitchRenderer.Options()
    renderOptions.pixelsPerMM = pixelsPerMM
    guard let pngData = StitchRenderer.renderPNGData(plan, widthMM: widthMM, heightMM: heightMM, colors: colors, options: renderOptions) else {
        fail("Rendering failed.")
    }
    try pngData.write(to: outputURL)
    print("Wrote \(outputURL.path)")
} catch {
    fail("Error: \(error)")
}
