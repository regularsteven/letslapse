import SwiftUI
import AVFoundation
import os

/// **Experimental spike.** A soundtrack that reacts to the timelapse speed profile.
///
/// LetsLapse's primary mode is HIGH SPEED: timelapse compresses hours into seconds.
/// Slow-motion burst clips are the exception. The musical energy model reflects that:
///
/// - fast (4×) = DROP — this is the normal state. Dense, full energy.
/// - normal (1×) = VERSE — transitional feel, drums but no double-time.
/// - slow (0.5×) = BREAKDOWN — nearly silent, atmospheric; sets up the next drop.
///
/// The demo envelope starts at 4× and treats slow-motion as the dramatic exception.
/// A real version will read speed sections directly from the project's blend metadata
/// (compressionRatio, sourceFPS, rampStart/rampEnd).
///
/// UI controls: genre, scale (major/minor), pad type, kick style (normal/double/heavy).
/// Generate Bed randomises key, progression (8-pattern library), and BPM each press.
struct MusicView: View {
    @StateObject private var engine = MusicBedEngine()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header

                LLSectionHeader("Speed envelope")
                envelopeCard
                    .padding(.bottom, 12)

                LLSectionHeader("Bed")
                bedCard
                    .padding(.bottom, 12)

                LLSectionHeader("Sound")
                soundCard
                    .padding(.bottom, 12)

                LLSectionHeader("Playback")
                playbackCard

