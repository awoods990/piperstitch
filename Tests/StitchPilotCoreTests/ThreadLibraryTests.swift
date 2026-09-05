import Testing
@testable import StitchPilotCore

struct ThreadLibraryTests {
    @Test func exactPaletteColorMatchesItself() {
        let black = RGBColor(hex: 0x000000)
        let match = ThreadLibrary.nearestMatch(to: black)
        #expect(match?.rgb == black)
    }

    @Test func nearbyColorMatchesClosestPaletteEntry() {
        // Slightly off pure red should still match the palette's red, not black or blue.
        let almostRed = RGBColor(hex: 0xCE1F28)
        let match = ThreadLibrary.nearestMatch(to: almostRed)
        #expect(match?.name.contains("Red") == true)
    }

    @Test func nearestMatchesReturnsRequestedCountInAscendingDistance() {
        let color = RGBColor(hex: 0x1A5CB0) // exactly "Generic Blue"
        let matches = ThreadLibrary.nearestMatches(to: color, count: 3)
        #expect(matches.count == 3)
        #expect(matches[0].rgb == color)

        var distances: [Double] = []
        for m in matches { distances.append(RGBColor.deltaE(color, m.rgb)) }
        for i in 1..<distances.count {
            #expect(distances[i] >= distances[i - 1])
        }
    }

    @Test func emptyPaletteReturnsNil() {
        #expect(ThreadLibrary.nearestMatch(to: RGBColor(hex: 0xFF0000), in: []) == nil)
    }

    @Test func customPaletteIsRespected() {
        // A restricted "my thread inventory" palette should only ever match within itself.
        let inventory = [ThreadLibrary.genericPalette[0], ThreadLibrary.genericPalette[1]] // black, white
        let match = ThreadLibrary.nearestMatch(to: RGBColor(hex: 0xFF0000), in: inventory)
        #expect(match?.rgb == RGBColor(hex: 0x000000) || match?.rgb == RGBColor(hex: 0xFFFFFF))
    }

    @Test func genericPaletteHasNoDuplicateNames() {
        let names = ThreadLibrary.genericPalette.map { $0.name }
        #expect(Set(names).count == names.count)
    }
}
