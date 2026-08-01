import SwiftUI
import AVFoundation
import os

// MARK: - View

/// Music tab — experimental soundtrack that builds like a real track.
///
/// Layers accumulate across 7 arrangement stages. Two arpeggiators are the
/// foundation: a chunky bass arp with per-step velocity + rests, and a lead arp
/// that moves across the chosen mode's scale with gaps and melodic shape.
/// Eight scale modes (including harmonic minor, Locrian, Phrygian) give very
/// different moods; chord qualities (aug, dim, half-dim7, dom7) arise naturally
/// from the mode's diatonic harmony.
struct MusicView: View {
    @StateObject private var engine = MusicBedEngine()
    @State private var midiExportURL: URL?
    @State private var showingMIDIShare = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header

                LLSectionHeader("Arrangement")
                stageCard.padding(.bottom, 12)

                LLSectionHeader("Bed")
                bedCard.padding(.bottom, 12)

                LLSectionHeader("Playback")
                playbackCard

                Text("Experimental. Arrangement cycles ~6 min; each stage adds one element.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)

                Spacer(minLength: 96)
            }
            .padding(.horizontal, 16)
        }
        .background(LL.screenBackground)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingMIDIShare) {
            if let url = midiExportURL {
                ShareSheet(activityItems: [url]).ignoresSafeArea()
            }
        }
        #endif
        .onDisappear { engine.stop() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Music")
                .font(.system(size: 34, weight: .bold))
            Text("Experimental")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LL.amber)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4).padding(.top, 8).padding(.bottom, 6)
    }

    // MARK: Stage card

    private var stageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(engine.stage.label)
                        .font(.system(size: 17, weight: .bold))
                    Text(engine.stage.layerDescription)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if engine.isPlaying {
                    Text("Bar \(engine.barNumber)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LL.accent)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(LL.accent.opacity(0.12), in: Capsule())
                }
            }

            HStack(spacing: 3) {
                ForEach(ArrangementStage.allCases) { s in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(s == engine.stage ? LL.amber :
                              s < engine.stage  ? LL.ink.opacity(0.35) : LL.ink.opacity(0.12))
                        .frame(height: 6)
                }
            }

            HStack(spacing: 6) {
                pill("Kick",   on: true)
                pill("Hats",   on: engine.stage.hasHats)
                pill("Crash",  on: engine.stage.hasCrash)
                pill("Snare",  on: engine.stage.hasSnare)
                pill("2× kick", on: engine.stage == .doubleKick)
            }

            // Start with picker
            VStack(alignment: .leading, spacing: 6) {
                Text("Start with")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(StartLayer.allCases) { layer in
                        Button {
                            engine.startLayer = layer
                        } label: {
                            Text(layer.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(layer == engine.startLayer ? .white : .primary)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(layer == engine.startLayer ? LL.ink : LL.ink.opacity(0.08),
                                            in: Capsule())
                                .contentShape(Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }

            VStack(spacing: 6) {
                arpBar("Bass arp", level: engine.arp1Volume / 0.5, color: LL.accent,
                       pattern: engine.bassPatternName)
                arpBar("Lead arp", level: engine.arp2Volume / 0.7, color: LL.amber,
                       pattern: engine.upperPatternName)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .llCard()
    }

    @ViewBuilder private func pill(_ label: String, on: Bool) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(on ? Color.white : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(on ? LL.ink : LL.ink.opacity(0.1), in: Capsule())
    }

    @ViewBuilder
    private func arpBar(_ label: String, level: Double, color: Color, pattern: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(pattern)
                    .font(.system(size: 9)).foregroundStyle(.secondary.opacity(0.7))
            }
            .frame(width: 72, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(LL.ink.opacity(0.12))
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, level))))
                        .animation(.easeOut(duration: 0.5), value: level)
                }
            }
            .frame(height: 6)
            Text("\(Int(max(0, min(1, level)) * 100))%")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }

    // MARK: Bed card

    private var bedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Genre
            HStack(spacing: 8) {
                ForEach(MusicBedEngine.Genre.allCases) { g in
                    Button { engine.select(genre: g) } label: {
                        Text(g.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(g == engine.genre ? .white : .primary)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(g == engine.genre ? LL.ink : LL.screenBackground, in: Capsule())
                            .contentShape(Capsule())
                    }.buttonStyle(.plain)
                }
                Spacer()
            }

            // Mode picker — all 8 modes in a scrollable row
            VStack(alignment: .leading, spacing: 6) {
                Text("Mode")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ScaleMode.allCases) { m in
                            Button { engine.select(mode: m) } label: {
                                VStack(spacing: 1) {
                                    Text(m.label)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(m.flavour)
                                        .font(.system(size: 9))
                                }
                                .foregroundStyle(m == engine.mode ? .white : .primary)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(m == engine.mode ? LL.accent : LL.screenBackground,
                                            in: RoundedRectangle(cornerRadius: 20))
                                .contentShape(RoundedRectangle(cornerRadius: 20))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }

            Button("Generate") { engine.generateBed() }
                .buttonStyle(LLPrimaryButtonStyle())

            Text(engine.bedSummary)
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .llCard()
    }

    // MARK: Playback card

    private var playbackCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(engine.isPlaying ? "Stop" : "Play") { engine.togglePlayback() }
                .buttonStyle(LLPrimaryButtonStyle(tint: engine.isPlaying ? LL.accentDeep : LL.accent))
            LevelMeter(level: engine.level).frame(height: 10)
            if engine.hasMIDIData {
                Button("Export MIDI") {
                    midiExportURL = engine.exportMIDI()
                    if midiExportURL != nil { showingMIDIShare = true }
                }
                .buttonStyle(LLPrimaryButtonStyle(tint: LL.amber))
            }

            // Tempo control
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    tempoModeButton("Auto",   mode: .auto)
                    tempoModeButton("Custom", mode: .manual)
                }
                .background(LL.ink.opacity(0.08), in: Capsule())
                .frame(height: 32)

                if engine.tempoMode == .manual {
                    HStack(spacing: 10) {
                        Slider(value: Binding(
                            get: { engine.manualBPM },
                            set: { engine.setManualBPM($0) }
                        ), in: 60...200, step: 1)
                        Text("\(Int(engine.manualBPM)) BPM")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LL.accent)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .llCard()
    }

    @ViewBuilder
    private func tempoModeButton(_ label: String, mode: MusicBedEngine.TempoMode) -> some View {
        Button {
            engine.setTempoMode(mode)
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(engine.tempoMode == mode ? .white : .primary)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(engine.tempoMode == mode ? LL.ink : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain)
    }
}