                Text("Demo envelope — a real version reads speed sections from the project's blend metadata.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 10)

                Spacer(minLength: 96)
            }
            .padding(.horizontal, 16)
        }
        .background(LL.screenBackground)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #else
        .navigationTitle("Music")
        #endif
        .onDisappear { engine.stop() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Music")
                .font(.system(size: 34, weight: .bold))
            Text("Experimental")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LL.amber)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: - Speed envelope

    private var envelopeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(engine.activeSection.label)
                    .font(.system(size: 15, weight: .semibold))
                Text(SpeedSection.multiplierText(engine.activeSection.speedMultiplier))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(engine.timeFeel.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(LL.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(LL.accent.opacity(0.12), in: Capsule())
            }

            SpeedEnvelopeGraph(
                sections: engine.sections,
                activeIndex: engine.sectionIndex,
                playhead: engine.playhead,
                isRunning: engine.status == .playing
            )
            .frame(height: 104)

            Text("Chord \(engine.chordName) · bar \(engine.barNumber) of \(engine.barCount)")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .llCard()
    }

    // MARK: - Bed (genre + generate)

    private var bedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Genre chips
            HStack(spacing: 8) {
                ForEach(MusicBedEngine.Genre.allCases) { genre in
                    Button {
                        engine.select(genre)
                    } label: {
                        Text(genre.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(genre == engine.genre ? Color.white : .primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                genre == engine.genre ? LL.ink : LL.screenBackground,
                                in: Capsule()
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(genre == engine.genre ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }

            Button("Generate Bed") { engine.generateBed() }
                .buttonStyle(LLPrimaryButtonStyle())

            VStack(alignment: .leading, spacing: 3) {
                Text(engine.status.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(engine.bedSummary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .llCard()
    }

    // MARK: - Sound controls

    private var soundCard: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Scale
            VStack(alignment: .leading, spacing: 6) {
                Text("Scale")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(MusicBedEngine.Scale.allCases) { scale in
                        Button {
                            engine.setScale(scale)
                        } label: {
                            Text(scale.label)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(scale == engine.scale ? Color.white : .primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    scale == engine.scale ? LL.accent : LL.screenBackground,
                                    in: Capsule()
                                )
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }

            // Pad type
            VStack(alignment: .leading, spacing: 6) {
                Text("Pad")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(MusicBedEngine.PadType.allCases) { pt in
                            Button {
                                engine.setPadType(pt)
                            } label: {
                                Text(pt.label)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(pt == engine.padType ? Color.white : .primary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(
                                        pt == engine.padType ? LL.ink : LL.screenBackground,
                                        in: Capsule()
                                    )
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Kick style
            VStack(alignment: .leading, spacing: 6) {
                Text("Kick")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(MusicBedEngine.KickStyle.allCases) { ks in
                        Button {
                            engine.setKickStyle(ks)
                        } label: {
                            VStack(spacing: 2) {
                                Text(ks.label)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(ks.sublabel)
                                    .font(.system(size: 10))
                            }
                            .foregroundStyle(ks == engine.kickStyle ? Color.white : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                ks == engine.kickStyle ? LL.ink : LL.screenBackground,
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .llCard()
    }

    // MARK: - Playback

    private var playbackCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(engine.status == .playing ? "Stop" : "Play") {
                engine.togglePlayback()
            }
            .buttonStyle(LLPrimaryButtonStyle(tint: engine.status == .playing ? LL.accentDeep : LL.accent))

            LevelMeter(level: engine.level)
                .frame(height: 10)

            Text(engine.status == .playing ? "Output level" : "Silent")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .llCard()
    }
}

// MARK: - Speed envelope model

/// One stretch of a timelapse that plays at a constant speed.
/// The demo starts FAST — fast is the normal LetsLapse mode.
private struct SpeedSection: Identifiable {
    let id = UUID()
    let label: String
    let durationSeconds: Double
    let speedMultiplier: Double   // >1 = timelapse, <1 = slow motion relative to timelapse

    var shortLabel: String {
        switch label {
        case "Timelapse": return "Fast"
        case "Slow-mo":   return "Slow"
        case "Ramp up":   return "Ramp ↑"
        case "Ramp down": return "Ramp ↓"
        default:          return label
        }
    }

    static func multiplierText(_ multiplier: Double) -> String {
        multiplier < 1
            ? String(format: "×%.1f", multiplier)
            : String(format: "×%.0f", multiplier)
    }

    /// Demo envelope: starts at timelapse speed (the norm), dips into
    /// slow-motion (the exception), then returns to full speed.
    /// Mirrors a typical LetsLapse project structure.
    static let demo: [SpeedSection] = [
        SpeedSection(label: "Timelapse", durationSeconds: 5, speedMultiplier: 4.0),
        SpeedSection(label: "Ramp down", durationSeconds: 2, speedMultiplier: 1.0),
        SpeedSection(label: "Slow-mo",   durationSeconds: 4, speedMultiplier: 0.5),
        SpeedSection(label: "Ramp up",   durationSeconds: 2, speedMultiplier: 1.0),
        SpeedSection(label: "Timelapse", durationSeconds: 5, speedMultiplier: 4.0),
    ]
}

// MARK: - Envelope graph

private struct SpeedEnvelopeGraph: View {
    var sections: [SpeedSection]
    var activeIndex: Int
    var playhead: Double
    var isRunning: Bool

    private let gap: CGFloat = 2
    private let graphHeight: CGFloat = 84

    private var total: Double {
        max(0.001, sections.reduce(0) { $0 + $1.durationSeconds })
    }

    var body: some View {
        GeometryReader { geo in
            let usable = max(0, geo.size.width - gap * CGFloat(max(0, sections.count - 1)))
            VStack(spacing: 6) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LL.ink)
                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                            block(section, isActive: index == activeIndex)
                                .frame(width: width(of: section, usable: usable))
                        }
                    }
                    .padding(.vertical, 8)
                    if isRunning {
                        Capsule()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 2, height: graphHeight - 12)
                            .offset(x: geo.size.width * CGFloat(playhead / total), y: 6)
                            .animation(.linear(duration: 0.12), value: playhead)
                    }
                }
                .frame(height: graphHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: gap) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        Text(section.shortLabel)
                            .font(.system(size: 9.5, weight: index == activeIndex ? .semibold : .regular))
                            .foregroundStyle(index == activeIndex ? LL.accent : Color.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .frame(width: width(of: section, usable: usable))
                    }
                }
            }
        }
    }

    private func width(of section: SpeedSection, usable: CGFloat) -> CGFloat {
        max(0, usable * CGFloat(section.durationSeconds / total))
    }

    private func height(for multiplier: Double) -> CGFloat {
        let fraction = (log2(max(0.25, multiplier)) + 1) / 3
        return 18 + CGFloat(min(1, max(0, fraction))) * (graphHeight - 16 - 18)
    }

    @ViewBuilder
    private func block(_ section: SpeedSection, isActive: Bool) -> some View {
        let bh = height(for: section.speedMultiplier)
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LL.amber.opacity(isActive ? 1 : 0.42))
            .frame(height: bh)
            .overlay(alignment: .top) {
                if bh >= 32 {
                    Text(SpeedSection.multiplierText(section.speedMultiplier))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isActive ? LL.ink : Color.white.opacity(0.72))
                        .padding(.top, 4)
                }
            }
    }
}

// MARK: - Level meter

private struct LevelMeter: View {
    var level: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(LL.ink.opacity(0.12))
                Capsule()
                    .fill(LinearGradient(colors: [LL.accent, LL.amber],
                                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, level))))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Engine

private final class MusicBedEngine: ObservableObject {

    // MARK: Types

    enum Status {
        case ready, playing, stopped
        var title: String {
            switch self {
            case .ready: return "Ready"
            case .playing: return "Playing"
            case .stopped: return "Stopped"
            }
        }
    }

    enum Genre: String, CaseIterable, Identifiable {
        case synthwave, dubstep, electronic
        var id: String { rawValue }
        var title: String {
            switch self {
            case .synthwave: return "Synthwave"
            case .dubstep: return "Dubstep"
            case .electronic: return "Electronic"
            }
        }
        var baseBPM: Double {
            switch self {
            case .synthwave: return 100
            case .dubstep: return 140
            case .electronic: return 124
            }
        }
        var padDetune: Double {
            switch self {
            case .synthwave: return 0.007
            case .dubstep: return 0.011
            case .electronic: return 0.004
            }
        }
        var hatLevel: Double {
            switch self { case .synthwave: return 0.42; case .dubstep: return 0.68; case .electronic: return 0.55 }
        }
        var snareLevel: Double {
            switch self { case .synthwave: return 0.75; case .dubstep: return 0.92; case .electronic: return 0.80 }
        }
    }

    /// Major or minor scale — wires through to chord construction.
    enum Scale: String, CaseIterable, Identifiable {
        case minor, major
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var thirdSemitones: Double { self == .minor ? 3 : 4 }
    }

    /// How the pad synthesiser sounds.
    enum PadType: String, CaseIterable, Identifiable {
        case supersaw, pluck, strings, glass
        var id: String { rawValue }
        var label: String {
            switch self {
            case .supersaw: return "Supersaw"
            case .pluck: return "Pluck"
            case .strings: return "Strings"
            case .glass: return "Glass"
            }
        }
        var detune: Double {
            switch self { case .supersaw: return 0.007; case .pluck: return 0.003; case .strings: return 0.011; case .glass: return 0.001 }
        }
        /// Level coefficient (0–1) sent to Voices.
        var levelMult: Double {
            switch self { case .supersaw: return 1.0; case .pluck: return 0.85; case .strings: return 0.90; case .glass: return 0.75 }
        }
        /// Attack time in ms.
        var attackMs: Double {
            switch self { case .supersaw: return 250; case .pluck: return 4; case .strings: return 600; case .glass: return 8 }
        }
    }

    /// Kick drum style.
    enum KickStyle: String, CaseIterable, Identifiable {
        case standard, double, heavy
        var id: String { rawValue }
        var label: String {
            switch self { case .standard: return "Standard"; case .double: return "Double"; case .heavy: return "Heavy" }
        }
        var sublabel: String {
            switch self { case .standard: return "four on floor"; case .double: return "8th notes"; case .heavy: return "metal sub" }
        }
    }

    enum TimeFeel {
        case half, straight, double
        init(multiplier: Double) {
            if multiplier >= 2 { self = .double }
            else if multiplier <= 0.5 { self = .half }
            else { self = .straight }
        }
        var label: String {
            switch self { case .half: return "breakdown"; case .straight: return "verse"; case .double: return "drop" }
        }
        var rate: Double { switch self { case .half: return 0.5; case .straight: return 1; case .double: return 2 } }
        var sectionEnergy: Double { switch self { case .half: return 0.18; case .straight: return 0.58; case .double: return 1.0 } }
    }

    // MARK: Chord / progression

    private struct Chord {
        let name: String; let root: Double; let tones: (Double, Double, Double)
        var arp: [Double] { let (t0,t1,t2) = tones; return [t0,t1,t2,t0*2,t2,t1,t2*2,t0] }
    }

    private static let progressionTemplates: [(name: String, steps: [(Int, Bool)])] = [
        ("i–VI–III–VII",  [(0,true),(5,false),(3,false),(7,false)]),
        ("i–iv–VII–VI",   [(0,true),(2,true),(10,false),(5,false)]),
        ("i–VII–VI–III",  [(0,true),(10,false),(5,false),(3,false)]),
        ("i–III–VII–VI",  [(0,true),(3,false),(7,false),(5,false)]),
        ("i–iv–i–V",      [(0,true),(2,true),(0,true),(7,false)]),
        ("VI–i–VII–III",  [(5,false),(0,true),(7,false),(3,false)]),
        ("i–VI–VII–V",    [(0,true),(5,false),(7,false),(7,false)]),
        ("i–VII–i–V",     [(0,true),(10,false),(0,true),(7,false)]),
    ]

    private static let majorProgressionTemplates: [(name: String, steps: [(Int, Bool)])] = [
        ("I–V–vi–IV",     [(0,false),(7,false),(9,true),(5,false)]),
        ("I–IV–V–IV",     [(0,false),(5,false),(7,false),(5,false)]),
        ("I–vi–IV–V",     [(0,false),(9,true),(5,false),(7,false)]),
        ("I–V–IV–I",      [(0,false),(7,false),(5,false),(0,false)]),
        ("I–II–IV–I",     [(0,false),(2,false),(5,false),(0,false)]),
        ("I–III–vi–V",    [(0,false),(4,false),(9,true),(7,false)]),
        ("IV–I–V–vi",     [(5,false),(0,false),(7,false),(9,true)]),
        ("I–vi–ii–V",     [(0,false),(9,true),(2,true),(7,false)]),
    ]

    private static let rootFrequencies: [Double] = [
        65.41,69.30,73.42,77.78,82.41,87.31,92.50,98.00,103.83,110.00,116.54,123.47
    ]
    private static let noteNames = ["C","C#","D","Eb","E","F","F#","G","Ab","A","Bb","B"]

    private func buildProgression(seed: UInt64, scale: Scale) -> ([Chord], String, Double) {
        let templates = scale == .minor ? Self.progressionTemplates : Self.majorProgressionTemplates
        let tIdx  = Int(seed % UInt64(templates.count))
        let rIdx  = Int((seed / 100) % 12)
        let bpmDelta = Double(seed % 22) - 11

        let template = templates[tIdx]
        let rootHz   = Self.rootFrequencies[rIdx]
        let rootNote = Self.noteNames[rIdx]

        let chords = template.steps.map { (semi, isMinor) -> Chord in
            let cr    = rootHz * pow(2.0, Double(semi) / 12.0)
            let third = cr * pow(2.0, (isMinor ? 3.0 : 4.0) / 12)
            let fifth = cr * pow(2.0, 7.0/12)
            return Chord(name: rootNote, root: cr*2, tones: (cr*2, third*2, fifth*2))
        }
        let pname = scale == .minor
            ? "\(rootNote)m · \(template.name)"
            : "\(rootNote) · \(template.name)"
        return (chords, pname, bpmDelta)
    }

    // MARK: Published state

    @Published private(set) var status: Status = .ready
    @Published private(set) var level: Double = 0
    @Published private(set) var sectionIndex = 0
    @Published private(set) var playhead: Double = 0
    @Published private(set) var timeFeel = TimeFeel(multiplier: SpeedSection.demo[0].speedMultiplier)
    @Published private(set) var chordName = "–"
    @Published private(set) var barNumber = 1
    @Published private(set) var genre: Genre = .synthwave
    @Published private(set) var bedSummary = "Synthwave · Generate to randomise"
    @Published private(set) var scale: Scale = .minor
    @Published private(set) var padType: PadType = .supersaw
    @Published private(set) var kickStyle: KickStyle = .standard

    let sections = SpeedSection.demo
    var activeSection: SpeedSection { sections[min(sectionIndex, sections.count - 1)] }
    var barCount: Int { max(1, Int(ceil(totalDuration / barSeconds))) }

    // MARK: Audio graph

    private let audioEngine  = AVAudioEngine()
    private let reverb = AVAudioUnitReverb()
    private let voices = VoiceBox()
    private var rhythmNode: AVAudioSourceNode?
    private var padNode:    AVAudioSourceNode?
    private var graphIsBuilt = false

    // MARK: Tempo grid (clock-queue-only)

    private let clockQueue = DispatchQueue(label: "com.regularsteven.letslapse.music-clock", qos: .userInitiated)
    private var clock: DispatchSourceTimer?
    private var clockInterval:     Double = 0
    private var clockPlayhead:     Double = 0
    private var lastSectionIndex          = -1
    private var tickProgression:  [Chord] = []
    private var tickBPM:          Double  = 100
    private var tickKickStyle:    KickStyle = .standard

    private var currentProgression: [Chord] = []
    private var currentBPM:         Double  = 100

    private var totalDuration: Double { sections.reduce(0) { $0 + $1.durationSeconds } }
    private var beatSeconds:   Double { 60 / currentBPM }
    private var barSeconds:    Double { beatSeconds * 4 }

    deinit { clock?.cancel(); if audioEngine.isRunning { audioEngine.stop() } }

    // MARK: Controls

    func setScale(_ s: Scale) { guard s != scale else { return }; scale = s; generateBed() }
    func setPadType(_ p: PadType) { padType = p; voices.write { $0.padAttackMs = p.attackMs; $0.padLevelMult = p.levelMult } }
    func setKickStyle(_ k: KickStyle) { kickStyle = k; clockQueue.async { self.tickKickStyle = k } }

    // MARK: Bed

    func generateBed() {
        let wasPlaying = status == .playing
        let seed = UInt64(arc4random()) ^ (UInt64(arc4random()) << 32)
        let (prog, name, bpmDelta) = buildProgression(seed: seed, scale: scale)
        currentProgression = prog
        currentBPM = genre.baseBPM + bpmDelta
        bedSummary = "\(genre.title) · \(scale.label) · \(Int(currentBPM)) BPM · \(name)"

        teardownGraph()
        resetClock()
        sectionIndex = 0; playhead = 0; barNumber = 1; level = 0
        chordName = prog.first?.name ?? "–"
        timeFeel = TimeFeel(multiplier: sections[0].speedMultiplier)
        status = .ready
        if wasPlaying { start() }
    }

    func select(_ newGenre: Genre) { guard newGenre != genre else { return }; genre = newGenre; generateBed() }

    // MARK: Transport

    func togglePlayback() { status == .playing ? stop() : start() }

    func start() {
        guard status != .playing else { return }
        if currentProgression.isEmpty { generateBed(); return }
        configureSession(active: true)
        do {
            try buildGraphIfNeeded()
            try audioEngine.start()
        } catch {
            configureSession(active: false); status = .stopped; return
        }
        status = .playing; startClock()
    }

    func stop() {
        guard status == .playing else { return }
        stopClock()
        if audioEngine.isRunning { audioEngine.stop() }
        voices.write { $0 = Voices() }
        configureSession(active: false); status = .stopped; level = 0
    }

    private func configureSession(active: Bool) {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if active {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
        } else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            PlaybackAudioSession.configureAmbient()
        }
        #endif
    }

    // MARK: Graph

    private func buildGraphIfNeeded() throws {
        guard !graphIsBuilt else { return }
        let outputRate = audioEngine.outputNode.outputFormat(forBus: 0).sampleRate
        let sr = outputRate > 0 ? outputRate : 44_100
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else {
            throw MusicSpikeError.unsupportedFormat
        }
        let rhythm = MusicBedEngine.makeRhythmNode(sampleRate: sr, voices: voices, format: format)
        let pad    = MusicBedEngine.makePadNode(sampleRate: sr, voices: voices, format: format,
                                               detune: genre.padDetune, padType: padType)
        reverb.loadFactoryPreset(.mediumHall); reverb.wetDryMix = 38
        audioEngine.attach(rhythm); audioEngine.attach(pad); audioEngine.attach(reverb)
        audioEngine.connect(rhythm, to: audioEngine.mainMixerNode, format: format)
        audioEngine.connect(pad, to: reverb, format: format)
        audioEngine.connect(reverb, to: audioEngine.mainMixerNode, format: format)
        audioEngine.mainMixerNode.outputVolume = 0.85

        audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let ch = buffer.floatChannelData?[0] else { return }
            var peak: Float = 0
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[i])) }
            let r = Double(min(1, peak * 1.5))
            DispatchQueue.main.async {
                guard let self, self.status == .playing else { return }
                self.level = r > self.level ? r : self.level * 0.72 + r * 0.28
            }
        }
        rhythmNode = rhythm; padNode = pad; graphIsBuilt = true; audioEngine.prepare()
    }

    private func teardownGraph() {
        stopClock(); if audioEngine.isRunning { audioEngine.stop() }
        guard graphIsBuilt else { return }
        audioEngine.mainMixerNode.removeTap(onBus: 0)
        if let rhythmNode { audioEngine.detach(rhythmNode) }
        if let padNode    { audioEngine.detach(padNode) }
        audioEngine.detach(reverb)
        rhythmNode = nil; padNode = nil; graphIsBuilt = false
        voices.write { $0 = Voices() }
    }

    // MARK: Clock

    private func startClock() {
        let beat = beatSeconds; let prog = currentProgression; let bpm = currentBPM; let ks = kickStyle
        clockQueue.async { [weak self] in
            guard let self else { return }
            self.tickProgression = prog; self.tickBPM = bpm; self.tickKickStyle = ks
            self.clock?.cancel()
            let interval = beat / self.feel(at: self.clockPlayhead).rate
            self.clockInterval = interval
            let timer = DispatchSource.makeTimerSource(queue: self.clockQueue)
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.clock = timer; timer.resume()
        }
    }
    private func stopClock() { clockQueue.async { self.clock?.cancel(); self.clock = nil; self.clockInterval = 0 } }
    private func resetClock() { clockQueue.async { self.clockPlayhead = 0; self.lastSectionIndex = -1 } }
    private func feel(at p: Double) -> TimeFeel { TimeFeel(multiplier: sections[sectionIndex(at: p)].speedMultiplier) }
    private func sectionIndex(at p: Double) -> Int {
        var e = 0.0
        for (i,s) in sections.enumerated() { e += s.durationSeconds; if p < e { return i } }
        return sections.count - 1
    }

    // MARK: Tick

    private func tick() {
        let beat = 60.0 / tickBPM; let bar = beat * 4
        let index = sectionIndex(at: clockPlayhead)
        let section = sections[index]; let sectionFeel = TimeFeel(multiplier: section.speedMultiplier)
        let interval = beat / sectionFeel.rate; let energy = sectionFeel.sectionEnergy
        let crossedBoundary = index != lastSectionIndex && lastSectionIndex >= 0
        lastSectionIndex = index

        let barIndex = Int(clockPlayhead / bar)
        let prog = tickProgression
        let chord = prog.isEmpty ? defaultChord : prog[barIndex % prog.count]

        let positionInBar = clockPlayhead.truncatingRemainder(dividingBy: bar)
        let beatInBar     = Int(positionInBar / beat)
        let isOnBackbeat  = beatInBar == 1 || beatInBar == 3
        let stepsPerBar   = max(1, Int((bar / interval).rounded()))
        let step          = Int((positionInBar / interval).rounded()) % stepsPerBar
        let eighthIndex   = Int((positionInBar / (beat * 0.5)).rounded()) % 8
        let arpFreq       = chord.arp[eighthIndex % chord.arp.count]

        let ks = tickKickStyle

        voices.write { v in
            v.tickSeconds = interval
            v.padTone0 = chord.tones.0; v.padTone1 = chord.tones.1; v.padTone2 = chord.tones.2
            v.padLevel = energy * 0.9

            guard sectionFeel != .half else {
                // BREAKDOWN: just a slow bass pulse, no drums
                if step % stepsPerBar == 0 {
                    v.bassFrequency = chord.root; v.bassTrigger &+= 1
                }
                if crossedBoundary { v.riserTrigger &+= 1; v.impactTrigger &+= 1 }
                return
            }

            // Kick — style-dependent
            switch ks {
            case .standard:
                // Four-on-the-floor (beats 1,2,3,4)
                if beatInBar == 0 || beatInBar == 1 || beatInBar == 2 || beatInBar == 3 {
                    if positionInBar < beat * 0.1 + Double(beatInBar) * beat { } // ignore, handle by step
                }
                if step % (stepsPerBar / 4) == 0 { v.kickTrigger &+= 1 }

            case .double:
                // 8th-note kick (double time kick, every other step in double, every step in straight)
                if sectionFeel == .double {
                    if step % 2 == 0 { v.kickTrigger &+= 1 }
                    if step % 4 == 1 { v.kick2Trigger &+= 1 }  // ghost second foot
                } else {
                    if step % 2 == 0 { v.kickTrigger &+= 1 }
                }

            case .heavy:
                // Heavy: kick on every beat + big sub on beats 1 and 3 + rapid roll in drop
                if sectionFeel == .double {
                    v.kickTrigger &+= 1  // every tick in drop
                } else {
                    if step % (stepsPerBar / 4) == 0 { v.kickTrigger &+= 1 }
                    // Extra punch on beat 3
                    if beatInBar == 2 && positionInBar < Double(beatInBar) * beat + beat * 0.1 {
                        v.kick2Trigger &+= 1
                    }
                }
            }

            // Snare — backbeats 2 & 4 always; heavier in heavy mode
            if isOnBackbeat {
                v.snareLevel = ks == .heavy ? 1.0 : self.genre.snareLevel * energy
                v.snareTrigger &+= 1
            }
            // Ghost snare in drop
            if sectionFeel == .double && step % 4 == 1 {
                v.ghostSnareLevel = self.genre.snareLevel * 0.28; v.ghostSnareTrigger &+= 1
            }
            // Extra snare hit in heavy drop (on beat 3 offbeat)
            if ks == .heavy && sectionFeel == .double && step % 4 == 2 {
                v.snareLevel = 0.65; v.snareTrigger &+= 1
            }

            // Hat
            v.hatLevel = self.genre.hatLevel * energy
            if sectionFeel == .double || step % 2 == 0 { v.hatTrigger &+= 1 }
            if (sectionFeel == .straight && step == stepsPerBar - 1) ||
               (sectionFeel == .double && step == stepsPerBar - 2) {
                v.openHatTrigger &+= 1
            }

            // Bass
            v.bassFrequency = (step % stepsPerBar > stepsPerBar / 2) ? chord.root * 2 : chord.root
            v.bassTrigger &+= 1

            // Lead arp
            if sectionFeel == .straight || step % 2 == 0 {
                v.arpFrequency = arpFreq; v.arpLevel = energy * 0.55; v.arpTrigger &+= 1
            }

            if crossedBoundary { v.riserTrigger &+= 1; v.impactTrigger &+= 1 }
        }

        clockPlayhead += interval
        if clockPlayhead >= totalDuration { clockPlayhead -= totalDuration }
        if interval != clockInterval {
            clockInterval = interval
            clock?.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        }

        let pPh = clockPlayhead; let pCh = chord.name
        DispatchQueue.main.async { [weak self] in
            guard let self, self.status == .playing else { return }
            self.sectionIndex = index; self.timeFeel = sectionFeel
            self.chordName = pCh; self.barNumber = barIndex + 1; self.playhead = pPh
        }
    }

    private let defaultChord = Chord(name: "Am", root: 110, tones: (220, 261.63, 329.63))
}

