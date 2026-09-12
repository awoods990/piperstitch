import Foundation
import StitchPilotCore

/// Runs the engine's CPU-bound, synchronous work off Vapor's event loops,
/// at most one job per core at a time. A full digitize is ~0.4 s on Apple
/// Silicon (measured in DigitizeCLI); queueing beyond the core count means
/// a burst of users each wait a second or two rather than the server
/// thrashing or a request timing out.
enum Engine {
    private static let queue = DispatchQueue(label: "com.piperstitch.engine", qos: .userInitiated, attributes: .concurrent)
    private static let limiter = JobLimiter(maxConcurrent: max(1, ProcessInfo.processInfo.activeProcessorCount))

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        await limiter.acquire()
        defer { Task { await limiter.release() } }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}

actor JobLimiter {
    private let maxConcurrent: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) { self.maxConcurrent = maxConcurrent }

    func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        running += 1
    }

    func release() {
        running -= 1
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }
}

// MARK: - The document lifecycle, mirrored from the Mac app's AppState

/// Everything an import produces that the browser must hold onto to
/// rebuild the document later (a size change re-fits these *source*
/// shapes -- never scales stitches, spec §39). The Mac app keeps this as
/// `AppState.lastRawShapes` and friends; here it round-trips through the
/// client because the server keeps nothing between requests.
struct ImportedSource: Codable, Sendable {
    var shapes: [VectorShape]
    var fillColors: [RGBColor?]
    /// Pixel-space bounds of every shape together.
    var bounds: BoundingBox
    var pixelWidth: Int
    var pixelHeight: Int
}

enum DocumentBuilder {
    static let defaultPhysicalWidthMM: Double = 100

    /// `AppState.importFile`'s sizing step: a starting size from the
    /// artwork's own detail, capped to the selected hoop, height following
    /// the source aspect ratio.
    static func recommendedSize(for source: ImportedSource, hoopWidthMM: Double?, hoopHeightMM: Double?) -> (widthMM: Double, heightMM: Double) {
        let aspect = source.bounds.height > 0 ? source.bounds.width / source.bounds.height : 1
        let width = SizeRecommender.recommendedWidthMM(for: source.shapes, currentWidthMM: defaultPhysicalWidthMM,
                                                       maxWidthMM: hoopWidthMM, maxHeightMM: hoopHeightMM)
        return (width, aspect > 0 ? width / aspect : width)
    }

    /// `AppState.regenerateFromStoredGeometry`, verbatim in behavior: fit
    /// each source shape to the physical size, match its color to the
    /// palette, classify, then reconcile same-word outliers.
    static func build(source: ImportedSource, name: String, widthMM: Double, heightMM: Double,
                      matchToThreadLibrary: Bool, palette: [ThreadColor]?, fabricType: FabricType) -> StitchDocument {
        let effectivePalette = (palette?.isEmpty == false) ? palette! : ThreadLibrary.genericPalette
        var objects: [EmbroideryObject] = []
        for (i, shape) in source.shapes.enumerated() {
            let fitted = shape.fitToPhysicalSize(widthMM: widthMM, heightMM: heightMM, within: source.bounds)
            let detectedRGB = (i < source.fillColors.count ? source.fillColors[i] : nil) ?? RGBColor(hex: 0x000000)
            let threadColor: ThreadColor
            if matchToThreadLibrary, let matched = ThreadLibrary.nearestMatch(to: detectedRGB, in: effectivePalette) {
                threadColor = matched
            } else {
                threadColor = .generic(detectedRGB, name: "Imported Color \(i + 1)")
            }
            var parameters = StitchGenerationParameters()
            parameters.fabricType = fabricType
            let stitchType = StitchTypeClassifier.classify(shape: fitted, parameters: parameters)
            objects.append(EmbroideryObject(name: "Object \(i + 1)", shape: fitted, stitchType: stitchType,
                                             threadColor: threadColor, parameters: parameters))
        }
        objects = StitchTypeClassifier.reconcileRunningStitchOutliers(objects)
        return StitchDocument(name: name, physicalWidthMM: widthMM, physicalHeightMM: heightMM, objects: objects)
    }

    /// `AppState.applyPhysicalSizeChange`: resize an existing document from
    /// its own current bounds, re-classifying anything the user hasn't
    /// pinned to a stitch type by hand.
    static func resize(_ current: StitchDocument, widthMM: Double, heightMM: Double) -> StitchDocument {
        let currentBounds = current.boundingBox
        guard !currentBounds.isEmpty else { return current }
        let resized = current.objects.map { object -> EmbroideryObject in
            var resized = object
            resized.shape = object.shape.fitToPhysicalSize(widthMM: widthMM, heightMM: heightMM, within: currentBounds)
            if !resized.stitchTypeIsManualOverride {
                resized.stitchType = StitchTypeClassifier.classify(shape: resized.shape, parameters: resized.parameters)
            }
            return resized
        }
        return StitchDocument(name: current.name, physicalWidthMM: widthMM, physicalHeightMM: heightMM, objects: resized)
    }

    /// `AppState.selectedFabricType`'s didSet: the fabric is a whole-
    /// document setting written onto every object's own parameters.
    static func applyFabric(_ fabric: FabricType, to document: StitchDocument) -> StitchDocument {
        var updated = document
        for i in updated.objects.indices { updated.objects[i].parameters.fabricType = fabric }
        return updated
    }
}
