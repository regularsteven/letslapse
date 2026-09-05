import XCTest
@testable import LetsLapseKit

/// Crafted text and the position side of an association — the two pieces of
/// the "Add Crafted Text · association menu" design that are arithmetic
/// rather than pixels.
///
/// The layout is worth testing because it is the part a model cannot be
/// trusted with: whatever Gemma returns, the lines have to fit the frame,
/// keep the hierarchy their priorities asked for, and stack without
/// overlapping. The splitter is worth testing because it is what runs when
/// there is no model at all.
final class CraftedTextTests: XCTestCase {

    /// A stand-in for Core Text: every character is half an em wide, bold
    /// costs a tenth more. Enough for the fit maths to have something
    /// monotonic to chew on.
    private func measure(_ copy: String, _ style: CraftedTextStyle) -> Double {
        Double(copy.count) * 0.5 * (style.isBold ? 1.1 : 1.0)
    }

    private func lines(_ parts: [CraftedTextPart], aspect: Double = 4.0 / 3.0)
        -> [CraftedTextLayout.Line] {
        CraftedTextLayout.lines(for: parts, aspect: aspect, measure: measure)
    }

    // MARK: - Layout

    func testPayoffLineIsLargestAndAmber() {
        let out = lines([
            CraftedTextPart(copy: "A little sand", priority: 2),
            CraftedTextPart(copy: "wash away the woes", priority: 1),
        ])
        XCTAssertEqual(out.count, 2)
        XCTAssertGreaterThan(out[1].size, out[0].size, "priority 1 is the biggest line")
        XCTAssertEqual(out[1].style.colorHex, "#FFB340")
        XCTAssertEqual(out[1].style.style, .pop, "the payoff line pops in")
        XCTAssertEqual(out[0].style.colorHex, "#FFFFFF")
    }

    func testLongLineIsShrunkToFitTheFrame() {
        let long = String(repeating: "wide ", count: 30)
        let out = lines([CraftedTextPart(copy: long, priority: 1)])
        let ems = measure(long, out[0].style)
        // size is a long-edge fraction; on a landscape frame that is the width.
        XCTAssertLessThanOrEqual(out[0].size * ems, CraftedTextLayout.widthLimit + 1e-9)
        XCTAssertLessThan(out[0].size, CraftedTextStyle.forPriority(1).size,
                          "the priority's own size was too big for this copy")
    }

    func testPortraitFrameFitsAgainstTheShortEdge() {
        // Long edge is the HEIGHT in portrait, so the same size is a wider
        // line and has to shrink further than it would landscape.
        let copy = "a reasonably long line of copy"
        let portrait = lines([CraftedTextPart(copy: copy, priority: 1)], aspect: 3.0 / 4.0)
        let landscape = lines([CraftedTextPart(copy: copy, priority: 1)], aspect: 4.0 / 3.0)
        XCTAssertLessThan(portrait[0].size, landscape[0].size)
        let ems = measure(copy, portrait[0].style)
        XCTAssertLessThanOrEqual(portrait[0].size * (4.0 / 3.0) * ems,
                                 CraftedTextLayout.widthLimit + 1e-9)
    }

    func testHierarchySurvivesTheFit() {
        // The important line is long enough to be shrunk below the quiet
        // one's size; the quiet one must give way rather than out-shout it.
        let out = lines([
            CraftedTextPart(copy: String(repeating: "important ", count: 12), priority: 1),
            CraftedTextPart(copy: "tiny", priority: 5),
        ])
        XCTAssertGreaterThan(out[0].size, out[1].size,
                             "priority 1 still reads larger than priority 5")
    }