// MARK: - Share sheet (iOS)

#if os(iOS)
private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
#endif

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

// MARK: - Scale modes

/// Eight modes covering dark, bright, and unusual harmonic colours.
/// Each mode defines its scale degrees and the characteristic chord progressions
/// that bring out its sound — including augmented (harmonic minor III),
/// diminished (Locrian root, Phrygian), half-dim7 (Locrian), and dominant7
/// (harmonic minor V) chord qualities.
enum ScaleMode: String, CaseIterable, Identifiable {
    case aeolian      // Natural minor — dark, emotive
    case dorian       // Minor + raised 6th — groove, soulful
    case phrygian     // Minor + flat 2nd — flamenco, mysterious
    case harmonicMin  // Minor + raised 7th — dramatic, tense
    case locrian      // Diminished root — most dissonant, eerie
    case ionian       // Major — bright, resolved
    case lydian       // Major + raised 4th — dreamy, floating
    case mixolydian   // Major + flat 7th — bluesy, driving

    var id: String { rawValue }

    var label: String {
        switch self {
        case .aeolian:     return "Aeolian"
        case .dorian:      return "Dorian"
        case .phrygian:    return "Phrygian"
        case .harmonicMin: return "Harm. Min"
        case .locrian:     return "Locrian"
        case .ionian:      return "Major"
        case .lydian:      return "Lydian"
        case .mixolydian:  return "Mixolydian"
        }
    }

    var flavour: String {
        switch self {
        case .aeolian:     return "dark"
        case .dorian:      return "groove"
        case .phrygian:    return "tense"
        case .harmonicMin: return "dramatic"
        case .locrian:     return "eerie"
        case .ionian:      return "bright"
        case .lydian:      return "dreamy"
        case .mixolydian:  return "bluesy"
        }
    }

    /// Semitone offsets for each of the 7 scale degrees.
    var degrees: [Int] {
        switch self {
        case .aeolian:     return [0, 2, 3, 5, 7, 8, 10]
        case .dorian:      return [0, 2, 3, 5, 7, 9, 10]
        case .phrygian:    return [0, 1, 3, 5, 7, 8, 10]
        case .harmonicMin: return [0, 2, 3, 5, 7, 8, 11]
        case .locrian:     return [0, 1, 3, 5, 6, 8, 10]
        case .ionian:      return [0, 2, 4, 5, 7, 9, 11]
        case .lydian:      return [0, 2, 4, 6, 7, 9, 11]
        case .mixolydian:  return [0, 2, 4, 5, 7, 9, 10]
        }
    }

    /// Four characteristic progressions for this mode.
    /// Each is an array of (semitone offset from root, chord quality).
    var progressions: [[(semitones: Int, quality: ChordQuality, roman: String)]] {
        switch self {
        case .aeolian: return [
            [(0,.minor,"i"),(8,.major,"VI"),(3,.major,"III"),(10,.major,"VII")],
            [(0,.minor,"i"),(5,.minor,"iv"),(10,.major,"VII"),(8,.major,"VI")],
            [(0,.minor,"i"),(7,.minor,"v"),(8,.major,"VI"),(10,.major,"VII")],
            [(0,.minor,"i"),(5,.minor,"iv"),(0,.minor,"i"),(7,.minor,"v")],
        ]
        case .dorian: return [
            [(0,.minor,"i"),(5,.major,"IV"),(0,.minor,"i"),(5,.major,"IV")],
            [(0,.minor,"i"),(2,.major,"II"),(10,.minor,"VII"),(0,.minor,"i")],
            [(0,.minor,"i"),(5,.major,"IV"),(10,.minor,"VII"),(0,.minor,"i")],
            [(0,.minor,"i"),(9,.minor,"vi"),(5,.major,"IV"),(2,.major,"II")],
        ]
        case .phrygian: return [
            [(0,.minor,"i"),(1,.major,"bII"),(0,.minor,"i"),(1,.major,"bII")],
            [(0,.minor,"i"),(10,.minor,"bVII"),(8,.major,"bVI"),(1,.major,"bII")],
            [(1,.major,"bII"),(0,.minor,"i"),(8,.major,"bVI"),(0,.minor,"i")],
            [(0,.minor,"i"),(8,.major,"bVI"),(10,.minor,"bVII"),(1,.major,"bII")],
        ]
        case .harmonicMin: return [
            [(0,.minor,"i"),(7,.dominant7,"V7"),(0,.minor,"i"),(7,.dominant7,"V7")],
            [(0,.minor,"i"),(5,.minor,"iv"),(7,.dominant7,"V7"),(0,.minor,"i")],
            [(0,.minor,"i"),(3,.augmented,"III+"),(5,.minor,"iv"),(7,.dominant7,"V7")],
            [(0,.minor,"i"),(8,.major,"VI"),(5,.minor,"iv"),(7,.dominant7,"V7")],
        ]
        case .locrian: return [
            [(0,.diminished,"i°"),(10,.minor,"bVII"),(8,.major,"bVI"),(10,.minor,"bVII")],
            [(1,.major,"bII"),(0,.diminished,"i°"),(10,.minor,"bVII"),(1,.major,"bII")],
            [(0,.halfDim7,"iø7"),(8,.major,"bVI"),(10,.minor,"bVII"),(1,.major,"bII")],
            [(0,.diminished,"i°"),(8,.major,"bVI"),(1,.major,"bII"),(10,.minor,"bVII")],
        ]
        case .ionian: return [
            [(0,.major,"I"),(7,.major,"V"),(9,.minor,"vi"),(5,.major,"IV")],
            [(0,.major,"I"),(5,.major,"IV"),(7,.major,"V"),(0,.major,"I")],
            [(0,.major,"I"),(9,.minor,"vi"),(5,.major,"IV"),(7,.major,"V")],
            [(2,.minor,"ii"),(7,.major,"V"),(0,.major,"I"),(5,.major,"IV")],
        ]
        case .lydian: return [
            [(0,.major,"I"),(2,.major,"II"),(0,.major,"I"),(7,.major,"V")],
            [(0,.major,"I"),(2,.major,"II"),(11,.minor,"vii"),(0,.major,"I")],
            [(0,.major,"I"),(9,.minor,"vi"),(2,.major,"II"),(7,.major,"V")],
            [(0,.major,"I"),(2,.major,"II"),(5,.diminished,"#iv°"),(0,.major,"I")],
        ]
        case .mixolydian: return [
            [(0,.major,"I"),(10,.major,"bVII"),(5,.major,"IV"),(0,.major,"I")],
            [(0,.major,"I"),(5,.major,"IV"),(10,.major,"bVII"),(0,.major,"I")],
            [(0,.major,"I"),(7,.minor,"v"),(5,.major,"IV"),(10,.major,"bVII")],
            [(0,.major,"I"),(10,.major,"bVII"),(0,.major,"I"),(5,.major,"IV")],
        ]
        }
    }
}