private enum MusicSpikeError: Error { case unsupportedFormat }

// MARK: - Voices

private struct Voices {
    var bassFrequency:     Double = 110
    var bassTrigger:       UInt64 = 0
    var kickTrigger:       UInt64 = 0
    var kick2Trigger:      UInt64 = 0   // second foot / ghost kick
    var snareTrigger:      UInt64 = 0
    var snareLevel:        Double = 0.75
    var ghostSnareTrigger: UInt64 = 0
    var ghostSnareLevel:   Double = 0.30
    var hatTrigger:        UInt64 = 0
    var hatLevel:          Double = 0.45
    var openHatTrigger:    UInt64 = 0
    var arpFrequency:      Double = 440
    var arpTrigger:        UInt64 = 0
    var arpLevel:          Double = 0
    var padTone0:          Double = 220
    var padTone1:          Double = 261.63
    var padTone2:          Double = 329.63
    var padLevel:          Double = 0
    var padAttackMs:       Double = 250   // from PadType
    var padLevelMult:      Double = 1.0   // from PadType
    var riserTrigger:      UInt64 = 0
    var impactTrigger:     UInt64 = 0
    var tickSeconds:       Double = 0.6
}

private final class VoiceBox {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var value = Voices()
    init() { lock = .allocate(capacity: 1); lock.initialize(to: os_unfair_lock()) }
    deinit { lock.deinitialize(count: 1); lock.deallocate() }
    func read() -> Voices { os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }; return value }
    func write(_ body: (inout Voices) -> Void) { os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }; body(&value) }
}

