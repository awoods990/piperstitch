import Testing
@testable import StitchPilotCore

struct HoopProfileTests {
    @Test func recommendsTheSmallestHoopThatActuallyFits() {
        // A small design should get the small 4x4in hoop, not the largest
        // available -- smaller hoops hold fabric taut more evenly.
        let hoop = HoopProfile.recommended(forDesignWidthMM: 80, heightMM: 80)
        #expect(hoop.name == "4\" × 4\"")
    }

    @Test func recommendsAHoopThatFitsBothDimensionsNotJustOne() {
        // Narrow but tall -- fits a 4x4in's width but not its height, so
        // must skip it for something that actually fits both axes.
        let hoop = HoopProfile.recommended(forDesignWidthMM: 90, heightMM: 150)
        #expect(hoop.widthMM >= 90 && hoop.heightMM >= 150)
        #expect(hoop.name == "5\" × 7\"")
    }

    @Test func fallsBackToTheLargestHoopWhenNothingFits() {
        let hoop = HoopProfile.recommended(forDesignWidthMM: 500, heightMM: 500)
        let largest = HoopProfile.commonHoops.max { $0.widthMM * $0.heightMM < $1.widthMM * $1.heightMM }!
        #expect(hoop.name == largest.name)
    }
}