// MARK: - Chord quality

enum ChordQuality {
    case major, minor, diminished, augmented, halfDim7, dominant7

    /// Semitone offsets for the chord tones: [root, 3rd, 5th, (7th)].
    var intervals: [Int] {
        switch self {
        case .major:      return [0, 4, 7]
        case .minor:      return [0, 3, 7]
        case .diminished: return [0, 3, 6]
        case .augmented:  return [0, 4, 8]
        case .halfDim7:   return [0, 3, 6, 10]
        case .dominant7:  return [0, 4, 7, 10]
        }
    }

    var symbol: String {
        switch self {
        case .major: return ""; case .minor: return "m"; case .diminished: return "°"
        case .augmented: return "+"; case .halfDim7: return "ø7"; case .dominant7: return "7"
        }
    }

    /// Hz for chord tone at index (0=root, 1=3rd, 2=5th, 3=7th/oct, 4=oct-root, 5=oct-5th).
    func hz(root: Double, toneIndex: Int) -> Double {
        let semi: Int
        switch toneIndex {
        case 0: semi = 0
        case 1: semi = intervals[1]
        case 2: semi = intervals[2]
        case 3: semi = intervals.count > 3 ? intervals[3] : 12
        case 4: semi = 12
        case 5: semi = 12 + intervals[2]
        default: semi = 0
        }
        return root * pow(2.0, Double(semi) / 12.0)
    }
}

// MARK: - Arp patterns

/// One step in an arp pattern. `toneIndex` is nil for a rest.
/// For the bass arp, toneIndex maps to ChordQuality.hz(root:toneIndex:).
/// For the upper arp, toneIndex maps to a scale degree (0–13, next-octave aware).
private struct ArpStep {
    let toneIndex: Int?     // nil = rest
    let velocity: Double    // 0.0–1.0 per-note dynamics

    static func t(_ tone: Int, _ vel: Double) -> ArpStep { ArpStep(toneIndex: tone, velocity: vel) }
    static var r: ArpStep { ArpStep(toneIndex: nil, velocity: 0) }
}

/// Library of bass arp patterns. Tone indices: 0=root 1=3rd 2=5th 3=7th/oct 4=oct-root 5=oct-5th.
private let bassArpLibrary: [[ArpStep]] = [
    // 1. Power pulse — root, 5th, octave, rest
    [.t(0,1.0), .t(2,0.72), .t(4,0.88), .r],
    // 2. Syncopated echo — root, ghost root, 5th, rest
    [.t(0,1.0), .t(0,0.38), .t(2,0.82), .r],
    // 3. Sparse backbone — root, rest, rest, octave
    [.t(0,1.0), .r,          .r,          .t(4,0.78)],
    // 4. Rolling thirds — root, 3rd, 5th, 3rd (colorful)
    [.t(0,0.90), .t(1,0.55), .t(2,0.75), .t(1,0.42)],
    // 5. Punch and pause — root accent, ghost, rest, 5th
    [.t(0,1.0), .t(0,0.40), .r,          .t(2,0.88)],
    // 6. Ascending climb — root, rest, 5th, octave
    [.t(0,1.0), .r,          .t(2,0.78), .t(4,0.95)],
    // 7. Fall back — octave, 5th, rest, root
    [.t(4,0.88), .t(2,0.70), .r,          .t(0,0.85)],
    // 8. Wide spread with 7th colour (only audible on 7th-quality chords)
    [.t(0,1.0), .t(2,0.60), .t(3,0.70), .r],
]

/// Library of upper arp patterns. Tone indices are scale degree (0–13 = two octaves).
private let upperArpLibrary: [[ArpStep]] = [
    // 1. Up with breath — gaps on beats
    [.r,          .t(0,0.88), .r,          .t(2,0.65), .t(4,0.82), .r,          .t(6,0.92), .r],
    // 2. Cascade down — high to low with gaps
    [.t(6,0.95), .r,          .t(4,0.65), .r,          .t(2,0.80), .t(1,0.52), .r,          .t(0,0.75)],
    // 3. Thirds dance — interval skips
    [.t(0,0.90), .t(2,0.52), .r,          .t(4,0.82), .t(2,0.45), .r,          .t(5,0.88), .r],
    // 4. High reach — sparse, top of phrase
    [.r,          .t(4,0.90), .r,          .t(7,1.00), .r,          .t(5,0.68), .r,          .t(2,0.60)],
    // 5. Modal climb — fills the bar
    [.t(0,1.0), .t(2,0.60), .t(4,0.75), .r,          .t(5,0.82), .r,          .t(7,0.95), .t(4,0.50)],
    // 6. Very sparse — just three notes
    [.t(0,0.88), .r,          .r,          .t(4,0.92), .r,          .r,          .t(7,1.00), .r],
    // 7. Modal wander — not root-centric
    [.t(2,0.75), .t(4,0.55), .t(6,0.82), .r,          .t(5,0.70), .t(4,0.45), .t(2,0.65), .r],
    // 8. Float — offbeat entries, airy
    [.r,          .t(0,0.90), .t(2,0.65), .r,          .t(4,0.85), .r,          .t(6,0.78), .t(4,0.52)],
]

