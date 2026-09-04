import XCTest
@testable import LetsLapseKit

/// The text overlay model: runs and their editing, reveal units and phases,
/// the moment a layer is in, sidecar decoding, sequencing — and the caret
/// arithmetic the editor's copy field leans on.
///
/// Why these exist: on 2026-09-04 the first Mac test run trapped with
/// "String index is out of bounds" the moment the placeholder was selected
/// and typed over. The trap itself was SwiftUI re-applying a stale selection,
/// but every offset path on our side of that field is the same shape of
/// bug waiting to happen, and none of it had a test. The run editor's own
/// first version trapped on an empty overlap range; a harness caught it.
final class TextOverlayModelTests: XCTestCase {

    private func runs(_ content: TextOverlayContent) -> [String] {
        content.runs.map { "\($0.text)|\($0.styleKey)" }
    }

    // MARK: - Runs

    func testStringJoinsRuns() {
        let c = TextOverlayContent(runs: [
            TextRun(text: "Don't "), TextRun(text: "you", isBold: true), TextRun(text: " think")])
        XCTAssertEqual(c.string, "Don't you think")
        XCTAssertEqual(c.characterCount, 15)
    }

    func testInsertKeepsRunsAndInheritsTheRunItLandsIn() {
        var c = TextOverlayContent(runs: [
            TextRun(text: "Don't "), TextRun(text: "you", isBold: true), TextRun(text: " think")])
        c.string = "Don't you really think"
        XCTAssertEqual(c.string, "Don't you really think")
        XCTAssertEqual(c.runs.count, 3, "\(runs(c))")
        XCTAssertEqual(c.runs[1].text, "you")
        XCTAssertEqual(c.runs[1].isBold, true)
        // Typing inside the bold run inherits bold.
        c.string = "Don't u really think"
        XCTAssertTrue(c.runs.contains { $0.text == "u" && $0.isBold == true }, "\(runs(c))")
    }

    func testDeletingAWholeRunMergesItsNeighbours() {
        var c = TextOverlayContent(runs: [
            TextRun(text: "Don't "), TextRun(text: "you", isBold: true), TextRun(text: " think")])
        c.string = "Don't  think"
        XCTAssertFalse(c.runs.contains { $0.isBold == true }, "\(runs(c))")
        XCTAssertEqual(c.runs.count, 1)
    }

    /// The exact editing gesture that trapped the field: select the whole
    /// placeholder and type over it. The model must swallow every shape of
    /// it — shorter, longer, empty — without touching a stale offset.
    func testSelectAllAndTypeOverThePlaceholder() {
        var c = TextOverlayContent(string: "Your text")
        c.string = "H"
        XCTAssertEqual(c.string, "H")
        c.string = "Hello world"
        XCTAssertEqual(c.string, "Hello world")
        c.string = ""
        XCTAssertEqual(c.string, "")
        XCTAssertEqual(c.runs.count, 1, "an empty layer keeps one run for its style")
        c.string = "Prague"
        XCTAssertEqual(c.string, "Prague")

        // Same over styled runs: the replacement lands in the first run.
        var styled = TextOverlayContent(runs: [
            TextRun(text: "Don't "), TextRun(text: "you", isBold: true), TextRun(text: " think")])
        styled.string = "x"
        XCTAssertEqual(styled.string, "x")
        XCTAssertEqual(styled.runs.count, 1, "\(runs(styled))")
    }

    func testReplaceRangeEdgesNeverTrap() {
        var c = TextOverlayContent(runs: [TextRun(text: "ab"), TextRun(text: "cd", isBold: true)])
        c.replace(0..<0, with: "")          // no-op
        c.replace(4..<4, with: "e")         // append past the last run
        XCTAssertEqual(c.string, "abcde")
        c.replace(0..<5, with: "")          // everything
        XCTAssertEqual(c.string, "")
        c.replace(0..<0, with: "z")
        XCTAssertEqual(c.string, "z")
        // A range that overlaps no run at all (past the end) is ignored.
        c.replace(10..<12, with: "")
        XCTAssertEqual(c.string, "z")
    }