// MARK: - Rhythm node

private final class RhythmState {
    // Bass
    var bassPhase = 0.0; var bassFilter = 0.0; var bassEnv = 0.0; var lastBass: UInt64 = 0
    // Kick 1
    var kickPhase = 0.0; var kickEnv = 0.0; var lastKick: UInt64 = 0
    // Kick 2 (second foot / ghost)
    var kick2Phase = 0.0; var kick2Env = 0.0; var lastKick2: UInt64 = 0
    // Snare
    var snareBodyPhase = 0.0; var snareBodyEnv = 0.0; var snareNoiseEnv = 0.0
    var lastSnare: UInt64 = 0; var snareVelocity = 0.75
    // Ghost snare
    var ghostBodyPhase = 0.0; var ghostBodyEnv = 0.0; var ghostNoiseEnv = 0.0
    var lastGhostSnare: UInt64 = 0; var ghostVelocity = 0.30
    // Hats
    var hatEnv = 0.0; var hatFilter = 0.0; var lastHat: UInt64 = 0
    var openHatEnv = 0.0; var lastOpenHat: UInt64 = 0
    // Impact
    var impactPhase = 0.0; var impactEnv = 0.0; var lastImpact: UInt64 = 0
    // Noise
    var noiseSeed: UInt32 = 0x2545_F491
    func noise() -> Double {
        noiseSeed ^= noiseSeed << 13; noiseSeed ^= noiseSeed >> 17; noiseSeed ^= noiseSeed << 5
        return Double(Int32(bitPattern: noiseSeed)) / Double(Int32.max)
    }
}