private let bassPatternNames = [
    "power pulse", "syncopated", "sparse", "rolling thirds",
    "punch+pause", "climb", "fall back", "wide spread"
]
private let upperPatternNames = [
    "up+breath", "cascade", "thirds", "high reach",
    "modal climb", "sparse", "wander", "float"
]

// MARK: - Arrangement stage

enum ArrangementStage: Int, CaseIterable, Identifiable, Comparable {
    case countIn, hats, openCrash, snare, doubleKick, peak, rampDown
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    var id: Int { rawValue }

    static func from(bar: Int) -> ArrangementStage {
        switch bar {
        case 0..<4:  return .countIn
        case 4..<8:  return .hats
        case 8..<12: return .openCrash
        case 12..<16:return .snare
        case 16..<20:return .doubleKick
        case 20..<24:return .peak
        default:     return .rampDown
        }
    }

    var label: String {
        switch self {
        case .countIn:    return "Count-in"
        case .hats:       return "Hats in"
        case .openCrash:  return "Open + Crash"
        case .snare:      return "Snare"
        case .doubleKick: return "Double kicks"
        case .peak:       return "Full drop"
        case .rampDown:   return "Wind-down"
        }
    }

    var layerDescription: String {
        switch self {
        case .countIn:    return "Kick · Bass arp fading in"
        case .hats:       return "Kick + Closed hats · Bass at 50%"
        case .openCrash:  return "Kick + Hats + Open on 4 + Crash"
        case .snare:      return "Full kit · Lead arp entering"
        case .doubleKick: return "8th-note kicks · Both arps building"
        case .peak:       return "Everything at full level"
        case .rampDown:   return "Half-time kick · Open hats · Quieter snare"
        }
    }

    var hasHats: Bool  { self >= .hats }
    var hasCrash: Bool { self >= .openCrash && self < .rampDown }
    var hasSnare: Bool { self >= .snare }
    var hasUpperArp: Bool { self >= .snare }
}

// MARK: - Start layer

enum StartLayer: String, CaseIterable, Identifiable {
    case drums, bass, lead, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .drums: return "Drums"
        case .bass:  return "Bass"
        case .lead:  return "Lead"
        case .all:   return "All"
        }
    }
    /// Virtual bar offset — skips build-up stages so the chosen layer is present from bar 1
    var barOffset: Int {
        switch self {
        case .drums: return 0    // current behaviour: drums-first build-up
        case .bass:  return 4    // hats stage → bass is audible immediately
        case .lead:  return 12   // snare stage → lead arp enters immediately
        case .all:   return 20   // peak stage → everything at once
        }
    }
}

// MARK: - Voice bus

private struct Voices {
    var kickTrigger:   UInt64 = 0
    var snareTrigger:  UInt64 = 0;  var snareVelocity: Double = 1.0
    var hatTrigger:    UInt64 = 0;  var hatOpen: Bool = false
    var crashTrigger:  UInt64 = 0
    // Arp 1 (bass) — per-note velocity drives both amplitude and filter sweep
    var arp1Trigger:   UInt64 = 0;  var arp1Frequency: Double = 55
    var arp1Volume:    Double = 0;  var arp1Velocity:  Double = 1.0
    // Arp 2 (lead)
    var arp2Trigger:   UInt64 = 0;  var arp2Frequency: Double = 220
    var arp2Volume:    Double = 0;  var arp2Velocity:  Double = 1.0
    var tickSeconds:   Double = 0.25
}

private final class VoiceBox {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var value = Voices()
    init() { lock = .allocate(capacity: 1); lock.initialize(to: os_unfair_lock()) }
    deinit { lock.deinitialize(count: 1); lock.deallocate() }
    func read() -> Voices { os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }; return value }
    func write(_ body: (inout Voices) -> Void) { os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }; body(&value) }
}

// MARK: - Engine

private final class MusicBedEngine: ObservableObject {

    // MARK: Sub-types

    enum Genre: String, CaseIterable, Identifiable {
        case synthwave, dubstep, electronic
        var id: String { rawValue }
        var title: String { switch self { case .synthwave: "Synthwave"; case .dubstep: "Dubstep"; case .electronic: "Electronic" } }
        var baseBPM: Double { switch self { case .synthwave: 100; case .dubstep: 140; case .electronic: 124 } }
    }

    private struct Chord {
        let root: Double;  let quality: ChordQuality;  let name: String
    }

    // MARK: Published state

    @Published private(set) var isPlaying           = false
    @Published private(set) var level: Double        = 0
    @Published private(set) var stage: ArrangementStage = .countIn
    @Published private(set) var barNumber: Int       = 1
    @Published private(set) var genre: Genre         = .synthwave
    @Published private(set) var mode: ScaleMode      = .aeolian
    @Published private(set) var bedSummary           = "Generate to start"
    @Published private(set) var arp1Volume: Double   = 0
    @Published private(set) var arp2Volume: Double   = 0
    @Published private(set) var bassPatternName: String = "–"
    @Published private(set) var upperPatternName: String = "–"
    // Arrangement start
    @Published var startLayer: StartLayer = .drums
    // Tempo
    enum TempoMode { case auto, manual }
    @Published var tempoMode: TempoMode  = .auto
    @Published var manualBPM: Double     = 120

    // MARK: Audio graph

    private let audioEngine  = AVAudioEngine()
    private let drumMixer    = AVAudioMixerNode()    // fans kick + snare + hat into one bus
    private let drumReverb   = AVAudioUnitReverb()
    private let bassReverb   = AVAudioUnitReverb()
    private let bassDelay    = AVAudioUnitDelay()
    private let upperReverb  = AVAudioUnitReverb()
    private let crashReverb  = AVAudioUnitReverb()   // plate reverb for cymbal
    private let voices       = VoiceBox()
    // Drum sample players (one per voice, share drumReverb bus)
    private var kickPlayer:  AVAudioPlayerNode?
    private var snarePlayer: AVAudioPlayerNode?
    private var hatPlayer:   AVAudioPlayerNode?   // single node; .interrupts chokes hat
    private var crashPlayer: AVAudioPlayerNode?
    // Sampler instruments (replace AVAudioSourceNode synths)
    private let bassSampler  = AVAudioUnitSampler()
    private let upperSampler = AVAudioUnitSampler()
    private var bassCurrentNote:  UInt8 = 255  // 255 = none
    private var upperCurrentNote: UInt8 = 255
    private var graphBuilt   = false
    // Pre-loaded sample buffers
    private var kickBuf:   AVAudioPCMBuffer?
    private var snareBuf:  AVAudioPCMBuffer?
    private var hatClBuf:  AVAudioPCMBuffer?
    private var hatOpBuf:  AVAudioPCMBuffer?
    private var crashBuf:  AVAudioPCMBuffer?