    func testApplyStyleSplitsAndClearingMergesBack() {
        var d = TextOverlayContent(string: "is worth a LITTLE visit?")
        let word = d.wordRange(at: 13)
        XCTAssertNotNil(word)
        XCTAssertEqual(String(Array(d.string)[word!]), "LITTLE")
        d.applyStyle(in: word!) { $0.colorHex = "#3A3A3C" }
        XCTAssertEqual(d.runs.count, 3, "\(runs(d))")
        XCTAssertEqual(d.runs[1].text, "LITTLE")
        XCTAssertEqual(d.runs[1].colorHex, "#3A3A3C")
        d.applyStyle(in: word!) { $0.colorHex = nil }
        XCTAssertEqual(d.runs.count, 1)
    }

    func testToolbarEditsStoreOnlyWhatDiffersFromTheLayer() {
        var c = TextOverlayContent(string: "Don't you think")
        c.isBold = true
        let you = c.wordRange(at: 7)!
        c.toggleBold(in: you)
        XCTAssertEqual(c.run(at: 7)?.isBold, false, "an explicit off against a bold layer")
        c.toggleBold(in: you)
        XCTAssertNil(c.run(at: 7)?.isBold, "back to inheriting")
        XCTAssertEqual(c.runs.count, 1, "merged back: \(runs(c))")
        c.setColor("#FFB340", in: you)
        XCTAssertEqual(c.run(at: 7)?.colorHex, "#FFB340")
        c.setColor("#F3E37C", in: nil)
        XCTAssertEqual(c.colorHex, "#F3E37C")
        XCTAssertTrue(c.runs.allSatisfy { $0.colorHex == nil }, "a layer swatch clears every run's own colour")
        c.toggleUnderline(in: nil)
        XCTAssertTrue(c.isUnderlined)
    }

    func testWordRangeAtCaret() {
        let c = TextOverlayContent(string: "is worth a LITTLE visit?")
        XCTAssertEqual(c.wordRange(at: 0), 0..<2)
        XCTAssertEqual(c.wordRange(at: 2), 0..<2, "a caret at the end of a word is in the word")
        XCTAssertEqual(c.wordRange(at: 24), 18..<24, "a caret at the very end takes the last word")
        XCTAssertNil(TextOverlayContent(string: "").wordRange(at: 0))
        XCTAssertNil(TextOverlayContent(string: "   ").wordRange(at: 1))
        XCTAssertEqual(c.wordRange(at: 99), 18..<24, "past the end clamps")
        XCTAssertEqual(c.wordRange(at: -5), 0..<2, "before the start clamps")
    }

    // MARK: - The field's caret arithmetic

    /// Indices made in a longer text, applied to the shorter text that
    /// replaced it — the select-all-and-type case. They must clamp, never
    /// trap.
    func testCharacterRangeClampsIndicesFromAnOlderLongerText() {
        let old = "Your text"
        let staleAll = old.startIndex..<old.endIndex
        let staleMid = old.index(old.startIndex, offsetBy: 5)..<old.index(old.startIndex, offsetBy: 9)
        XCTAssertEqual(TextOverlayContent.characterRange(of: staleAll, in: "H"), 0..<1)
        XCTAssertEqual(TextOverlayContent.characterRange(of: staleMid, in: "H"), 1..<1)
        XCTAssertEqual(TextOverlayContent.characterRange(of: staleAll, in: ""), 0..<0)
        // A caret clamped to the end of "H" sits at the end of that word.
        XCTAssertEqual(TextOverlayContent.styleTarget(for: staleMid, in: "H"), 0..<1)
        XCTAssertNil(TextOverlayContent.styleTarget(for: staleAll, in: ""))
    }

    /// The caret the field re-seats itself at after each edit — it must be
    /// an offset INTO the new text for every shape of edit.
    func testCaretAfterEditLandsAtTheEndOfTheChange() {
        XCTAssertEqual(TextOverlayContent.caretAfterEdit(from: "Your text", to: "H"), 1, "select all, type")
        XCTAssertEqual(TextOverlayContent.caretAfterEdit(from: "Your text", to: ""), 0, "select all, delete")
        XCTAssertEqual(TextOverlayContent.caretAfterEdit(from: "", to: "Prague"), 6, "type into empty")
        XCTAssertEqual(TextOverlayContent.caretAfterEdit(from: "Your text", to: "Your textHi"), 11, "append")
        XCTAssertEqual(TextOverlayContent.caretAfterEdit(from: "Don't you think", to: "Don't we think"), 8, "replace a word")
        // "you" → "u" reads as "yo deleted" (the longest untouched suffix
        // wins); either reading is a valid caret, and both are inside.
        XCTAssertEqual(TextOverlayContent.caretAfterEdit(from: "Don't you think", to: "Don't u think"), 6, "ambiguous edit: suffix-maximal")
        XCTAssertEqual(TextOverlayContent.caretAfterEdit(from: "abc", to: "ac"), 1, "delete in the middle")
        XCTAssertEqual(TextOverlayContent.caretAfterEdit(from: "abc", to: "abc"), 3, "no change")
        for (old, new) in [("Your text", "H"), ("a👍🏽b", "a"), ("é", "e\u{301}x")] {
            let caret = TextOverlayContent.caretAfterEdit(from: old, to: new)
            XCTAssertTrue((0...new.count).contains(caret), "\(old) → \(new): \(caret)")
            _ = new.index(new.startIndex, offsetBy: caret)  // must not trap
        }
    }