private extension MusicBedEngine {
    static func makeRhythmNode(sampleRate: Double, voices: VoiceBox, format: AVAudioFormat) -> AVAudioSourceNode {
        let state = RhythmState(); let dt = 1 / sampleRate
        return AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let v = voices.read()
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)

            if v.bassTrigger != state.lastBass       { state.lastBass = v.bassTrigger; state.bassEnv = 1 }
            if v.kickTrigger != state.lastKick        { state.lastKick = v.kickTrigger; state.kickEnv = 1; state.kickPhase = 0 }
            if v.kick2Trigger != state.lastKick2      { state.lastKick2 = v.kick2Trigger; state.kick2Env = 0.65; state.kick2Phase = 0 }
            if v.snareTrigger != state.lastSnare {
                state.lastSnare = v.snareTrigger; state.snareBodyEnv = 1
                state.snareNoiseEnv = 1; state.snareVelocity = v.snareLevel; state.snareBodyPhase = 0
            }
            if v.ghostSnareTrigger != state.lastGhostSnare {
                state.lastGhostSnare = v.ghostSnareTrigger; state.ghostBodyEnv = 1
                state.ghostNoiseEnv = 1; state.ghostVelocity = v.ghostSnareLevel; state.ghostBodyPhase = 0
            }
            if v.hatTrigger != state.lastHat          { state.lastHat = v.hatTrigger; state.hatEnv = 1 }
            if v.openHatTrigger != state.lastOpenHat   { state.lastOpenHat = v.openHatTrigger; state.openHatEnv = 1 }
            if v.impactTrigger != state.lastImpact     { state.lastImpact = v.impactTrigger; state.impactEnv = 1; state.impactPhase = 0 }

