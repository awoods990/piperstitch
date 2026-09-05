import Testing
import Foundation
@testable import StitchPilotCore

struct SVGImportTests {
    @Test func importsSimpleRect() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="50">
          <rect x="10" y="10" width="80" height="30" fill="#ff0000"/>
        </svg>
        """
        let result = try SVGImporter.importShapes(from: svg.data(using: .utf8)!)
        #expect(result.shapes.count == 1)
        let box = result.shapes[0].boundingBox
        #expect(abs(box.minX - 10) <= 0.01)
        #expect(abs(box.minY - 10) <= 0.01)
        #expect(abs(box.width - 80) <= 0.01)
        #expect(abs(box.height - 30) <= 0.01)
        #expect(result.fillColors[0] == RGBColor(hex: 0xFF0000))
    }

    @Test func importsCircleApproximation() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
          <circle cx="50" cy="50" r="40"/>
        </svg>
        """
        let result = try SVGImporter.importShapes(from: svg.data(using: .utf8)!)
        #expect(result.shapes.count == 1)
        let box = result.shapes[0].boundingBox
        #expect(abs(box.width - 80) <= 1.0)
        #expect(abs(box.height - 80) <= 1.0)
        // Default fill (no fill attribute) is black per the SVG spec.
        #expect(result.fillColors[0] == RGBColor(hex: 0x000000))
    }

    @Test func pathWithCubicCurve() throws {
        // A simple rounded rectangle corner: line then a cubic curve back down.
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
          <path d="M10,10 L90,10 C95,10 95,15 95,20 L95,90 Z" fill="blue"/>
        </svg>
        """
        let result = try SVGImporter.importShapes(from: svg.data(using: .utf8)!)
        #expect(result.shapes.count == 1)
        let subPath = result.shapes[0].subPaths[0]
        #expect(subPath.closed)
        #expect(subPath.points.count > 4, "the cubic segment should have been flattened into multiple points")
        let box = result.shapes[0].boundingBox
        #expect(abs(box.maxX - 95) <= 0.5)
    }

    @Test func groupTransformIsApplied() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="200" height="200">
          <g transform="translate(50,50)">
            <rect x="0" y="0" width="10" height="10"/>
          </g>
        </svg>
        """
        let result = try SVGImporter.importShapes(from: svg.data(using: .utf8)!)
        let box = result.shapes[0].boundingBox
        #expect(abs(box.minX - 50) <= 0.01)
        #expect(abs(box.minY - 50) <= 0.01)
    }

    @Test func fitToPhysicalSizePreservesAspectRatioAndCenters() {
        let shape = VectorShape(subPaths: [SubPath(points: [Point2D(0, 0), Point2D(100, 0), Point2D(100, 50), Point2D(0, 50)], closed: true)])
        let fitted = shape.fitToPhysicalSize(widthMM: 40, heightMM: 40, within: shape.boundingBox)
        let box = fitted.boundingBox
        // 100x50 into a 40x40 box, preserving aspect ratio -> scale = 40/100 = 0.4 -> 40x20, centered vertically.
        #expect(abs(box.width - 40) <= 0.01)
        #expect(abs(box.height - 20) <= 0.01)
        #expect(abs(box.minY - 10) <= 0.01)
    }
}