    func testStyleTargetPrefersSelectionThenWordThenNothing() {
        let text = "Don't you think"
        let sel = text.index(text.startIndex, offsetBy: 6)..<text.index(text.startIndex, offsetBy: 9)
        XCTAssertEqual(TextOverlayContent.styleTarget(for: sel, in: text), 6..<9)
        let caretInWord = text.index(text.startIndex, offsetBy: 7)..<text.index(text.startIndex, offsetBy: 7)
        XCTAssertEqual(TextOverlayContent.styleTarget(for: caretInWord, in: text), 6..<9)
        let caretOnSpace = text.index(text.startIndex, offsetBy: 5)..<text.index(text.startIndex, offsetBy: 5)
        XCTAssertEqual(TextOverlayContent.styleTarget(for: caretOnSpace, in: text), 0..<5,
                       "a caret on the space after a word styles that word")
        let twoSpaces = "a  b"
        let between = twoSpaces.index(twoSpaces.startIndex, offsetBy: 2)..<twoSpaces.index(twoSpaces.startIndex, offsetBy: 2)
        XCTAssertNil(TextOverlayContent.styleTarget(for: between, in: twoSpaces),
                     "a caret with whitespace on both sides is no target")
    }

    func testEmojiAndCombiningMarksCountAsOneCharacter() {
        var c = TextOverlayContent(string: "a👍🏽b")
        XCTAssertEqual(c.characterCount, 3)
        XCTAssertEqual(c.wordRange(at: 1), 0..<3)
        c.applyStyle(in: 1..<2) { $0.isBold = true }
        XCTAssertEqual(c.runs.map(\.text), ["a", "👍🏽", "b"])
        c.string = "a👍🏽"
        XCTAssertEqual(c.runs.map(\.text), ["a", "👍🏽"])
        let text = "é" + "\u{301}"   // e + two combining acutes: one grapheme
        let all = text.startIndex..<text.endIndex
        XCTAssertEqual(TextOverlayContent.characterRange(of: all, in: text), 0..<1)
    }

    // MARK: - Units and phases

    func testUnitsSpacesTravelWithThePrecedingWord() {
        let u = TextOverlayContent(string: "Don't  you\nthink")
        let words = u.unitIndices(for: .word)
        XCTAssertEqual(words.count, 3)
        XCTAssertEqual(words.ofCluster, [0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 2])
        XCTAssertEqual(u.unitIndices(for: .character).count, 16)
        let element = u.unitIndices(for: .element)
        XCTAssertEqual(element.count, 1)
        XCTAssertTrue(element.ofCluster.allSatisfy { $0 == 0 })
        XCTAssertEqual(TextOverlayContent(string: "").unitIndices(for: .word).count, 0)
        XCTAssertEqual(TextOverlayContent(string: "  lead").unitIndices(for: .word).count, 1,
                       "leading whitespace joins the first word")
    }

    func testPhasesStaggerAndSettle() {
        let reveal = OverlayReveal(unit: .word, style: .fade, start: 0.2, end: 0.4, overlap: 0.6)
        XCTAssertTrue(reveal.phases(at: 0.1, unitCount: 3).allSatisfy { $0 == 0 })
        XCTAssertTrue(reveal.phases(at: 0.4, unitCount: 3).allSatisfy { $0 == 1 })
        let mid = reveal.phases(at: 0.3, unitCount: 3)
        XCTAssertTrue(mid[0] >= mid[1] && mid[1] >= mid[2], "\(mid)")
        var element = reveal
        element.unit = .element
        XCTAssertEqual(element.phases(at: 0.3, unitCount: 1)[0], 0.5, accuracy: 1e-9)
        XCTAssertEqual(reveal.phases(at: 0.3, unitCount: 0), [])
        var zero = reveal
        zero.end = zero.start
        XCTAssertTrue(zero.phases(at: 0.5, unitCount: 2).allSatisfy { $0 == 1 }, "an empty band is over at once")
    }