            let bassDecay       = exp(-dt / max(0.08, v.tickSeconds * 0.78))
            let kickDecay       = exp(-dt / 0.14)
            let kick2Decay      = exp(-dt / 0.10)   // ghost kick is shorter
            let snareBodyDecay  = exp(-dt / 0.028)
            let snareNoiseDecay = exp(-dt / 0.065)
            let hatDecay        = exp(-dt / 0.032)
            let openHatDecay    = exp(-dt / 0.22)
            let impactDecay     = exp(-dt / 0.50)

            for frame in 0..<Int(frameCount) {
                // Bass
                state.bassPhase += v.bassFrequency * dt; if state.bassPhase >= 1 { state.bassPhase -= 1 }
                let square: Double = state.bassPhase < 0.5 ? 1 : -1
                state.bassFilter += 0.12 * (square - state.bassFilter)
                var sample = state.bassFilter * state.bassEnv * 0.28

                // Kick 1
                let kickHz = 42 + 95 * state.kickEnv * state.kickEnv
                state.kickPhase += kickHz * dt; if state.kickPhase >= 1 { state.kickPhase -= 1 }
                sample += sin(2 * .pi * state.kickPhase) * state.kickEnv * 0.52

                // Kick 2 (ghost / second foot — slightly higher pitch, quieter)
                let kick2Hz = 55 + 80 * state.kick2Env * state.kick2Env
                state.kick2Phase += kick2Hz * dt; if state.kick2Phase >= 1 { state.kick2Phase -= 1 }
                sample += sin(2 * .pi * state.kick2Phase) * state.kick2Env * 0.38

                // Snare body + noise
                state.snareBodyPhase += 185 * dt; if state.snareBodyPhase >= 1 { state.snareBodyPhase -= 1 }
                let snareBody = sin(2 * .pi * state.snareBodyPhase) * state.snareBodyEnv * 0.28
                let snareNoise = state.noise() * state.snareNoiseEnv * state.snareVelocity * 0.32
                sample += snareBody + snareNoise

                // Ghost snare
                state.ghostBodyPhase += 185 * dt; if state.ghostBodyPhase >= 1 { state.ghostBodyPhase -= 1 }
                let ghostBody = sin(2 * .pi * state.ghostBodyPhase) * state.ghostBodyEnv * 0.14
                let ghostNoise = state.noise() * state.ghostNoiseEnv * state.ghostVelocity * 0.18
                sample += ghostBody + ghostNoise

                // Hat
                let white = state.noise()
                state.hatFilter += 0.42 * (white - state.hatFilter)
                sample += (white - state.hatFilter) * state.hatEnv * v.hatLevel * 0.22

                // Open hat
                sample += state.noise() * state.openHatEnv * v.hatLevel * 0.28

                // Impact stinger
                let impHz = 34 + 48 * state.impactEnv
                state.impactPhase += impHz * dt; if state.impactPhase >= 1 { state.impactPhase -= 1 }
                sample += sin(2 * .pi * state.impactPhase) * state.impactEnv * 0.50

                state.bassEnv       *= bassDecay
                state.kickEnv       *= kickDecay
                state.kick2Env      *= kick2Decay
                state.snareBodyEnv  *= snareBodyDecay; state.snareNoiseEnv *= snareNoiseDecay
                state.ghostBodyEnv  *= snareBodyDecay; state.ghostNoiseEnv *= snareNoiseDecay
                state.hatEnv        *= hatDecay; state.openHatEnv *= openHatDecay
                state.impactEnv     *= impactDecay

                let value = Float(tanh(sample))
                for buffer in buffers { UnsafeMutableBufferPointer<Float>(buffer)[frame] = value }
            }
            return noErr
        }
    }
}

