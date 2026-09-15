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

if args.count >= 3, args[1] == "--recommend-size" {
    // Diagnostic: what SizeRecommender would set as the initial Finished
    // Size for this file, matching AppState.importFile's own logic --
    // useful for checking real artwork without driving the GUI.
    let inputURL = URL(fileURLWithPath: args[2])
    let data = try Data(contentsOf: inputURL)
    let isSVG = inputURL.pathExtension.lowercased() == "svg"
    let rawShapes: [VectorShape] = isSVG
        ? try SVGImporter.importShapes(from: data).shapes
        : try ImageImporter.importShapes(from: data, maxColors: 8).shapes
    let recommended = SizeRecommender.recommendedWidthMM(for: rawShapes, currentWidthMM: 100)
    print("Recommended width for \(inputURL.lastPathComponent): \(recommended)mm")
    exit(0)
}

if args.count >= 3, args[1] == "--detect-text" {
    // Diagnostic: what TextDetector finds in a real raster file, without
    // driving the GUI's Add Lettering / review flow.
    let inputURL = URL(fileURLWithPath: args[2])
    let data = try Data(contentsOf: inputURL)
    let regions = try TextDetector.detectTextRegions(from: data)
    print("\(regions.count) text region(s) found in \(inputURL.lastPathComponent):")
    for region in regions {
        print("  \"\(region.text)\" confidence=\(String(format: "%.2f", region.confidence)) rotation=\(String(format: "%.1f", region.rotationDegrees))deg weight=\(region.suggestedWeight) box=(\(Int(region.boundingBoxPixels.minX)),\(Int(region.boundingBoxPixels.minY)))-(\(Int(region.boundingBoxPixels.maxX)),\(Int(region.boundingBoxPixels.maxY)))")
    }
    exit(0)
}

if args.count >= 5, args[1] == "--lettering-preview" {
    // Diagnostic: render real lettering (generated the same way AppState's
    // Add Lettering path does, including the run-level stitch-type
    // classification) to a PNG, without driving the GUI.
    let text = args[2]
    let fontPostScriptName = args[3]
    let outputURL = URL(fileURLWithPath: args[4])
    let fontSizeMM = args.count > 5 ? (Double(args[5]) ?? 20) : 20

    let spec = LetteringSpec(text: text, fontPostScriptName: fontPostScriptName, fontSizeMM: fontSizeMM)
    let rawShapes = try LetteringGenerator.generateShapes(spec: spec)
    var rawCombined = BoundingBox.empty
    for shape in rawShapes { rawCombined = rawCombined.union(shape.boundingBox) }
    // Center within the canvas the same way AppState.generateLetteringObjects does.
    let offsetX = -rawCombined.minX + 5, offsetY = -rawCombined.minY + 5
    let shapes = rawShapes.map { shape in
        VectorShape(subPaths: shape.subPaths.map { sp in
            SubPath(points: sp.points.map { Point2D($0.x + offsetX, $0.y + offsetY) }, closed: sp.closed)
        })
    }
    var combined = BoundingBox.empty
    for shape in shapes { combined = combined.union(shape.boundingBox) }
    let parameters = StitchGenerationParameters()
    let runType = StitchTypeClassifier.classifyLetteringRun(shapes: shapes, parameters: parameters, capHeightMM: fontSizeMM)
    print("Run stitch type: \(runType)")
    let objects = shapes.enumerated().map { i, shape -> EmbroideryObject in
        let stitchType = StitchTypeClassifier.classifyGlyphInRun(shape: shape, runStitchType: runType)
        print("  glyph \(i): subPaths=\(shape.subPaths.count) -> \(stitchType)")
        return EmbroideryObject(name: "Letter \(i)", shape: shape, stitchType: stitchType,
                                 threadColor: .generic(RGBColor(hex: 0x1144AA)), parameters: parameters)
    }
    let widthMM = combined.width + 10, heightMM = combined.height + 10
    let doc = StitchDocument(name: text, physicalWidthMM: widthMM, physicalHeightMM: heightMM, objects: objects)
    let plan = try DigitizePipeline.flatten(doc)
    print("Stitch count: \(plan.stitchCount)")
    var options = StitchRenderer.Options()
    options.pixelsPerMM = 20
    guard let pngData = StitchRenderer.renderPNGData(plan, widthMM: widthMM, heightMM: heightMM, colors: [.generic(RGBColor(hex: 0x1144AA))], options: options) else {
        print("Render failed"); exit(1)
    }
    try pngData.write(to: outputURL)
    print("Wrote \(outputURL.path)")
    exit(0)
}