    // MARK: Clock state (all on clockQueue)

    private let clockQueue = DispatchQueue(label: "com.regularsteven.letslapse.music.clock",
                                           qos: .userInitiated)
    private var clock: DispatchSourceTimer?
    private var globalStep       = 0
    private var clockBPM: Double = 100
    private var clockProg:  [Chord]    = []
    private var clockMode:  ScaleMode  = .aeolian
    private var clockBassPattern  = 0
    private var clockUpperPattern = 0
    private var clockStartOffset  = 0   // bar offset from StartLayer (clock queue only)
    private var humanSeed: UInt32  = 0x8F3A_1C7D   // humanisation PRNG (clock queue only)

    // MARK: MIDI recording (written on clockQueue; read from main after stop)
    private struct MidiEvent {
        let step: Int; let ch: UInt8; let note: UInt8; let vel: UInt8; let on: Bool
    }
    private var midiLog: [MidiEvent] = []
    private var currentTickStep = 0   // set at tick() start so drum helpers can log
    @Published private(set) var hasMIDIData = false

    private var currentProg:  [Chord]   = []
    private var currentBPM:   Double    = 100

    private static let rootFrequencies: [Double] = [
        65.41, 69.30, 73.42, 77.78, 82.41, 87.31,
        92.50, 98.00, 103.83, 110.00, 116.54, 123.47
    ]
    private static let noteNames = ["C","C#","D","Eb","E","F","F#","G","Ab","A","Bb","B"]

    deinit { clock?.cancel(); if audioEngine.isRunning { audioEngine.stop() } }

    // MARK: Controls

    func select(genre g: Genre) { guard g != genre else { return }; genre = g; generateBed() }
    func select(mode m: ScaleMode) { guard m != mode else { return }; mode = m; generateBed() }

    func generateBed() {
        let wasPlaying = isPlaying
        if wasPlaying { stop() }   // properly tear down before rebuilding
        midiLog.removeAll(); hasMIDIData = false
        let seed = UInt64(arc4random()) ^ (UInt64(arc4random()) << 32)

        // Pick root, progression, BPM variation
        let rIdx     = Int(seed % 12)
        let progIdx  = Int((seed / 100) % UInt64(mode.progressions.count))
        let bpmDelta = Double(seed % 18) - 9
        let bassIdx  = Int((seed / 1000) % UInt64(bassArpLibrary.count))
        let upperIdx = Int((seed / 10000) % UInt64(upperArpLibrary.count))

        let rootHz   = Self.rootFrequencies[rIdx]
        let rootName = Self.noteNames[rIdx]
        let prog     = mode.progressions[progIdx]

        let chords = prog.map { step -> Chord in
            let chordRoot = rootHz * pow(2.0, Double(step.semitones) / 12.0)
            return Chord(root: chordRoot, quality: step.quality,
                         name: "\(rootName)\(step.quality.symbol)")
        }

        currentProg = chords
        currentBPM  = tempoMode == .manual ? manualBPM : genre.baseBPM + bpmDelta
        bassDelay.delayTime = (60.0 / currentBPM) * 0.75

        let progName = prog.map(\.roman).joined(separator: "–")
        let tempoLabel = tempoMode == .manual ? "\(Int(manualBPM)) BPM (manual)" : "\(Int(currentBPM)) BPM"
        bedSummary = "\(genre.title) · \(mode.label) · \(tempoLabel) · \(progName)"
        bassPatternName  = bassPatternNames[bassIdx]
        upperPatternName = upperPatternNames[upperIdx]

        teardownGraph()
        resetClock()
        stage = .countIn; barNumber = 1; arp1Volume = 0; arp2Volume = 0; level = 0

        let bp = bassIdx; let up = upperIdx; let cm = mode; let so = startLayer.barOffset
        clockQueue.async { [weak self] in
            self?.clockBassPattern  = bp
            self?.clockUpperPattern = up
            self?.clockMode         = cm
            self?.clockStartOffset  = so
        }

        if wasPlaying { start() }
    }

    func setTempoMode(_ mode: TempoMode) {
        tempoMode = mode
        if isPlaying { generateBed() }
    }

    func setManualBPM(_ bpm: Double) {
        manualBPM = max(60, min(200, bpm))
        if tempoMode == .manual {
            currentBPM = manualBPM
            bassDelay.delayTime = (60.0 / currentBPM) * 0.75
            if isPlaying { startClock() }   // restart timer at new interval
        }
    }

    // MARK: Transport

    func togglePlayback() { isPlaying ? stop() : start() }

    func start() {
        guard !isPlaying else { return }
        if currentProg.isEmpty { generateBed(); return }
        configureSession(active: true)
        do { try buildGraphIfNeeded(); try audioEngine.start() }
        catch { configureSession(active: false); return }
        // Start player nodes AFTER engine is running (required on every start, not just first build)
        [kickPlayer, snarePlayer, hatPlayer, crashPlayer].compactMap { $0 }.forEach { $0.play() }
        isPlaying = true; startClock()
    }

    func stop() {
        guard isPlaying else { return }
        stopClock()
        bassSampler.sendMIDIEvent(0xB0, data1: 123, data2: 0)   // all notes off
        upperSampler.sendMIDIEvent(0xB0, data1: 123, data2: 0)
        clockQueue.sync { bassCurrentNote = 255; upperCurrentNote = 255 }
        if audioEngine.isRunning { audioEngine.stop() }
        voices.write { $0 = Voices() }
        configureSession(active: false)
        isPlaying = false; level = 0
        hasMIDIData = !midiLog.isEmpty
    }