// MARK: - Pad + lead node

private final class PadState {
    var phase0=0.0;var phase1=0.0;var phase2=0.0;var phase3=0.0;var phase4=0.0;var phase5=0.0
    var padLevel=0.0; var padAttack=0.0  // coefficient computed once
    var leadPhase0=0.0;var leadPhase1=0.0;var leadEnv=0.0;var leadTargetFreq=440.0;var lastArp:UInt64=0
    var riserPhase=0.0;var riserProgress=1.0;var lastRiser:UInt64=0
}

private func saw(_ phase: inout Double, _ hz: Double, _ dt: Double) -> Double {
    phase += hz * dt; if phase >= 1 { phase -= 1 }; return 2 * phase - 1
}

private extension MusicBedEngine {
    static func makePadNode(
        sampleRate: Double, voices: VoiceBox, format: AVAudioFormat,
        detune: Double, padType: PadType
    ) -> AVAudioSourceNode {
        let state = PadState(); let dt = 1 / sampleRate
        let riserSec = 0.38

        // Pre-compute attack coeff from padType
        let attackSec = padType.attackMs / 1000.0
        let levelCoeff = 1 - exp(-dt / max(0.01, attackSec))

        return AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let v = voices.read()
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)

            if v.riserTrigger != state.lastRiser {
                state.lastRiser = v.riserTrigger; state.riserProgress = 0; state.riserPhase = 0
            }
            if v.arpTrigger != state.lastArp {
                state.lastArp = v.arpTrigger; state.leadTargetFreq = v.arpFrequency
                state.leadEnv = v.arpLevel
            }

