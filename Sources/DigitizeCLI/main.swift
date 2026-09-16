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

/// A structural profile of a stitch plan, printed the same way for a file
/// we generated and for a professionally digitized one, so the two can be
/// compared number for number (see the "professional samples" entry in
/// DIGITIZING_ENGINE.md). Per colour run: stitch count, mean stitch length,
/// and the share of stitches that reverse direction against the previous
/// one -- a satin column reverses on every stitch (zigzag), a fill only at
/// row ends, a running stitch almost never -- which is enough to tell how
/// much of a design a digitizer chose to sew as satin without any object
/// information.
func printProfile(_ plan: StitchPlan) {
    var runs: [(stitches: Int, lengthSum: Double, reversals: Int, pairs: Int, lengths: [Double])] = []
    var current: (stitches: Int, lengthSum: Double, reversals: Int, pairs: Int, lengths: [Double]) = (0, 0, 0, 0, [])
    var last: Point2D? = nil
    var lastDir: Point2D? = nil
    var allLengths: [Double] = []
    for command in plan.commands {
        switch command {
        case .stitch(let p):
            current.stitches += 1
            if let l = last {
                let d = Point2D(p.x - l.x, p.y - l.y)
                let len = l.distance(to: p)
                if len > 0.05 {
                    current.lengthSum += len; current.lengths.append(len); allLengths.append(len)
                    if let ld = lastDir {
                        let dot = (d.x * ld.x + d.y * ld.y) / (len * max(1e-9, ld.distance(to: .zero)))
                        current.pairs += 1
                        if dot < -0.5 { current.reversals += 1 }
                    }
                    lastDir = d
                }
            }
            last = p
        case .jump(let p):
            last = p; lastDir = nil
        case .colorChange:
            runs.append(current); current = (0, 0, 0, 0, []); last = nil; lastDir = nil
        case .trim, .stop:
            last = nil; lastDir = nil
        case .end:
            break
        }
    }
    if current.stitches > 0 { runs.append(current) }
    let box = BoundingBox(points: plan.commands.compactMap { $0.point })
    let sorted = allLengths.sorted()
    func pct(_ q: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
    print(String(format: "Profile: %d stitches, %d colour runs, %d trims, %.1f x %.1f mm, %.0f mm thread",
                 plan.stitchCount, runs.count, plan.trimCount, box.width, box.height, plan.totalStitchLength))
    print(String(format: "  stitch length p10/p50/p90/max: %.2f / %.2f / %.2f / %.2f mm", pct(0.1), pct(0.5), pct(0.9), sorted.last ?? 0))
    let area = max(1, box.width * box.height)
    print(String(format: "  stitches per mm² of bbox: %.2f", Double(plan.stitchCount) / area))
    var satinish = 0
    for (i, r) in runs.enumerated() {
        let rev = r.pairs > 0 ? Double(r.reversals) / Double(r.pairs) : 0
        let mean = r.lengths.isEmpty ? 0 : r.lengthSum / Double(r.lengths.count)
        let kind = rev > 0.8 ? "satin-like" : rev > 0.25 ? "mixed" : mean > 2.0 && rev < 0.25 ? "fill/run" : "fill"
        if rev > 0.8 { satinish += r.stitches }
        print(String(format: "  run %2d: %6d st  mean %.2f mm  reversal %.0f%%  %@", i + 1, r.stitches, mean, rev * 100, kind))
    }
    print(String(format: "  satin-like share of stitches: %.0f%%", plan.stitchCount > 0 ? Double(satinish) / Double(plan.stitchCount) * 100 : 0))
}

if args.count >= 4, args[1] == "--analyze" {
    // Diagnostic: read a finished DST/PES (e.g. a professionally digitized
    // sample), print its structural profile, and render it with our own
    // renderer so it can sit beside our result for the same artwork.
    let inputURL = URL(fileURLWithPath: args[2])
    let outputURL = URL(fileURLWithPath: args[3])
    let ppm = args.count > 4 ? (Double(args[4]) ?? 12) : 12
    let data = try Data(contentsOf: inputURL)
    let ext = inputURL.pathExtension.lowercased()
    let decodedCommands = ext == "dst" ? try DSTFormat.read(data).commands : try PESFormat.read(data).commands
    let box = BoundingBox(points: decodedCommands.compactMap { $0.point })
    let margin = 3.0
    // The readers hand back document space (Y-down), so only a shift to a
    // positive origin is needed. If a machine file ever renders upside-down
    // here, that reader's Y sign is wrong -- see DSTFormat's coordinate note.
    let shifted = decodedCommands.map { command -> StitchCommand in
        switch command {
        case .stitch(let p): return .stitch(Point2D(p.x - box.minX + margin, p.y - box.minY + margin))
        case .jump(let p): return .jump(Point2D(p.x - box.minX + margin, p.y - box.minY + margin))
        default: return command
        }
    }
    let plan = StitchPlan(commands: shifted)
    print("=== \(inputURL.lastPathComponent) ===")
    printProfile(plan)
    // The readers don't carry thread colours, so each run gets a distinct
    // colour from a fixed palette: structure is what's being compared.
    let palette: [UInt32] = [0x2f5d3a, 0x8a2c2c, 0x2c4f8a, 0xc08a2a, 0x6a3a8a, 0x2a8a8a, 0x8a5a2a, 0x555555, 0xb04a8a, 0x4a8a3a]
    let runCount = plan.colorChangeCount + 1
    let colors = (0..<runCount).map { ThreadColor.generic(RGBColor(hex: palette[$0 % palette.count])) }
    var options = StitchRenderer.Options()
    options.pixelsPerMM = ppm
    guard let png = StitchRenderer.renderPNGData(plan, widthMM: box.width + 2 * margin, heightMM: box.height + 2 * margin, colors: colors, options: options) else {
        print("Render failed"); exit(1)
    }
    try png.write(to: outputURL)
    print("Wrote \(outputURL.path)")
    exit(0)
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
    var fittedPieces: [[VectorShape]] = rawShapes.map { [$0.fitToPhysicalSize(widthMM: widthMM, heightMM: heightMM, within: combined)] }
    if isSVG {
        // Vector fills overlap back to front; sew each region once (C2).
        fittedPieces = DesignFinishing.removeOverlaps(fittedPieces.map { $0[0] }, opaque: fillColors.map { $0 != nil })
    }
    for (i, pieces) in fittedPieces.enumerated() {
      for (pieceIndex, fitted) in pieces.enumerated() {
        let detectedRGB = (i < fillColors.count ? fillColors[i] : nil) ?? RGBColor(hex: 0x000000)
        let threadColor = ThreadLibrary.nearestMatch(to: detectedRGB) ?? .generic(detectedRGB)
        var parameters = StitchGenerationParameters()
        // Diagnostic toggle, like ONLY_OBJECT/DEBUG_SATIN below: exercise the
        // branching-satin path (see DIGITIZING_ENGINE.md) against a real file
        // without changing the engine's own default.
        if ProcessInfo.processInfo.environment["ALLOW_BRANCHING_SATIN"] != nil {
            parameters.allowBranchingSatin = true
        }
        // UNDERLAY=none (any UnderlayType raw value): force every object's underlay.
        if let raw = ProcessInfo.processInfo.environment["UNDERLAY"], let underlay = UnderlayType(rawValue: raw) {
            parameters.underlayType = underlay
        }
        // FABRIC=terry (any FabricType raw value): sew as if on that fabric.
        if let raw = ProcessInfo.processInfo.environment["FABRIC"], let fabric = FabricType(rawValue: raw) {
            parameters.fabricType = fabric
        }
        let stitchType = StitchTypeClassifier.classify(shape: fitted, parameters: parameters)
        if ProcessInfo.processInfo.environment["DEBUG_CLASSIFY"] != nil {
            let box = fitted.boundingBox
            let reason = stitchType == .tatamiFill ? (SatinColumnGenerator.branchingSatinRejection(shape: fitted, parameters: parameters) ?? "eligible (rejected elsewhere)") : "-"
            print(String(format: "  classify Object %d: %@; subPaths=%d bbox %.1fx%.1f; branching satin: %@", i + 1, stitchType.rawValue, fitted.subPaths.count, box.width, box.height, reason))
        }
        objects.append(EmbroideryObject(name: pieceIndex == 0 ? "Object \(i + 1)" : "Object \(i + 1) (\(pieceIndex + 1))", shape: fitted, stitchType: stitchType,
                                         threadColor: threadColor, parameters: parameters))
      }
    }
    objects = StitchTypeClassifier.separateStrokesFromAreas(objects)
    objects = StitchTypeClassifier.harmonizeSameColorFillConsistency(objects)
    objects = StitchTypeClassifier.reconcileRunningStitchOutliers(objects)
    checkpoint("Built \(objects.count) objects")

    if let onlyStr = ProcessInfo.processInfo.environment["ONLY_OBJECT"], let only = Int(onlyStr), only >= 1, only <= objects.count {
        objects = [objects[only - 1]]
        print("Isolated Object \(only): \(objects[0].stitchType.rawValue), subPaths=\(objects[0].shape.subPaths.count)")
    }

    var document = StitchDocument(name: inputURL.deletingPathExtension().lastPathComponent,
                                  physicalWidthMM: widthMM, physicalHeightMM: heightMM, objects: objects)
    // LAYDOWN=1: a white laydown stitch first (`LaydownSettings`).
    if ProcessInfo.processInfo.environment["LAYDOWN"] != nil {
        document.laydown = LaydownSettings(threadColor: .generic(RGBColor(hex: 0xF2EFE8), name: "Ecru"))
    }
    let (plan, colors) = try DigitizePipeline.flattenWithColors(document)
    checkpoint("Flattened plan: \(plan.stitchCount) stitches, \(colors.count) colors")
    let report = QualityAnalyzer.analyze(plan, document: document)
    checkpoint("Quality analysis done")

    print("=== \(inputURL.lastPathComponent) ===")
    print("Objects: \(objects.count)  Stitches: \(plan.stitchCount)  Colors: \(colors.count)  Color changes: \(plan.colorChangeCount)  Trims: \(plan.trimCount)")
    print("Max stitch length: \(String(format: "%.2f", plan.maxStitchLength()))mm  Total thread: \(String(format: "%.0f", plan.totalStitchLength))mm  Est. run time: \(RunTimeEstimator.estimate(plan).formatted) at \(Int(RunTimeEstimator.defaultStitchesPerMinute)) spm")
    print("Readiness: \(report.score)/100 (\(report.isReadyToSew ? "Ready to Sew" : "Review Recommended"))")
    if ProcessInfo.processInfo.environment["PROFILE"] != nil { printProfile(plan) }
    if ProcessInfo.processInfo.environment["DUMP_PLAN"] != nil {
        for (i, c) in plan.commands.prefix(400).enumerated() { print("  \(i): \(c)") }
    }
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
