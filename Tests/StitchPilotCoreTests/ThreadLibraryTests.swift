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

    // MARK: - bestMatch

    /// The actual scenario `bestMatch` exists for: a sparse or narrowly-
    /// curated custom/manufacturer thread library with nothing close to a
    /// color genuinely in the artwork. `nearestMatch` correctly stays
    /// strict (a deliberately-restricted "My Thread Inventory" should
    /// never silently suggest a thread the user doesn't own -- see
    /// `customPaletteIsRespected`), but `bestMatch` is the opt-in sibling
    /// for automatic import color-matching, which has no such
    /// "deliberately restricted" intent to respect and should surface the
    /// genuinely closest available color instead of a poor in-palette one.
    @Test func bestMatchFallsBackToGenericPaletteWhenTheCustomPaletteHasNothingClose() {
        let inventory = [ThreadLibrary.genericPalette[0], ThreadLibrary.genericPalette[1]] // black, white
        let match = ThreadLibrary.bestMatch(to: RGBColor(hex: 0xFF0000), in: inventory)
        #expect(match?.color.name.contains("Red") == true)
        #expect(match?.isFallback == true)
        // Pure sRGB red (0xFF0000) is a far more saturated primary than any
        // realistic thread color, "Generic Red" included -- a real Delta-E
        // gap between them is expected and not itself a quality bug; the
        // behavior under test is that the search widened to the generic
        // palette and found red, not that this particular pairing scores
        // as an "excellent" match.
        #expect(match?.deltaE ?? .infinity < RGBColor.deltaE(RGBColor(hex: 0xFF0000), RGBColor(hex: 0x000000)),
                "the generic palette's red must still be closer than the inventory's black")
    }

    /// A custom palette that already has a good match must be respected,
    /// exactly like `nearestMatch` -- `bestMatch` only widens the search
    /// when the palette's own answer is genuinely poor, never just because
    /// a marginally closer color exists elsewhere.
    @Test func bestMatchKeepsAGoodInPaletteMatchWithoutFallingBack() {
        let inventory = [ThreadLibrary.genericPalette.first { $0.name == "Generic Red" }!]
        let match = ThreadLibrary.bestMatch(to: RGBColor(hex: 0xCE1F28), in: inventory)
        #expect(match?.color.name == "Generic Red")
        #expect(match?.isFallback == false)
    }

    @Test func bestMatchOnAnEmptyPaletteFallsBackToGeneric() {
        let match = ThreadLibrary.bestMatch(to: RGBColor(hex: 0xFF0000), in: [])
        #expect(match?.color.name.contains("Red") == true)
        #expect(match?.isFallback == true)
    }

    @Test func matchQualityOrdersFromExcellentToPoor() {
        #expect(ThreadLibrary.MatchQuality.excellent < .good)
        #expect(ThreadLibrary.MatchQuality.good < .acceptable)
        #expect(ThreadLibrary.MatchQuality.acceptable < .poor)
    }
}