    private func configureSession(active: Bool) {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        if active {
            try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? s.setActive(true)
        } else {
            try? s.setActive(false, options: .notifyOthersOnDeactivation)
            PlaybackAudioSession.configureAmbient()
        }
        #endif
    }

    // MARK: Graph

    private func loadBuffer(_ name: String) -> AVAudioPCMBuffer? {
        guard let url  = Bundle.main.url(forResource: name, withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url),
              let buf  = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                          frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }
        try? file.read(into: buf)
        return buf
    }

    private func buildGraphIfNeeded() throws {
        guard !graphBuilt else { return }
        let outRate = audioEngine.outputNode.outputFormat(forBus: 0).sampleRate
        let sr = outRate > 0 ? outRate : 44_100
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else {
            throw MusicError.unsupportedFormat
        }

        // Load sample buffers
        kickBuf  = loadBuffer("ll_kick")
        snareBuf = loadBuffer("ll_snare")
        hatClBuf = loadBuffer("ll_hat_closed")
        hatOpBuf = loadBuffer("ll_hat_open")
        crashBuf = loadBuffer("ll_crash")

        // Create drum player nodes
        let kp = AVAudioPlayerNode(); let sp = AVAudioPlayerNode()
        let hp = AVAudioPlayerNode(); let cp = AVAudioPlayerNode()

        drumReverb.loadFactoryPreset(.mediumRoom);  drumReverb.wetDryMix  = 18
        bassReverb.loadFactoryPreset(.mediumHall);  bassReverb.wetDryMix  = 28
        upperReverb.loadFactoryPreset(.mediumHall); upperReverb.wetDryMix = 35
        crashReverb.loadFactoryPreset(.plate);      crashReverb.wetDryMix = 55
        bassDelay.delayTime     = (60.0 / currentBPM) * 0.75
        bassDelay.feedback      = 22
        bassDelay.wetDryMix     = 22
        bassDelay.lowPassCutoff = 5500

        for n in [kp, sp, hp, cp,
                  bassSampler, upperSampler,
                  drumMixer, drumReverb, bassReverb, bassDelay, upperReverb, crashReverb] as [AVAudioNode] {
            audioEngine.attach(n)
        }

        // Load SF2 instruments
        if let sf2URL = Bundle.main.url(forResource: "ll_instruments", withExtension: "sf2") {
            do {
                try bassSampler.loadSoundBankInstrument(at: sf2URL, program: 0,
                    bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: 0)
                try upperSampler.loadSoundBankInstrument(at: sf2URL, program: 1,
                    bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: 0)
            } catch {
                print("⚠️ SF2 load error: \(error)")
            }
        } else {
            print("⚠️ ll_instruments.sf2 not found in bundle")
        }

        let mx = audioEngine.mainMixerNode
        // Drum players → drum mixer → drum reverb → main mixer
        audioEngine.connect(kp, to: drumMixer, fromBus: 0, toBus: 0, format: fmt)
        audioEngine.connect(sp, to: drumMixer, fromBus: 0, toBus: 1, format: fmt)
        audioEngine.connect(hp, to: drumMixer, fromBus: 0, toBus: 2, format: fmt)
        audioEngine.connect(drumMixer,   to: drumReverb,  format: fmt)
        audioEngine.connect(drumReverb,  to: mx,          format: fmt)
        // Crash player → plate reverb → mixer
        audioEngine.connect(cp,          to: crashReverb, format: fmt)
        audioEngine.connect(crashReverb, to: mx,          format: fmt)
        // Sampler instruments → reverb → delay → mixer
        audioEngine.connect(bassSampler,  to: bassReverb,  format: nil)
        audioEngine.connect(bassReverb,   to: bassDelay,   format: nil)
        audioEngine.connect(bassDelay,    to: mx,          format: nil)
        audioEngine.connect(upperSampler, to: upperReverb, format: nil)
        audioEngine.connect(upperReverb,  to: mx,          format: nil)
        mx.outputVolume = 0.88

        mx.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            guard let ch = buf.floatChannelData?[0] else { return }
            var peak: Float = 0
            for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(ch[i])) }
            let r = Double(min(1, peak * 1.4))
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isPlaying else { return }
                self.level = r > self.level ? r : self.level * 0.72 + r * 0.28
            }
        }

        kickPlayer  = kp; snarePlayer = sp; hatPlayer = hp; crashPlayer = cp
        graphBuilt = true; audioEngine.prepare()
    }

    private func teardownGraph() {
        stopClock(); if audioEngine.isRunning { audioEngine.stop() }
        guard graphBuilt else { return }
        audioEngine.mainMixerNode.removeTap(onBus: 0)
        bassSampler.sendMIDIEvent(0xB0, data1: 123, data2: 0)   // all notes off
        upperSampler.sendMIDIEvent(0xB0, data1: 123, data2: 0)
        for n in [kickPlayer, snarePlayer, hatPlayer, crashPlayer].compactMap({ $0 as AVAudioNode? }) {
            audioEngine.detach(n)
        }
        for n in [bassSampler, upperSampler,
                  drumMixer, drumReverb, bassReverb, bassDelay, upperReverb, crashReverb] as [AVAudioNode] {
            audioEngine.detach(n)
        }
        kickPlayer = nil; snarePlayer = nil; hatPlayer = nil; crashPlayer = nil
        bassCurrentNote = 255; upperCurrentNote = 255
        graphBuilt = false
        voices.write { $0 = Voices() }
    }

    // MARK: Sample playback helpers (called from clockQueue)

    private func playKick(velocity: Float = 1.0) {
        guard let p = kickPlayer, let b = kickBuf else { return }
        p.volume = velocity * 0.92
        p.scheduleBuffer(b, at: nil, options: .interrupts)
        let v = UInt8(min(127, Int(velocity * 100)))
        midiLog.append(MidiEvent(step: currentTickStep,     ch: 9, note: 36, vel: v, on: true))
        midiLog.append(MidiEvent(step: currentTickStep + 2, ch: 9, note: 36, vel: 0, on: false))
    }

    private func playSnare(velocity: Float = 1.0) {
        guard let p = snarePlayer, let b = snareBuf else { return }
        p.volume = velocity * 0.85
        p.scheduleBuffer(b, at: nil, options: .interrupts)
        let v = UInt8(min(127, Int(velocity * 127)))
        midiLog.append(MidiEvent(step: currentTickStep,     ch: 9, note: 38, vel: v, on: true))
        midiLog.append(MidiEvent(step: currentTickStep + 2, ch: 9, note: 38, vel: 0, on: false))
    }

    private func playHat(open: Bool) {
        guard let p = hatPlayer else { return }
        let b = open ? hatOpBuf : hatClBuf
        guard let b = b else { return }
        p.volume = open ? 0.72 : 0.80
        // .interrupts automatically chokes the previous hat hit (open cuts closed and vice-versa)
        p.scheduleBuffer(b, at: nil, options: .interrupts)
        let note: UInt8 = open ? 46 : 42
        midiLog.append(MidiEvent(step: currentTickStep,     ch: 9, note: note, vel: 90, on: true))
        midiLog.append(MidiEvent(step: currentTickStep + 2, ch: 9, note: note, vel: 0,  on: false))
    }

    private func playCrash() {
        guard let p = crashPlayer, let b = crashBuf else { return }
        p.volume = 0.78
        p.scheduleBuffer(b, at: nil, options: .interrupts)
        midiLog.append(MidiEvent(step: currentTickStep,      ch: 9, note: 49, vel: 100, on: true))
        midiLog.append(MidiEvent(step: currentTickStep + 16, ch: 9, note: 49, vel: 0,   on: false))
    }

    // MARK: Clock

    private func startClock() {
        let bpm = currentBPM; let prog = currentProg; let m = mode; let so = startLayer.barOffset
        clockQueue.async { [weak self] in
            guard let self else { return }
            self.clockBPM = bpm; self.clockProg = prog; self.clockMode = m
            self.clockStartOffset = so
            self.clock?.cancel()
            let interval = (60.0 / bpm) / 2.0   // 8th-note tick
            let t = DispatchSource.makeTimerSource(queue: self.clockQueue)
            t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.tick() }
            self.clock = t; t.resume()
        }
    }

    private func stopClock() { clockQueue.async { self.clock?.cancel(); self.clock = nil } }
    private func resetClock() { clockQueue.async { self.globalStep = 0 } }

    // MARK: Humanisation PRNG (called only from clockQueue)

    private func humanRand() -> Double {
        humanSeed ^= humanSeed << 13
        humanSeed ^= humanSeed >> 17
        humanSeed ^= humanSeed << 5
        return Double(Int32(bitPattern: humanSeed)) / Double(Int32.max)
    }

    // MARK: Tick (every 8th note, on clockQueue)

    private func tick() {
        guard !clockProg.isEmpty else { return }

        let step          = globalStep
        currentTickStep   = step   // used by drum helpers for MIDI logging
        let stepInBar     = step % 8
        let effectiveStep = step + clockStartOffset * 8   // virtual position in arrangement
        let barIdx        = effectiveStep / 8
        let stage         = ArrangementStage.from(bar: barIdx)
        let interval      = (60.0 / clockBPM) / 2.0

        // Chord changes every 2 bars
        let chord = clockProg[(barIdx / 2) % clockProg.count]

        // Arp volumes (ramp from effective position so "All" starts at full)
        let arp1Vol = min(0.5, Double(effectiveStep) * (0.5 / 16.0))
        let arp2Vol: Double = stage.hasUpperArp
            ? min(0.7, Double(max(0, barIdx - 12) * 8 + stepInBar) * (0.7 / 32.0))
            : 0

        // --- Phrase shape: 4-bar unit with dynamic arch (Beethoven: establish→rise→peak→release) ---
        let phraseBar = barIdx % 4       // 0 establish · 1 rise · 2 peak · 3 release
        let breathBar = barIdx % 8 == 7  // every 8 bars: ultra-sparse to reset tension
        let velArch   = [0.78, 0.90, 1.0, 0.60][phraseBar]   // dynamic envelope over phrase

        // --- Bass arp step (quarter-note rate: fires on even steps) ---
        var bassStepTrigger = false
        var bassFreq = 55.0
        var bassVel  = 1.0
        if stepInBar % 2 == 0 {
            let patStep = (step / 2) % bassArpLibrary[clockBassPattern].count
            let s       = bassArpLibrary[clockBassPattern][patStep]
            // Release bar: only root on beat 1 — silence creates anticipation for re-entry
            // Breath bar: one root note on beat 1 only, nothing else
            let suppress = (phraseBar == 3 && patStep != 0) || (breathBar && stepInBar != 0)
            if !suppress, let ti = s.toneIndex, s.velocity > 0 {
                bassFreq = chord.quality.hz(root: chord.root, toneIndex: breathBar ? 0 : ti)
                bassVel  = s.velocity
                bassStepTrigger = true
            }
        }

        // --- Upper arp step (8th-note rate) ---
        var upperStepTrigger = false
        var upperFreq = 220.0
        var upperVel  = 1.0
        if stage.hasUpperArp {
            let patStep = step % upperArpLibrary[clockUpperPattern].count
            let s       = upperArpLibrary[clockUpperPattern][patStep]
            // Call/response: bass owns the downbeat — upper yields beat 1 of every bar
            // Breath bar: upper completely silent (tension before re-entry)
            // Release bar: upper only speaks in second half (gentle setup, not full statement)
            let suppress = breathBar
                || stepInBar == 0
                || (phraseBar == 3 && stepInBar < 4)
            // Melodic contour: sequence up the scale on bars 2→3 (rise → peak)
            let degreeOffset = phraseBar == 1 ? 1 : phraseBar == 2 ? 2 : 0
            if !suppress, let di = s.toneIndex, s.velocity > 0 {
                let shiftedDi = di + degreeOffset
                let deg = clockMode.degrees[shiftedDi % 7] + (shiftedDi / 7) * 12
                upperFreq = chord.root * 2.0 * pow(2.0, Double(deg) / 12.0)
                upperVel  = s.velocity
                upperStepTrigger = true
            }
        }

        // --- Humanisation: phrase velocity arch + ±8 % scatter; drop one snare per 8 bars ---
        let huBass  = max(0.08, min(1, bassVel  * velArch + humanRand() * 0.16 - 0.08))
        let huUpper = max(0.08, min(1, upperVel * velArch + humanRand() * 0.16 - 0.08))
        let dropSnare = barIdx % 8 == 7 && stepInBar == 2   // subtle ghost measure

        // --- Drums: trigger sample players directly from clock queue ---
        var kickFired = false

        // KICK
        switch stage {
        case .countIn, .hats, .openCrash, .snare, .peak:
            if stepInBar % 2 == 0 { playKick(); kickFired = true }
        case .doubleKick:
            playKick(); kickFired = true
        case .rampDown:
            if stepInBar == 0 || stepInBar == 4 { playKick(); kickFired = true }
        }

        // HATS
        if stage.hasHats {
            if stage == .rampDown {
                if stepInBar == 2 || stepInBar == 6 { playHat(open: true) }
            } else {
                playHat(open: stepInBar == 6)
            }
        }

        // CRASH: beat 1 of every 4th bar
        if stage.hasCrash && stepInBar == 0 && barIdx % 4 == 0 {
            playCrash()
        }

        // SNARE
        if stage.hasSnare && !dropSnare {
            if stage == .rampDown {
                if stepInBar == 4 { playSnare(velocity: 0.52) }
            } else {
                if stepInBar == 2 || stepInBar == 6 {
                    playSnare(velocity: stage == .doubleKick ? 0.88 : 1.0)
                }
                if stage == .doubleKick && stepInBar == 5 {
                    playSnare(velocity: 0.32)
                }
            }
        }

        // --- Bass sampler ---
        if bassStepTrigger {
            let note = UInt8(clamping: Int(round(69 + 12 * log2(bassFreq / 440.0))))
            let arrangeVol = Float(min(1.0, arp1Vol / 0.5))
            let vel  = UInt8(max(1, Int(Float(huBass) * arrangeVol * 100)))
            if bassCurrentNote != 255 {
                bassSampler.stopNote(bassCurrentNote, onChannel: 0)
                midiLog.append(MidiEvent(step: step, ch: 0, note: bassCurrentNote, vel: 0, on: false))
            }
            bassSampler.startNote(note, withVelocity: vel, onChannel: 0)
            midiLog.append(MidiEvent(step: step, ch: 0, note: note, vel: vel, on: true))
            bassCurrentNote = note
        }

        // --- Lead/pad sampler ---
        if upperStepTrigger {
            let note = UInt8(clamping: Int(round(69 + 12 * log2(upperFreq / 440.0))))
            let arrangeVol = Float(min(1.0, arp2Vol / 0.7))
            let vel  = UInt8(max(1, Int(Float(huUpper) * arrangeVol * 100)))
            if upperCurrentNote != 255 {
                upperSampler.stopNote(upperCurrentNote, onChannel: 0)
                midiLog.append(MidiEvent(step: step, ch: 1, note: upperCurrentNote, vel: 0, on: false))
            }
            upperSampler.startNote(note, withVelocity: vel, onChannel: 0)
            midiLog.append(MidiEvent(step: step, ch: 1, note: note, vel: vel, on: true))
            upperCurrentNote = note
        }

        globalStep += 1

        let uiStage = stage; let uiBar = effectiveStep / 8 + 1; let v1 = arp1Vol; let v2 = arp2Vol
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPlaying else { return }
            self.stage = uiStage; self.barNumber = uiBar
            self.arp1Volume = v1; self.arp2Volume = v2
        }
    }
}