            let low = 1 - detune; let high = 1 + detune
            let leadDecay = exp(-dt / max(0.04, v.tickSeconds * 0.60))
            let targetPadLevel = v.padLevel * v.padLevelMult

            for frame in 0..<Int(frameCount) {
                state.padLevel += (targetPadLevel - state.padLevel) * levelCoeff

                var sample = saw(&state.phase0, v.padTone0 * low, dt)
                sample += saw(&state.phase1, v.padTone0 * high, dt)
                sample += saw(&state.phase2, v.padTone1 * low, dt)
                sample += saw(&state.phase3, v.padTone1 * high, dt)
                sample += saw(&state.phase4, v.padTone2 * low, dt)
                sample += saw(&state.phase5, v.padTone2 * high, dt)

                // PadType shapes the timbre:
                // Pluck: extra harmonic rolloff (already in saw, but scale differently)
                // Glass: pure without saw — sine blend (handled by detune≈0 + level)
                sample *= state.padLevel * 0.052

                // Lead arp
                let leadS = (saw(&state.leadPhase0, state.leadTargetFreq, dt) +
                             saw(&state.leadPhase1, state.leadTargetFreq * 1.009, dt)) * 0.5
                sample += leadS * state.leadEnv * 0.10
                state.leadEnv *= leadDecay

                // Riser
                if state.riserProgress < 1 {
                    state.riserProgress = min(1, state.riserProgress + dt / riserSec)
                    let rHz = 350 * pow(4, state.riserProgress)
                    state.riserPhase += rHz * dt; if state.riserPhase >= 1 { state.riserPhase -= 1 }
                    sample += sin(2 * .pi * state.riserPhase) * state.riserProgress * 0.13
                }

                let value = Float(tanh(sample))
                for buffer in buffers { UnsafeMutableBufferPointer<Float>(buffer)[frame] = value }
            }
            return noErr
        }
    }
}