    func testLinesStackWithoutOverlappingAndCentreOnTheBlock() {
        let out = lines([
            CraftedTextPart(copy: "one", priority: 3),
            CraftedTextPart(copy: "two", priority: 2),
            CraftedTextPart(copy: "three", priority: 1),
        ])
        XCTAssertEqual(out.count, 3)
        for (above, below) in zip(out, out.dropFirst()) {
            XCTAssertLessThan(above.centerY, below.centerY, "reading order, top down")
        }
        let mid = (out.first!.centerY + out.last!.centerY) / 2
        XCTAssertEqual(mid, CraftedTextLayout.stackCenterY, accuracy: 0.08)
        for line in out {
            XCTAssertEqual(line.centerX, 0.5)
            XCTAssertGreaterThanOrEqual(line.centerY, 0.02)
            XCTAssertLessThanOrEqual(line.centerY, 0.98)
        }
    }

    func testEachLineFollowsTheOneAbove() {
        let out = lines([
            CraftedTextPart(copy: "one", priority: 3),
            CraftedTextPart(copy: "two", priority: 2),
            CraftedTextPart(copy: "three", priority: 1),
        ])
        XCTAssertNil(out[0].followsIndex)
        XCTAssertEqual(out[1].followsIndex, 0)
        XCTAssertEqual(out[2].followsIndex, 1)
    }

    func testAtMostFiveLinesAndBlanksDropped() {
        let out = lines((1...8).map { CraftedTextPart(copy: "line \($0)", priority: 2) })
        XCTAssertEqual(out.count, 5)
        XCTAssertTrue(lines([CraftedTextPart(copy: "   ", priority: 1)]).isEmpty)
        XCTAssertTrue(lines([]).isEmpty)
    }

    // MARK: - Emphasis runs

    func testEmphasisBecomesItsOwnRun() {
        let part = CraftedTextPart(copy: "helps wash away the woes",
                                   emphasis: ["wash away the woes"], priority: 1)
        let out = CraftedTextLayout.runs(for: part, style: .forPriority(1))
        XCTAssertEqual(out.map(\.text), ["helps ", "wash away the woes"])
        XCTAssertEqual(out[0].colorHex, "#FFB340")
        XCTAssertEqual(out[1].colorHex, "#FFFFFF")
        XCTAssertEqual(out[1].isBold, true)
        XCTAssertEqual(out.map(\.text).joined(), part.copy, "the copy survives exactly")
    }

    func testEmphasisIsOrderedByTheCopyNotTheModel() {
        // Listed back to front by the model; drawn in the copy's own order.
        // The line is long enough that the coverage guard stays out of it.
        let part = CraftedTextPart(copy: "salt air and slow steps along the shore",
                                   emphasis: ["slow steps", "salt"], priority: 2)
        let out = CraftedTextLayout.runs(for: part, style: .forPriority(2))
        XCTAssertEqual(out.map(\.text),
                       ["salt", " air and ", "slow steps", " along the shore"])
        XCTAssertEqual(out.map(\.text).joined(), part.copy)
    }