// MARK: - MIDI Export

extension MusicBedEngine {
    /// Write the recorded session to a standard MIDI file and return its URL.
    /// Returns nil if nothing has been recorded yet.
    func exportMIDI() -> URL? {
        guard !midiLog.isEmpty else { return nil }

        let tpqn: UInt16 = 480         // ticks per quarter note
        let stepTicks    = Int(tpqn) / 2   // eighth note = 240 ticks
        let bpm          = currentBPM

        // Sort: earlier steps first; at the same step, note-offs before note-ons
        let sorted = midiLog.sorted {
            $0.step < $1.step || ($0.step == $1.step && !$0.on && $1.on)
        }

        var track = Data()

        // Tempo meta event (µs per beat)
        let uspb = UInt32(60_000_000.0 / bpm)
        track += midiVLQ(0)
        track += Data([0xFF, 0x51, 0x03,
                       UInt8((uspb >> 16) & 0xFF),
                       UInt8((uspb >>  8) & 0xFF),
                       UInt8( uspb        & 0xFF)])

        // Note events
        var cursor = 0
        for e in sorted {
            let absTick = e.step * stepTicks
            track += midiVLQ(absTick - cursor)
            cursor = absTick
            let status: UInt8 = (e.on ? 0x90 : 0x80) | e.ch
            track += Data([status, e.note, e.vel])
        }

        // End of track
        track += Data([0x00, 0xFF, 0x2F, 0x00])

        // Assemble RIFF-style MIDI file
        var file = Data()
        file += Data("MThd".utf8)
        file += midiBE32(6)
        file += midiBE16(0)       // format 0 (single track)
        file += midiBE16(1)       // 1 track
        file += midiBE16(tpqn)
        file += Data("MTrk".utf8)
        file += midiBE32(UInt32(track.count))
        file += track

        let name = "letslapse_\(Int(Date().timeIntervalSince1970)).mid"
        let url  = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? file.write(to: url)
        return url
    }

    private func midiVLQ(_ value: Int) -> Data {
        var v = value
        var bytes = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 { bytes.insert(UInt8((v & 0x7F) | 0x80), at: 0); v >>= 7 }
        return Data(bytes)
    }
    private func midiBE16(_ v: UInt16) -> Data {
        Data([UInt8(v >> 8), UInt8(v & 0xFF)])
    }
    private func midiBE32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
}

private enum MusicError: Error { case unsupportedFormat }

// MARK: - Drum synthesis removed in v8.2 — replaced by AVAudioPlayerNode + WAV samples
// See DrumSamples/ folder: ll_kick.wav, ll_snare.wav, ll_hat_closed.wav, ll_hat_open.wav, ll_crash.wav

// MARK: - Bass/Lead synthesis removed in v8.3 — replaced by AVAudioUnitSampler + ll_instruments.sf2