guard args.count >= 3 else {
    print("Usage: DigitizeCLI <input> <output.png> [widthMM=100] [heightMM=100] [maxColors=8] [pixelsPerMM=12]")
    print("       DigitizeCLI --recommend-size <input>")
    print("       DigitizeCLI --detect-text <input>")
    print("       DigitizeCLI --lettering-preview <text> <fontPostScriptName> <output.png> [fontSizeMM=20]")
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
        var parameters = StitchGenerationParameters()
        // Diagnostic toggle, like ONLY_OBJECT/DEBUG_SATIN below: exercise the
        // branching-satin path (see DIGITIZING_ENGINE.md) against a real file
        // without changing the engine's own default.
        if ProcessInfo.processInfo.environment["ALLOW_BRANCHING_SATIN"] != nil {
            parameters.allowBranchingSatin = true
        }
        let stitchType = StitchTypeClassifier.classify(shape: fitted, parameters: parameters)
        objects.append(EmbroideryObject(name: "Object \(i + 1)", shape: fitted, stitchType: stitchType,
                                         threadColor: threadColor, parameters: parameters))
    }
    objects = StitchTypeClassifier.harmonizeSameColorFillConsistency(objects)
    objects = StitchTypeClassifier.reconcileRunningStitchOutliers(objects)
    checkpoint("Built \(objects.count) objects")

    if let onlyStr = ProcessInfo.processInfo.environment["ONLY_OBJECT"], let only = Int(onlyStr), only >= 1, only <= objects.count {
        objects = [objects[only - 1]]
        print("Isolated Object \(only): \(objects[0].stitchType.rawValue), subPaths=\(objects[0].shape.subPaths.count)")
    }

    let document = StitchDocument(name: inputURL.deletingPathExtension().lastPathComponent,
                                   physicalWidthMM: widthMM, physicalHeightMM: heightMM, objects: objects)
    let (plan, colors) = try DigitizePipeline.flattenWithColors(document)
    checkpoint("Flattened plan: \(plan.stitchCount) stitches, \(colors.count) colors")
    let report = QualityAnalyzer.analyze(plan, document: document)
    checkpoint("Quality analysis done")

    print("=== \(inputURL.lastPathComponent) ===")
    print("Objects: \(objects.count)  Stitches: \(plan.stitchCount)  Colors: \(colors.count)  Color changes: \(plan.colorChangeCount)  Trims: \(plan.trimCount)")
    print("Max stitch length: \(String(format: "%.2f", plan.maxStitchLength()))mm  Total thread: \(String(format: "%.0f", plan.totalStitchLength))mm  Est. run time: \(RunTimeEstimator.estimate(plan).formatted) at \(Int(RunTimeEstimator.defaultStitchesPerMinute)) spm")
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
        let debugThreshold = ProcessInfo.processInfo.environment["DEBUG_SATIN"] != nil ? 3.0 : 12.5
        let longest = segments.sorted { $0.length > $1.length }.prefix(15)
        if let worst = longest.first, worst.length > debugThreshold {
            print("--- longest stitch segments ---")
            for s in longest {
                print(String(format: "  %.2fmm: (%.3f, %.3f) -> (%.3f, %.3f)", s.length, s.from.x, s.from.y, s.to.x, s.to.y))
            }
        }
    }
    for object in objects {
        let box = object.shape.boundingBox
        print(String(format: "  - %@: %@, color %@, bbox=(%.1f,%.1f)-(%.1f,%.1f)",
                      object.name, object.stitchType.rawValue, object.threadColor.name, box.minX, box.minY, box.maxX, box.maxY))
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