    func testEmphasisTheCopyLacksIsIgnored() {
        // A model that paraphrases its own emphasis must not corrupt the copy.
        let part = CraftedTextPart(copy: "walk until the tide forgets",
                                   emphasis: ["something else entirely"], priority: 2)
        let out = CraftedTextLayout.runs(for: part, style: .forPriority(2))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, part.copy)
    }

    func testEmphasisMatchesCaseInsensitivelyAndKeepsTheCopysCase() {
        let part = CraftedTextPart(copy: "is worth a LITTLE visit?",
                                   emphasis: ["little"], priority: 3)
        let out = CraftedTextLayout.runs(for: part, style: .forPriority(3))
        XCTAssertEqual(out.map(\.text), ["is worth a ", "LITTLE", " visit?"])
    }

    // MARK: - The no-model splitter

    func testSplitterBreaksOnPunctuationAndMakesTheLastLineThePayoff() {
        let parts = CraftedTextLayout.split("Salt air, slow steps, nothing owed")
        XCTAssertEqual(parts.map(\.copy), ["Salt air", "slow steps", "nothing owed"])
        XCTAssertEqual(parts.last?.priority, 1)
        XCTAssertEqual(parts[0].priority, 2)
        XCTAssertEqual(parts[1].priority, 3)
    }

    func testSplitterHalvesOneLongLine() {
        let parts = CraftedTextLayout.split("A little sand between your toes helps wash the woes")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts.map(\.copy).joined(separator: " "),
                       "A little sand between your toes helps wash the woes")
    }

    func testSplitterLeavesAShortLineAlone() {
        let parts = CraftedTextLayout.split("Prague")
        XCTAssertEqual(parts.map(\.copy), ["Prague"])
        XCTAssertEqual(parts[0].priority, 1)
        XCTAssertEqual(parts[0].emphasis, ["Prague"])
    }

    func testSplitterCapsAtFiveAndNominatesTheLongestWord()  {
        let parts = CraftedTextLayout.split("one. two. three. four. five. six. seven.")
        XCTAssertEqual(parts.count, 5)
        let long = CraftedTextLayout.split("go extraordinary now")
        XCTAssertEqual(long[0].emphasis, ["extraordinary"])
        XCTAssertEqual(CraftedTextLayout.split("a b cd").first?.emphasis, [],
                       "nothing worth emphasising in three short words")
    }

    func testRevealBandFinishesJustBeforeThePlayhead() {
        let band = CraftedTextLayout.revealBand(at: 0.5)
        XCTAssertEqual(band.start, 0.44, accuracy: 1e-9)
        XCTAssertEqual(band.end, 0.49, accuracy: 1e-9)
        XCTAssertLessThan(band.start, band.end)
        let atZero = CraftedTextLayout.revealBand(at: 0)
        XCTAssertGreaterThanOrEqual(atZero.start, 0)
        XCTAssertLessThanOrEqual(atZero.start, atZero.end)
    }

    // MARK: - The prompt

    // The prompt is not decoration: every rule in it is holding something
    // down, and a well-meaning edit that drops one is exactly the kind of
    // regression nothing else would catch.
    func testSplitPromptCarriesItsLoadBearingRules() {
        let prompt = CraftedTextPrompt.split(brief: "a little sand")
        XCTAssertTrue(prompt.contains("\"\"\"a little sand\"\"\""), "the brief is quoted")
        XCTAssertTrue(prompt.contains("AT MOST 5"), "the layout can place five lines and no more")
        XCTAssertTrue(prompt.contains("do not rewrite it"), "finished copy is split, not improved")
        XCTAssertTrue(prompt.contains("Never invent facts"), "no invented prices or URLs")
        XCTAssertTrue(prompt.contains("exactly one line is priority 1"))
        XCTAssertTrue(prompt.contains("MUST appear in that line's copy"))
        XCTAssertTrue(prompt.contains("{\"parts\":"), "the shape it must answer in")
    }

    func testCandidatesPromptAsksForThreeUsableLines() {
        let prompt = CraftedTextPrompt.candidates(brief: "the beach")
        XCTAssertTrue(prompt.contains("\"\"\"the beach\"\"\""))
        XCTAssertTrue(prompt.contains("3 DIFFERENT directions"))
        XCTAssertTrue(prompt.contains("the words themselves"),
                      "a direction is copy, not a description of copy")
        XCTAssertTrue(prompt.contains("{\"options\":"))
    }

    func testABriefCannotCloseThePromptsOwnFence() {
        // Found by sending it: a brief containing triple quotes ended the
        // fence early, the model read the rest as instructions, and it
        // answered with a sentence of prose and no JSON at all.
        let brief = #"The brief contains """ triple quotes """ inside it"#
        let prompt = CraftedTextPrompt.split(brief: brief)
        // Exactly two fences — the ones the prompt itself opens and closes.
        let fences = prompt.components(separatedBy: "\"\"\"").count - 1
        XCTAssertEqual(fences, 2, "the brief no longer opens a fence of its own")
        XCTAssertTrue(prompt.contains("triple quotes"), "the words still get through")
    }

    func testSanitisingKeepsOrdinaryQuotesAndTrimsRunaway() {
        XCTAssertEqual(
            CraftedTextPrompt.sanitised(#"She said "the light here is unreal""#),
            #"She said "the light here is unreal""#,
            "one quote is punctuation someone meant")
        XCTAssertFalse(CraftedTextPrompt.sanitised(#"a """ b"#).contains(#"""""#))
        XCTAssertEqual(
            CraftedTextPrompt.sanitised(String(repeating: "x", count: 5000)).count,
            CraftedTextPrompt.briefLimit,
            "a pasted essay is capped before it eats the context")
    }

    // MARK: - Reading the answer

    func testACleanAnswerParses() throws {
        let parts = try CraftedTextResponse.parts(from: """
            {"parts":[{"copy":"Don't you think","emphasis":["think"],"priority":2},
                      {"copy":"Prague","emphasis":["Prague"],"priority":1}]}
            """)
        XCTAssertEqual(parts.map(\.copy), ["Don't you think", "Prague"])
        XCTAssertEqual(parts.map(\.priority), [2, 1])
        XCTAssertEqual(parts[0].emphasis, ["think"])
    }

    func testProseAroundTheJSONIsSurvivable() throws {
        // A local model explains itself far too often to treat as an error.
        let parts = try CraftedTextResponse.parts(from: """
            Sure! Here is the JSON:
            {"parts":[{"copy":"nothing owed","emphasis":[],"priority":1}]}
            Let me know if you'd like another tone.
            """)
        XCTAssertEqual(parts.map(\.copy), ["nothing owed"])
    }

    func testLooseTypesAreCoerced() throws {
        // A bare string where an array belongs, and a priority as a string
        // and as a float — all three turn up in practice.
        let parts = try CraftedTextResponse.parts(from: """
            {"parts":[{"copy":"Walk until the tide","emphasis":"tide","priority":"2"},
                      {"copy":"forgets your name","emphasis":["name"],"priority":1.0}]}
            """)
        XCTAssertEqual(parts[0].emphasis, ["tide"])
        XCTAssertEqual(parts[0].priority, 2)
        XCTAssertEqual(parts[1].priority, 1)
    }

    func testAnUnreadablePriorityFallsBackAndTheLoneLineIsThePayoff() throws {
        // "the most important one" is not a number, so it reads as a middle
        // line — and normalisation then promotes it, because a single line
        // with no payoff would be drawn as if it were an aside.
        let parts = try CraftedTextResponse.parts(from:
            #"{"parts":[{"copy":"a line","priority":"the most important one"}]}"#)
        XCTAssertEqual(parts[0].priority, 1)
    }

    func testPriorityIsClampedIntoTheTable() throws {
        let parts = try CraftedTextResponse.parts(from:
            #"{"parts":[{"copy":"low","priority":99},{"copy":"high","priority":-3}]}"#)
        XCTAssertEqual(parts.map(\.priority), [5, 1])
    }

    func testEmphasisTheCopyNeverSaysIsDroppedAtParseTime() throws {
        // Dropped HERE rather than at layout time, so the model's answer and
        // what gets drawn cannot disagree quietly.
        let parts = try CraftedTextResponse.parts(from: """
            {"parts":[{"copy":"Barefoot is a state of mind","emphasis":["something else"],"priority":1}]}
            """)
        XCTAssertEqual(parts[0].emphasis, [])
    }

    func testAtMostFivePartsSurvive() throws {
        let entries = (1...9).map { #"{"copy":"line \#($0)","priority":2}"# }
            .joined(separator: ",")
        let parts = try CraftedTextResponse.parts(from: #"{"parts":[\#(entries)]}"#)
        XCTAssertEqual(parts.count, 5)
    }

    func testPartsWithNoCopyAreRefusedRatherThanInvented() {
        XCTAssertThrowsError(try CraftedTextResponse.parts(from:
            #"{"parts":[{"emphasis":["nothing"],"priority":1},{"copy":"   "}]}"#)) { error in
            XCTAssertEqual(error as? CraftedTextResponse.Failure, .noUsableParts)
        }
    }

    func testAnAnswerWithNoJSONOrTheWrongShapeIsRefused() {
        XCTAssertThrowsError(try CraftedTextResponse.parts(
            from: "I'm sorry, I can't help with that.")) { error in
            XCTAssertEqual(error as? CraftedTextResponse.Failure, .noJSONObject)
        }
        XCTAssertThrowsError(try CraftedTextResponse.parts(
            from: #"{"lines":["wrong key"],"confidence":0.4}"#)) { error in
            XCTAssertEqual(error as? CraftedTextResponse.Failure, .noPartsArray)
        }
    }

    func testOptionsParseAndCapAtThree() throws {
        XCTAssertEqual(
            try CraftedTextResponse.options(from: #"{"options":["one","two","three","four"]}"#),
            ["one", "two", "three"])
        XCTAssertEqual(
            try CraftedTextResponse.options(from: #"{"options":"just the one"}"#),
            ["just the one"])
        XCTAssertEqual(
            try CraftedTextResponse.options(from: #"{"parts":[{"copy":"x"}]}"#), [],
            "a parts answer read as options is empty, not an error")
    }

    // MARK: - What the real model actually does
    //
    // Every case below was taken from a sweep of ten briefs through
    // mlx-community/gemma-4-e2b-it-4bit on 2026-09-04 — the first time the
    // path had seen a real token stream. None of it is hypothetical.

    func testEnumeratedEmphasisIsDropped() {
        // "Visit Prague this summer" came back with three of its four words
        // emphasised, which inverts the scheme: the payoff line is amber, so
        // white-bolding most of it leaves an amber line with white words.
        let part = CraftedTextPart(copy: "Visit Prague this summer",
                                   emphasis: ["Visit", "Prague", "summer"], priority: 1)
        let out = CraftedTextLayout.runs(for: part, style: .forPriority(1))
        XCTAssertEqual(out.count, 1, "the enumeration is dropped whole")
        XCTAssertEqual(out[0].text, "Visit Prague this summer")
        XCTAssertEqual(out[0].colorHex, "#FFB340", "the line keeps its own colour")
    }

    func testEveryWordEmphasisedIsDropped() {
        // "Grand opening" → ["Grand", "opening"]. 100%, twice over.
        let part = CraftedTextPart(copy: "Grand opening",
                                   emphasis: ["Grand", "opening"], priority: 2)
        XCTAssertEqual(CraftedTextLayout.runs(for: part, style: .forPriority(2)).count, 1)
    }

    func testOneLongPhraseIsStillAHighlight() {
        // The design's own example: 86% of the line, and obviously right,
        // because it is ONE stretch. Coverage alone would have killed it —
        // which is why the guard counts stretches.
        let part = CraftedTextPart(copy: "helps wash away the woes",
                                   emphasis: ["wash away the woes"], priority: 1)
        let out = CraftedTextLayout.runs(for: part, style: .forPriority(1))
        XCTAssertEqual(out.map(\.text), ["helps ", "wash away the woes"])
    }

    func testTwoModerateStretchesSurvive() {
        // "Sunset over the Vltava" → ["Sunset", "Vltava"] at 63%: exactly the
        // emphasis this feature is for, and it has to come through.
        let part = CraftedTextPart(copy: "Sunset over the Vltava",
                                   emphasis: ["Sunset", "Vltava"], priority: 2)
        let out = CraftedTextLayout.runs(for: part, style: .forPriority(2))
        XCTAssertEqual(out.map(\.text), ["Sunset", " over the ", "Vltava"])
    }

    func testASingleWordLineDoesNotEmphasiseItself() {
        let part = CraftedTextPart(copy: "Prague", emphasis: ["Prague"], priority: 1)
        XCTAssertEqual(CraftedTextLayout.runs(for: part, style: .forPriority(1)).count, 1)
    }

    func testAStemEmphasisSnapsToTheWholeWord() {
        // "Time passes." came back with emphasis ["pass"], which a plain
        // substring match drew as Time **pass**es — a word split in half.
        let part = CraftedTextPart(copy: "Time passes.", emphasis: ["pass"], priority: 2)
        let out = CraftedTextLayout.runs(for: part, style: .forPriority(2))
        XCTAssertEqual(out.map(\.text), ["Time ", "passes", "."])
        XCTAssertEqual(out[1].isBold, true)
        XCTAssertEqual(out.map(\.text).joined(), part.copy, "the copy survives exactly")
    }

    func testAPhraseAlreadyOnBoundariesIsUntouched() {
        let part = CraftedTextPart(copy: "helps wash away the woes",
                                   emphasis: ["wash away the woes"], priority: 1)
        XCTAssertEqual(
            CraftedTextLayout.runs(for: part, style: .forPriority(1)).map(\.text),
            ["helps ", "wash away the woes"])
    }

    func testSnappingKeepsAnApostropheWordWhole() {
        let part = CraftedTextPart(copy: "Whether you don't.", emphasis: ["don"], priority: 2)
        let out = CraftedTextLayout.runs(for: part, style: .forPriority(2))
        XCTAssertEqual(out.map(\.text), ["Whether you ", "don't", "."])
    }

    func testAnAnswerWithNoPayoffGetsOne() throws {
        // "Time passes whether you watch it or not" came back as priorities
        // 2, 3, 4, 5 — no payoff at all, so nothing would have been drawn
        // amber or large. The last line is promoted, as the splitter does.
        let parts = try CraftedTextResponse.parts(from: """
            {"parts":[{"copy":"Time passes","priority":2},
                      {"copy":"whether you watch it","priority":3},
                      {"copy":"or not","priority":4}]}
            """)
        XCTAssertEqual(parts.map(\.priority), [2, 3, 1])
    }

    func testASecondPayoffIsDemoted() throws {
        let parts = try CraftedTextResponse.parts(from: """
            {"parts":[{"copy":"first","priority":1},{"copy":"second","priority":1}]}
            """)
        XCTAssertEqual(parts.map(\.priority), [1, 2], "one payoff, the first one")
    }

    func testARepeatedLineIsDropped() throws {
        // The same sweep: "Time passes." came back twice in one answer, which
        // would have stacked the same words on the frame.
        let parts = try CraftedTextResponse.parts(from: """
            {"parts":[{"copy":"Time passes.","priority":2},
                      {"copy":"Whether you watch it","priority":3},
                      {"copy":"time passes","priority":5}]}
            """)
        XCTAssertEqual(parts.map(\.copy), ["Time passes.", "Whether you watch it"])
        XCTAssertEqual(parts.last?.priority, 1, "and the survivor becomes the payoff")
    }

    func testAMarkdownFencedAnswerParses() throws {
        // EVERY one of the ten real answers came back fenced. The first-brace
        // scan already handled it; this pins that it keeps doing so.
        let parts = try CraftedTextResponse.parts(from: """
            ```json
            {"parts":[{"copy":"Visit Prague","emphasis":[],"priority":1}]}
            ```
            """)
        XCTAssertEqual(parts.map(\.copy), ["Visit Prague"])
    }

    // MARK: - The answer, laid out

    func testAParsedAnswerLandsAsAChainOfLines() throws {
        // The seam the CLI exists for: a generation in, layers out.
        let parts = try CraftedTextResponse.parts(from: """
            {"parts":[{"copy":"Don't you think","emphasis":["think"],"priority":2},
                      {"copy":"is worth a little visit?","emphasis":["little"],"priority":3},
                      {"copy":"Prague","emphasis":["Prague"],"priority":1}]}
            """)
        let out = lines(parts)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[2].style.colorHex, "#FFB340", "the payoff is the amber one")
        XCTAssertEqual(out.map(\.followsIndex), [nil, 0, 1], "each line follows the one above")
        XCTAssertEqual(out[0].runs.map(\.text).joined(), "Don't you think",
                       "the copy survives the run split exactly")
        XCTAssertEqual(out[1].runs.count, 3,
                       "a highlight inside a line becomes its own run")
        XCTAssertTrue(out[1].runs.contains { $0.isBold == true })
        XCTAssertEqual(out[2].runs.count, 1,
                       #""Prague" emphasising "Prague" is the whole line — dropped"#)
    }

    func testTheEstimatedWidthIsMonotonicAndFontFree() {
        // What the headless path fits against: no font, same answer on every
        // machine, and longer copy is always wider.
        let style = CraftedTextStyle.forPriority(2)
        let short = CraftedTextLayout.estimatedEmWidth(of: "sand", style: style)
        let long = CraftedTextLayout.estimatedEmWidth(of: "sand between your toes", style: style)
        XCTAssertGreaterThan(long, short)
        XCTAssertGreaterThan(CraftedTextLayout.estimatedEmWidth(of: "mmm", style: style),
                             CraftedTextLayout.estimatedEmWidth(of: "iii", style: style),
                             "wide glyphs measure wider than narrow ones")
        XCTAssertEqual(CraftedTextLayout.estimatedEmWidth(of: "", style: style), 0.001,
                       accuracy: 1e-9, "never zero — it is a divisor")
    }

    // MARK: - Independent position

    private func layer(_ id: UUID, follows: UUID? = nil, independent: Bool = false)
        -> OverlaySequencing.Layer {
        var animation = OverlayAnimation(
            reveal: OverlayReveal(unit: .element, style: .fade, start: 0.1, end: 0.2))
        if let follows {
            animation.follows = OverlayFollow(
                layerID: follows, gap: 0, independentPosition: independent)
        }
        return OverlaySequencing.Layer(id: id, animation: animation)
    }

    func testMoversAreTheFollowersThatTravelWithAParent() {
        let a = UUID(), b = UUID(), c = UUID()
        let layers = [layer(a), layer(b, follows: a), layer(c, follows: b)]
        XCTAssertEqual(Set(OverlaySequencing.movers(of: a, in: layers)), [b, c],
                       "the whole chain comes along")
        XCTAssertEqual(OverlaySequencing.movers(of: c, in: layers), [])
    }

    func testAnIndependentFollowerStaysPutAndKeepsItsOwnSubtreeBehind() {
        let a = UUID(), b = UUID(), c = UUID()
        // b holds its position; c follows b, so c is pinned to b, not to a.
        let layers = [layer(a), layer(b, follows: a, independent: true), layer(c, follows: b)]
        XCTAssertEqual(OverlaySequencing.movers(of: a, in: layers), [],
                       "an independent subtree opts its children out too")
        XCTAssertEqual(OverlaySequencing.movers(of: b, in: layers), [c])
        // Timing is untouched by any of this.
        var resolving = layers
        OverlaySequencing.resolve(&resolving)
        XCTAssertNotNil(resolving[1].animation?.follows, "still linked in time")
        XCTAssertEqual(resolving[1].animation!.reveal.start, 0.2, accuracy: 1e-9,
                       "and still re-seated after its parent")
    }

    func testMoversNeverIncludeTheDraggedLayerOrLoop() {
        let a = UUID(), b = UUID()
        var layers = [layer(a, follows: b), layer(b, follows: a)]
        XCTAssertFalse(OverlaySequencing.movers(of: a, in: layers).contains(a))
        OverlaySequencing.resolve(&layers)
        XCTAssertNotNil(OverlaySequencing.movers(of: a, in: layers))
    }

    func testIndependentPositionRoundTripsAndDefaultsOffOnOlderSidecars() throws {
        let parent = UUID()
        let follow = OverlayFollow(layerID: parent, gap: 0.02, independentPosition: true)
        let data = try JSONEncoder().encode(follow)
        XCTAssertEqual(try JSONDecoder().decode(OverlayFollow.self, from: data), follow)
        // A sidecar written before the flag existed: parent and gap only.
        let older = #"{"p":"\#(parent.uuidString)","g":0.02}"#
        let decoded = try JSONDecoder().decode(
            OverlayFollow.self, from: Data(older.utf8))
        XCTAssertEqual(decoded.layerID, parent)
        XCTAssertFalse(decoded.independentPosition, "off unless it says otherwise")
    }
}
