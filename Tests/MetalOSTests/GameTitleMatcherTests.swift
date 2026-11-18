import XCTest
@testable import MetalOS

final class GameTitleMatcherTests: XCTestCase {
    func testParsedSwitchFilenameRemovesOnlyKnownMetadata() {
        XCTAssertEqual(GameTitleMatcher.searchTitle("  Pokémon™ Legends: Arceus [01001F5010DFA000][v131072][USA][En,Fr].nsp  "), "Pokémon Legends: Arceus")
        XCTAssertEqual(GameTitleMatcher.searchTitle("NXNative - Mortal Kombat 11 (USA) [NXNative Build].app"), "Mortal Kombat 11")
        XCTAssertEqual(GameTitleMatcher.searchTitle("Portal 2 (Mac) v1.2.3"), "Portal 2")
        XCTAssertEqual(GameTitleMatcher.searchTitle("DOOM (2016).app"), "DOOM (2016)")
        XCTAssertEqual(GameTitleMatcher.searchTitle("Game (A Real Subtitle).app"), "Game (A Real Subtitle)")
    }
    func testUnicodePunctuationAndRomanNumeralsMatch() {
        XCTAssertEqual(match("Pokemon Legends Arceus", ["Pokémon™ Legends: Arceus"])?.id, 1)
        XCTAssertEqual(match("Mortal Kombat XI", ["Mortal Kombat 11"])?.id, 1)
        XCTAssertEqual(match("Final Fantasy VII", ["Final Fantasy 7"])?.id, 1)
        XCTAssertEqual(match("Ratchet & Clank", ["Ratchet and Clank"])?.id, 1)
    }
    func testSequelsYearsAndEditionsCannotBeConfused() {
        XCTAssertNil(match("Portal", ["Portal 2"]))
        XCTAssertNil(match("Hades", ["Hades II"]))
        XCTAssertNil(match("DOOM", ["DOOM (1993)", "DOOM (2016)"]))
        XCTAssertNil(match("DOOM (1993)", ["DOOM (2016)"]))
        XCTAssertNil(match("The Last of Us", ["The Last of Us Remastered"]))
        XCTAssertNil(match("The Legend of Zelda Breath of the Wild", ["The Legend of Zelda Tears of the Kingdom"]))
        XCTAssertEqual(match("Portal 2", ["Portal", "Portal 2"])?.id, 2)
    }
    func testUnambiguousMinorTypoAndArticlesCanMatch() {
        XCTAssertEqual(match("Stardew Valey", ["Stardew Valley", "Starbound"])?.id, 1)
        XCTAssertEqual(match("Legend of Zelda Breath of Wild", ["The Legend of Zelda: Breath of the Wild"])?.id, 1)
        XCTAssertNil(match("Stardew Vally", ["Stardew Valley", "Stardew Valey"]))
        XCTAssertNil(match("Doom", ["Doom Eternal"]))
        XCTAssertNil(match("Pokémon Legends Z-A", ["Pokémon Legends Z"]))
    }
    func testDuplicateExactTitlesRequireUserRefinement() {
        XCTAssertNil(match("DOOM", ["DOOM", "Doom"]))
        XCTAssertNil(match("", ["Portal"]))
        let duplicateID = [ArtworkCandidate(id: 42, name: "Portal"), ArtworkCandidate(id: 42, name: "Portal")]
        XCTAssertEqual(GameTitleMatcher.bestMatch(title: "Portal", candidates: duplicateID)?.id, 42)
    }
    private func match(_ title: String, _ names: [String]) -> ArtworkCandidate? {
        GameTitleMatcher.bestMatch(title: title, candidates: names.enumerated().map { ArtworkCandidate(id: $0.offset + 1, name: $0.element) })
    }
}