    // MARK: - Moments

    func testMomentsAcrossRevealHoldAndExit() {
        let content = TextOverlayContent(string: "Prague")
        let anim = OverlayAnimation(
            reveal: OverlayReveal(unit: .element, style: .fade, start: 0.2, end: 0.28),
            exit: OverlayReveal(unit: .element, style: .fade, start: 0.8, end: 0.86))
        XCTAssertEqual(anim.moment(at: 0.1, content: content), .hidden)
        if case .revealing = anim.moment(at: 0.24, content: content) {} else { XCTFail("revealing") }
        XCTAssertEqual(anim.moment(at: 0.5, content: content), .settled)
        if case .exiting = anim.moment(at: 0.83, content: content) {} else { XCTFail("exiting") }
        XCTAssertEqual(anim.moment(at: 0.86, content: content), .hidden)
        XCTAssertEqual(anim.moment(at: 0.9, content: content), .hidden)

        var cut = anim
        cut.reveal.style = nil
        cut.exit?.style = nil
        XCTAssertEqual(cut.moment(at: 0.21, content: content), .settled, "cut in: there from its start")
        XCTAssertEqual(cut.moment(at: 0.85, content: content), .settled, "cut out: there until its end")
        XCTAssertEqual(cut.moment(at: 0.861, content: content), .hidden)

        XCTAssertEqual(OverlayAnimation.alwaysOn.moment(at: 0, content: content), .settled)
        XCTAssertEqual(OverlayAnimation.alwaysOn.moment(at: 1, content: content), .settled)
        XCTAssertEqual(anim.visibleSpan, 0.2...0.86)
        XCTAssertTrue(anim.isOnScreen(at: 0.5))
        XCTAssertFalse(anim.isOnScreen(at: 0.9))
    }

    // MARK: - Decoding

    func testLegacyBandDecodesAsACharacterReveal() throws {
        let legacy = #"{"st":"characterSlide","d":"left","a":0.1,"b":0.3,"o":0.5}"#
        let decoded = try JSONDecoder().decode(OverlayAnimation.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.reveal.unit, .character)
        XCTAssertEqual(decoded.reveal.style, .slide)
        XCTAssertEqual(decoded.reveal.direction, .left)
        XCTAssertEqual(decoded.reveal.start, 0.1)
        XCTAssertEqual(decoded.reveal.end, 0.3)
        XCTAssertEqual(decoded.reveal.overlap, 0.5)
        XCTAssertNil(decoded.exit)
        XCTAssertNil(decoded.follows)
    }

