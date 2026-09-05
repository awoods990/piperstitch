import Foundation

/// The `.stitchpilot` editable master project file (spec §6): "Machine
/// files should be viewed as final manufacturing output. The .stitchpilot
/// file should be the editable master." A `StitchDocument` already holds
/// everything spec §6 asks the master format to retain that this codebase
/// has actually built so far — object hierarchy, physical dimensions,
/// thread assignments, stitch types, and per-object generation parameters
/// (density, underlay, pull compensation) — since `EmbroideryObject`,
/// `VectorShape`, `ThreadColor`, and `StitchGenerationParameters` are all
/// already `Codable`. Fields spec §6 lists that don't exist yet (fabric/
/// machine/hoop profile references, revision history, digitizer
/// adjustments distinct from the generation parameters) will extend this
/// wrapper when those features exist, rather than being stubbed now.
public struct ProjectFile: Codable, Sendable {
    public static let fileExtension = "stitchpilot"
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var document: StitchDocument

    public init(document: StitchDocument) {
        self.formatVersion = Self.currentFormatVersion
        self.document = document
    }
}

public enum ProjectFileError: Error, LocalizedError {
    case unsupportedFormatVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion(let version):
            return "This project file was saved by a newer version of StitchPilot (format version \(version)) and can't be opened here."
        }
    }
}

public enum ProjectFileFormat {
    public static func write(_ document: StitchDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(ProjectFile(document: document))
    }

    public static func read(_ data: Data) throws -> StitchDocument {
        let project = try JSONDecoder().decode(ProjectFile.self, from: data)
        guard project.formatVersion <= ProjectFile.currentFormatVersion else {
            throw ProjectFileError.unsupportedFormatVersion(project.formatVersion)
        }
        return project.document
    }
}