    func testPlainStringDecodesAsOneRunAndRunsRoundTrip() throws {
        let plain = try JSONDecoder().decode(TextOverlayContent.self, from: Data(#"{"s":"Hello"}"#.utf8))
        XCTAssertEqual(plain.runs.count, 1)
        XCTAssertEqual(plain.string, "Hello")
        XCTAssertTrue(plain.isBold, "the spike's look: bold white system")

        let styled = TextOverlayContent(runs: [TextRun(text: "Don't "), TextRun(text: "you", isBold: true), TextRun(text: " think")])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(styled)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains(#""s":"Don't you think""#), "the joined string still travels under the old key: \(json)")
        XCTAssertTrue(json.contains(#""r":["#))
        XCTAssertEqual(try JSONDecoder().decode(TextOverlayContent.self, from: data), styled)

        let single = try encoder.encode(TextOverlayContent(string: "Prague"))
        XCTAssertFalse(String(decoding: single, as: UTF8.self).contains(#""r":["#), "a plain run writes no runs key")
    }

    func testAnimationRoundTripsWithExitAndFollow() throws {
        let parent = UUID()
        let anim = OverlayAnimation(
            reveal: OverlayReveal(unit: .character, style: .bounce, start: 0.08, end: 0.2),
            exit: OverlayReveal(unit: .element, style: .fade, start: 0.8, end: 0.86),
            follows: OverlayFollow(layerID: parent, gap: 0.02))
        let data = try JSONEncoder().encode(anim)
        XCTAssertEqual(try JSONDecoder().decode(OverlayAnimation.self, from: data), anim)
    }

    // MARK: - Sequencing

    private func layer(_ start: Double, _ end: Double, exit: OverlayReveal? = nil,
                       follows: UUID? = nil, gap: Double = 0) -> OverlaySequencing.Layer {
        OverlaySequencing.Layer(
            id: UUID(),
            animation: OverlayAnimation(
                reveal: OverlayReveal(unit: .element, style: .fade, start: start, end: end),
                exit: exit,
                follows: follows.map { OverlayFollow(layerID: $0, gap: gap) }))
    }

    func testChildSeatsAfterParentKeepingDuration() {
        let l1 = layer(0.08, 0.2)
        let l2 = layer(0.5, 0.58, follows: l1.id, gap: 0.02)
        var layers = [l1, l2]
        OverlaySequencing.resolve(&layers)
        XCTAssertEqual(layers[1].animation!.reveal.start, 0.22, accuracy: 1e-9)
        XCTAssertEqual(layers[1].animation!.reveal.duration, 0.08, accuracy: 1e-9)
    }

    func testChainResolvesInAnyListOrderAndExitRidesAlong() {
        let l1 = layer(0.08, 0.2)
        let l2 = layer(0.5, 0.58, follows: l1.id)
        let l3 = layer(0.9, 0.95, exit: OverlayReveal(unit: .element, style: .fade, start: 0.97, end: 1.0), follows: l2.id)
        var layers = [l3, l1, l2]
        OverlaySequencing.resolve(&layers)
        XCTAssertEqual(layers[0].animation!.reveal.start, 0.28, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(layers[0].animation!.exit!.start, layers[0].animation!.reveal.end)
        XCTAssertEqual(OverlaySequencing.descendants(of: l1.id, in: layers), Set([l2.id, l3.id]))
        XCTAssertTrue(OverlaySequencing.descendants(of: l3.id, in: layers).isEmpty)
    }

    func testCyclesDanglingAndRemovalDropLinksButKeepTimes() {
        let l1 = layer(0.08, 0.2)
        let l2 = layer(0.5, 0.58, follows: l1.id)
        var cyc = [l1, l2]
        cyc[0].animation!.follows = OverlayFollow(layerID: l2.id)
        OverlaySequencing.resolve(&cyc)
        XCTAssertEqual(cyc.filter { $0.animation?.follows != nil }.count, 1, "one link of the cycle survives")

        var dangling = [l1, l2]
        dangling[1].animation!.follows = OverlayFollow(layerID: UUID())
        OverlaySequencing.resolve(&dangling)
        XCTAssertNil(dangling[1].animation!.follows)
        XCTAssertEqual(dangling[1].animation!.reveal.start, 0.5, "absolute time kept")

        var removed = [l1, l2]
        OverlaySequencing.resolve(&removed)
        OverlaySequencing.removing(l1.id, from: &removed)
        XCTAssertEqual(removed.count, 1)
        XCTAssertNil(removed[0].animation!.follows)
        XCTAssertEqual(removed[0].animation!.reveal.start, 0.2, accuracy: 1e-9, "left where the parent had seated it")

        var selfLink = [l1]
        selfLink[0].animation!.follows = OverlayFollow(layerID: l1.id)
        OverlaySequencing.resolve(&selfLink)
        XCTAssertNil(selfLink[0].animation!.follows)
    }

    func testShiftClampsInsideTheShoot() {
        var anim = OverlayAnimation(
            reveal: OverlayReveal(unit: .element, style: .fade, start: 0.9, end: 0.95),
            exit: OverlayReveal(unit: .element, style: .fade, start: 0.97, end: 1.0))
        anim.shift(by: 0.5)
        XCTAssertLessThanOrEqual(anim.reveal.end, 1)
        XCTAssertLessThanOrEqual(anim.exit!.end, 1)
        XCTAssertGreaterThanOrEqual(anim.exit!.start, anim.reveal.end)
        anim.shift(by: -2)
        XCTAssertEqual(anim.reveal.start, 0)
        XCTAssertEqual(anim.reveal.duration, 0.05, accuracy: 1e-9)
    }
}
