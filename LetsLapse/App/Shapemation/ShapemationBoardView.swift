import SwiftUI
import CoreGraphics
import LetsLapseKit

// The Sequence board (docs/shapemation/prototype-review.md; the prototype's
// ShapemationSteps.dc.html) — step 4½ of the builder, between Mode and
// Timing under the two frame modes. Every picked photo as it will render:
// a locked preview of the selected one, the strip of all of them with a
// crop badge each, and a side column with the source-and-window card, the
// two charts and the cog. Least crop and Fixed shape are one seat on the
// board: the same thumbnails re-render under the other rule. Code first
// (Steven, 2026-09-20); the SVG mirrors are redrawn after.

struct ShapemationBoardView: View {
    @ObservedObject var builder: ShapemationBuilder
    let family: DetectedShape.Family
    /// Tells the sheet the board is on screen — on the Mac it grows to
    /// `wideSheet` for this step only.
    var onBoard: ((Bool) -> Void)? = nil
    @State private var cogOpen = false
    @State private var keyPickerNine = false
    /// The width the board was given; the two-column form needs `wideFrom`.
    @State private var measuredWidth: CGFloat = 0

    /// The Mac sheet grows to this on the board step only.
    static let wideSheet = CGSize(width: 900, height: 720)
    static let sideWidth = 280.0
    /// Below this the board stacks: preview, strip, then the side cards.
    static let wideFrom = 760.0

    private var wide: Bool { measuredWidth >= Self.wideFrom }

    var body: some View {
        let tiles = builder.boardTiles(for: family)
        let board = builder.board(for: family)
        Group {
            if wide {
                VStack(alignment: .leading, spacing: 10) {
                    header(board: board, tiles: tiles)
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            preview(tiles: tiles)
                            strip(tiles: tiles)
                            Text(stripNote(tiles: tiles)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 12) { sideCards(board: board, tiles: tiles) }
                            }
                            .onAppear { applyBoardHook(proxy) }
                        }
                        .frame(width: Self.sideWidth)
                    }
                    .frame(maxHeight: .infinity)
                }
                .padding(16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            header(board: board, tiles: tiles)
                            preview(tiles: tiles)
                            strip(tiles: tiles)
                            Text(stripNote(tiles: tiles)).font(.system(size: 11)).foregroundStyle(.secondary)
                            sideCards(board: board, tiles: tiles)
                        }
                        .padding(16)
                        .padding(.bottom, 80)
                    }
                    .onAppear { applyBoardHook(proxy) }
                }
            }
        }
        .background(GeometryReader { geo in
            Color.clear.preference(key: BoardWidthKey.self, value: geo.size.width)
        })
        .onPreferenceChange(BoardWidthKey.self) { measuredWidth = $0 }
        .background(LL.screenBackground.ignoresSafeArea())
        .navigationTitle("Sequence board")
        .toolbar {
            if let locked = builder.lockedRecord {
                ToolbarItem(placement: .automatic) {
                    Text("Members locked · \(locked.members?.count ?? 0) photos")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(LL.accent.opacity(0.1), in: Capsule())
                        .foregroundStyle(LL.accentDeep)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                NavigationLink(value: ShapemationBuildStep.timing(family)) {
                    Text("Next · timing")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(LL.accent)
                .disabled(tiles.filter { !$0.rejected }.isEmpty)
            }
            .padding(16)
            .background(.regularMaterial)
        }
        .onAppear {
            onBoard?(true)
            LLog("shapemation: board on screen — \(builder.mode == .frame ? "fixed shape" : "least crop") · \(tiles.filter { !$0.rejected }.count) in the strip · \(board.rejected.count) rejected · rect \(Int(builder.rectSize(for: family).width))×\(Int(builder.rectSize(for: family).height))\(builder.membersLocked ? " · members locked" : "")")
            if builder.boardSelection == nil { builder.boardSelection = tiles.first { !$0.rejected }?.id }
            for p in builder.projects(for: family) { builder.thumbnail(for: p) }
        }
        .onDisappear { onBoard?(false) }
    }

    // MARK: - Header: the option seat, the rect, the toggles, the numbers

    private func header(board: ShapemationLeastCrop.Board, tiles: [ShapemationBuilder.BoardTile]) -> some View {
        let size = builder.rectSize(for: family)
        let optionSeat = Picker("Option", selection: Binding(get: { builder.mode == .frame ? 1 : 0 }, set: { builder.mode = $0 == 1 ? .frame : .leastCrop })) {
            Text("Least crop").tag(0)
            Text("Fixed shape").tag(1)
        }
        .pickerStyle(.segmented).labelsHidden()
        .accessibilityLabel("Option: \(builder.mode == .frame ? "Fixed shape" : "Least crop")")
        let sizeMenu = HStack(spacing: 8) {
            Picker("Size", selection: $builder.frameLongEdge) {
                ForEach(ShapemationFraming.sizePresets, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().tint(.secondary)
            .accessibilityLabel("Size: \(builder.frameLongEdge) long edge")
            Text("\(Int(size.width))×\(Int(size.height))").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
        let autoReject = Toggle(isOn: $builder.leastCrop.autoReject) { Text("Auto-reject").font(.system(size: 13)) }
            .toggleStyle(.switch).tint(LL.levelGood).fixedSize()
            .disabled(builder.mode == .frame || builder.membersLocked)
        let showRejected = Toggle(isOn: $builder.showRejected) { Text("Show rejected").font(.system(size: 13)) }
            .toggleStyle(.switch).tint(LL.levelGood).fixedSize()
            .disabled(builder.mode == .frame)
        let count = Text(countLine(board: board, tiles: tiles)).font(.system(size: 12)).foregroundStyle(.secondary)
        return VStack(alignment: .leading, spacing: 10) {
            if wide {
                HStack(spacing: 14) {
                    optionSeat.frame(maxWidth: 220)
                    ShapemationSortMenu(builder: builder)
                    Spacer(minLength: 0)
                    sizeMenu
                }
                rectChips
                HStack(spacing: 14) {
                    autoReject
                    showRejected
                    count.lineLimit(1)
                    Spacer(minLength: 0)
                    if builder.mode == .leastCrop { numbersPill(board) }
                }
            } else {
                // The phone stacks: one control row at a time, nothing wider than the screen.
                optionSeat
                HStack {
                    ShapemationSortMenu(builder: builder)
                    Spacer(minLength: 0)
                    sizeMenu
                }
                rectChips
                if builder.mode == .leastCrop { numbersPill(board).fixedSize() }
                HStack(spacing: 14) {
                    autoReject
                    Spacer(minLength: 0)
                    showRejected
                }
                count.fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Source first — the picked photos' own aspect — then the presets, each
    /// with the mean loss it would cost this shortlist.
    private var rectChips: some View {
        let chosen = builder.rectRatio
        let source = builder.sourceRatio(for: family)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                chip("Source · \(ShapemationFraming.aspectLabel(ratio: source))", ratio: source, on: chosen == nil) { builder.rectRatio = nil }
                ForEach(ShapemationFraming.aspectPresets) { aspect in
                    chip(aspect.label, ratio: aspect.ratio, on: chosen.map { abs($0 - aspect.ratio) < 0.001 } ?? false) { builder.rectRatio = aspect.ratio }
                }
            }
        }
    }

    private func chip(_ label: String, ratio: Double, on: Bool, select: @escaping () -> Void) -> some View {
        VStack(spacing: 3) {
            Button(action: select) {
                Text(label)
                    .font(.system(size: 13, weight: on ? .semibold : .regular))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(on ? LL.accent : LL.controlFill, in: Capsule())
                    .foregroundStyle(on ? .white : .primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rect \(label)")
            .accessibilityAddTraits(on ? .isSelected : [])
            Text("L \(pct(builder.meanLoss(for: family, ratio: ratio)))")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func numbersPill(_ board: ShapemationLeastCrop.Board) -> some View {
        HStack(spacing: wide ? 12 : 8) {
            number("jump", String(format: "%.2f", board.renderedJump))
            number(wide ? "mean crop" : "crop", pct(board.meanCrop))
            number(wide ? "mean loss" : "loss", pct(board.meanLoss))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(LL.ink, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("jump \(String(format: "%.2f", board.renderedJump)), mean crop \(pct(board.meanCrop)), mean loss \(pct(board.meanLoss))")
    }

    private func number(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(LL.amber).monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func countLine(board: ShapemationLeastCrop.Board, tiles: [ShapemationBuilder.BoardTile]) -> String {
        if builder.mode == .frame {
            let short = tiles.filter { $0.fixedVerdict?.isShort == true }.count
            let up = tiles.filter { $0.fixedVerdict?.isUpscaled == true }.count
            return "\(tiles.count) members · \(short) won't fill the frame · \(up) upscaled past ×2"
        }
        var line = board.countLine
        if board.floorHit { line += " · floor" }
        return line
    }

    // MARK: - The preview and the strip

    private var selectedID: UUID? { builder.boardHover ?? builder.boardSelection }

    private func selectedTile(_ tiles: [ShapemationBuilder.BoardTile]) -> ShapemationBuilder.BoardTile? {
        tiles.first { $0.id == selectedID } ?? tiles.first { !$0.rejected } ?? tiles.first
    }

    private func preview(tiles: [ShapemationBuilder.BoardTile]) -> some View {
        let tile = selectedTile(tiles)
        let ratio = builder.rectRatio(for: family)
        let isKey = tile.map { builder.leastCrop.key(for: $0.id) != nil && !$0.rejected && builder.mode == .leastCrop } ?? false
        return GeometryReader { geo in
            let w = min(geo.size.width, geo.size.height * ratio)
            let h = w / ratio
            ZStack(alignment: .topLeading) {
                Color.black
                if let tile {
                    ShapemationBoardTileImage(tile: tile, image: builder.bigThumbnail(for: tile.id) ?? builder.thumbnails[tile.id], size: CGSize(width: w, height: h), shapeBox: true)
                    if isKey, let target = tile.target {
                        Circle().fill(.white).overlay(Circle().stroke(LL.accent, lineWidth: 2.5))
                            .frame(width: 14, height: 14)
                            .position(x: target.x * w, y: target.y * h)
                            .allowsHitTesting(false)
                    }
                    Text(tile.title).font(.system(size: 12)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(8)
                    badge(tile).padding(8).frame(width: w, alignment: .topTrailing)
                    if isKey {
                        Text("key · drag to place the shape").font(.system(size: 11, weight: .semibold)).foregroundStyle(LL.ink)
                            .padding(.horizontal, 8).padding(.vertical, 2).background(LL.amber, in: Capsule())
                            .padding(8).frame(width: w, height: h, alignment: .bottomLeading)
                    }
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            // The drag places a key; without one the preview must not take
            // the gesture, or the phone's board could not scroll over it.
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard isKey, let tile else { return }
                let x = min(1, max(0, value.location.x / w)), y = min(1, max(0, value.location.y / h))
                builder.setKeyPlace(tile.id, CGPoint(x: x, y: y))
            }, including: isKey ? .all : .subviews)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityLabel("Preview: \(tile?.title ?? "none") \(tile?.badgeLabel ?? "")")
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 220)
        .aspectRatio(max(ratio, 0.75), contentMode: .fit)
        .frame(maxHeight: wide ? 420 : 360)
    }

    /// The strip: on the Mac an AppKit scroller with its bar always shown
    /// and the mouse wheel scrolling it; on iOS the SwiftUI scroll view.
    private func strip(tiles: [ShapemationBuilder.BoardTile]) -> some View {
        Group {
            #if os(macOS)
            MacHorizontalScroller { stripContent(tiles: tiles) }
                .frame(height: 84 + 16)
            #else
            ScrollView(.horizontal, showsIndicators: true) { stripContent(tiles: tiles) }
                .frame(height: 84)
            #endif
        }
        .background(LL.ink, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func stripContent(tiles: [ShapemationBuilder.BoardTile]) -> some View {
        let ratio = builder.rectRatio(for: family)
        let frames = builder.holds(for: family)
        return HStack(spacing: 3) {
            ForEach(Array(tiles.enumerated()), id: \.element.id) { i, tile in
                let hold = Double(frames[tile.id] ?? builder.timing.each.frames(at: builder.timing.fps))
                let w = max(28, min(200, 68 * ratio * hold / Double(builder.timing.fps)))
                stripTile(tile, index: i, size: CGSize(width: w, height: 68))
            }
        }
        .padding(8)
    }

    private func stripTile(_ tile: ShapemationBuilder.BoardTile, index: Int, size: CGSize) -> some View {
        let selected = tile.id == builder.boardSelection
        return ZStack(alignment: .topLeading) {
            ShapemationBoardTileImage(tile: tile, image: builder.thumbnails[tile.id], size: size, shapeBox: true)
                .opacity(tile.rejected ? 0.4 : 1)
            if tile.rejected {
                Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: size.width, y: size.height)); p.move(to: CGPoint(x: size.width, y: 0)); p.addLine(to: CGPoint(x: 0, y: size.height)) }
                    .stroke(LL.levelFar, lineWidth: 2)
            }
            Text(tile.rejected ? "×" : "\(tile.index + 1)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 4).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                .padding(3)
            Circle().fill(tile.badgeColour).overlay(Circle().stroke(.black.opacity(0.5), lineWidth: 1))
                .frame(width: 10, height: 10)
                .padding(4).frame(width: size.width, alignment: .topTrailing)
            if tile.isKey {
                Rectangle().fill(LL.amber).frame(width: 8, height: 8).rotationEffect(.degrees(45))
                    .overlay(Rectangle().stroke(LL.ink, lineWidth: 1).rotationEffect(.degrees(45)))
                    .padding(4).frame(width: size.width, height: size.height, alignment: .bottomLeading)
            }
            if let hold = tile.holdLabel {
                Text(hold).font(.system(size: 9, weight: .semibold)).foregroundStyle(LL.ink)
                    .padding(.horizontal, 4).background(LL.amber, in: RoundedRectangle(cornerRadius: 4))
                    .padding(3).frame(width: size.width, height: size.height, alignment: .bottomTrailing)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(LL.accent, lineWidth: selected ? 2.5 : 0))
        .contentShape(Rectangle())
        .onTapGesture { builder.boardSelection = tile.id }
        #if os(macOS)
        .onHover { inside in builder.boardHover = inside ? tile.id : (builder.boardHover == tile.id ? nil : builder.boardHover) }
        #endif
        .accessibilityLabel("\(tile.rejected ? "Rejected" : "Photo \(tile.index + 1)"), \(tile.title), \(tile.badgeLabel)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func stripNote(tiles: [ShapemationBuilder.BoardTile]) -> String {
        let kept = tiles.filter { !$0.rejected }.count
        let keys = builder.leastCrop.keys.count
        return "\(kept) in the strip · widths follow the hold · tap to select\(wide ? ", hover to peek" : "") · \(keys) key\(keys == 1 ? "" : "s")"
    }

    // MARK: - The side column

    @ViewBuilder
    private func sideCards(board: ShapemationLeastCrop.Board, tiles: [ShapemationBuilder.BoardTile]) -> some View {
        if let tile = selectedTile(tiles) { sourceCard(tile).id("source") }
        if builder.mode == .leastCrop {
            chartsCard(board).id("charts")
            cogCard.id("cog")
        } else {
            fixedCard(tiles: tiles).id("fixed")
        }
    }

    /// `LL_BOARD=charts|cog|fixed` (DEBUG): the side column scrolled to that
    /// card, the cog open — the way a screenshot reaches what sits below the
    /// source card in a 720 pt sheet.
    private func applyBoardHook(_ proxy: ScrollViewProxy) {
        #if DEBUG
        guard let target = ProcessInfo.processInfo.environment["LL_BOARD"] else { return }
        if target == "cog" { cogOpen = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { proxy.scrollTo(target, anchor: .top) }
        #endif
    }

    /// The source, the output window over it, the numbers, and the actions.
    private func sourceCard(_ tile: ShapemationBuilder.BoardTile) -> some View {
        let key = builder.leastCrop.key(for: tile.id)
        let isKey = key != nil && builder.mode == .leastCrop && !tile.rejected
        let kept = builder.leastCrop.keptAnyway.contains(tile.id)
        return VStack(alignment: .leading, spacing: 8) {
            ShapemationSourceWindowView(tile: tile, image: builder.thumbnails[tile.id])
                .frame(maxWidth: .infinity)
            Text("the source; the output window over it is what stays").font(.system(size: 11)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                GridRow { Text("shape").foregroundStyle(.secondary); Text(tile.shareLine) }
                GridRow { Text("natural").foregroundStyle(.secondary); Text(tile.naturalLine) }
                GridRow { Text(tile.metricLabel).foregroundStyle(.secondary); Text(tile.metricLine) }
                if let margins = tile.marginsLine { GridRow { Text("margins").foregroundStyle(.secondary); Text(margins) } }
            }
            .font(.system(size: 12)).monospacedDigit()
            if !builder.membersLocked {
                HStack(spacing: 6) {
                    if builder.mode == .leastCrop {
                        Button(tile.rejected ? (tile.rejectedByHand ? "Undo reject" : "Keep anyway") : (kept ? "Kept anyway · undo" : "Reject")) {
                            if tile.rejected { if tile.rejectedByHand { builder.leastCrop.unreject(tile.id) } else { builder.leastCrop.keepAnyway(tile.id) } }
                            else if kept { builder.leastCrop.unkeep(tile.id) }
                            else { builder.leastCrop.reject(tile.id) }
                        }
                        .buttonStyle(.bordered).tint(tile.rejected ? LL.accent : LL.levelFar).controlSize(.small)
                        Button(isKey ? "Remove key" : "Add key here") {
                            if isKey { builder.leastCrop.removeKey(for: tile.id) }
                            else { builder.leastCrop.setKey(ShapemationLeastCrop.Key(id: tile.id, place: tile.target ?? CGPoint(x: 0.5, y: 0.55))) }
                        }
                        .buttonStyle(.bordered).tint(LL.accent).controlSize(.small)
                        .disabled(tile.rejected)
                    }
                    Picker("Hold", selection: Binding(get: { builder.timing.override(for: tile.id) }, set: { builder.timing.setOverride($0, for: tile.id) })) {
                        Text("Hold · as timed").tag(ShapemationTiming.Hold?.none)
                        ForEach(ShapemationTiming.Hold.options, id: \.self) { Text("Hold \($0.title)").tag(ShapemationTiming.Hold?.some($0)) }
                    }
                    .pickerStyle(.menu).labelsHidden().tint(.secondary).controlSize(.small)
                    .accessibilityLabel("Hold for this photo")
                }
            }
            if isKey, let key {
                Divider()
                HStack {
                    Text(String(format: "Key · place %.2f · %.2f", key.place.x, key.place.y)).font(.system(size: 12))
                    Spacer()
                    Picker("Key picker", selection: $keyPickerNine) {
                        Text("Drag").tag(false)
                        Text("Nine points").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.mini).frame(width: 120)
                }
                if keyPickerNine || !wide {
                    ShapemationFacePlacePicker(aspect: builder.rectSize(for: family), selected: key.place, name: "key") { builder.setKeyPlace(tile.id, $0) }
                }
                HStack {
                    Text("Zoom beyond cover fit").font(.system(size: 12))
                    Spacer()
                    Stepper(String(format: "×%.1f", key.zoom), value: Binding(get: { key.zoom }, set: { builder.setKeyZoom(tile.id, $0) }), in: 1...3, step: 0.1)
                        .font(.system(size: 12)).controlSize(.small)
                }
            }
        }
        .padding(12)
        .llCard(cornerRadius: 18)
    }

    /// The face position chart (the path over the natural places, the keys
    /// as handles) and the size chart (the rendered share, must rise).
    private func chartsCard(_ board: ShapemationLeastCrop.Board) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Shape position").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("path over the natural places · x · y").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ShapemationPositionChart(builder: builder, board: board, selected: selectedID, showEnds: builder.showEndHandles)
                .frame(height: 96)
            HStack {
                Text("Shape share").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("as rendered · should rise").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ShapemationSizeChart(board: board, selected: selectedID, ascending: builder.sort != .largestFirst)
                .frame(height: 76)
            Text(board.sizeBreaks > 0
                 ? "\(board.sizeBreaks) dip\(board.sizeBreaks == 1 ? "" : "s") in the size curve — the crop's zoom, or a hand order, did this"
                 : "rises throughout")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(12)
        .llCard(cornerRadius: 18)
    }

    /// Path and thresholds: the tolerance, the window, the ends, the ease,
    /// the passes, the let-go, the end handles.
    private var cogCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { cogOpen.toggle() } label: {
                HStack {
                    Label("Path and tolerance", systemImage: "gearshape").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(cogSummary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Image(systemName: cogOpen ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Path and tolerance, \(cogOpen ? "open" : "closed")")
            if cogOpen {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tolerance").font(.system(size: 12))
                    Picker("Tolerance", selection: $builder.leastCrop.tolerance) {
                        ForEach(ShapemationLeastCrop.Tolerance.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    Text(builder.leastCrop.tolerance.summary).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Passes").font(.system(size: 12))
                    Picker("Passes", selection: $builder.leastCrop.fixpoint) {
                        Text("One pass").tag(false)
                        Text("To a fixpoint").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Let go as the shape grows").font(.system(size: 12))
                    Picker("Let go", selection: Binding(get: { builder.leastCrop.letGo ?? -1 }, set: { builder.leastCrop.letGo = $0 < 0 ? nil : $0 })) {
                        Text("Auto").tag(-1.0)
                        Text("Off").tag(0.0)
                        Text("½").tag(0.5)
                        Text("1").tag(1.0)
                        Text("2").tag(2.0)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                }
                Divider()
                cogRow("Window") {
                    Picker("Window", selection: $builder.leastCrop.window) {
                        ForEach(ShapemationLeastCrop.Settings.windows, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 110)
                }
                cogRow("The ends") {
                    Picker("Ends", selection: $builder.leastCrop.ends) {
                        ForEach(ShapemationLeastCrop.Settings.Ends.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 150)
                }
                cogRow("Ease between keys") {
                    Picker("Ease", selection: $builder.leastCrop.ease) {
                        ForEach(ShapemationFraming.Ease.allCases, id: \.self) { Text($0 == .linear ? "Linear" : "In-out").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 150)
                }
                cogRow("End handles") {
                    Picker("End handles", selection: $builder.showEndHandles) {
                        Text("Shown").tag(true)
                        Text("Hidden").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 110)
                }
            }
        }
        .padding(12)
        .llCard(cornerRadius: 18)
    }

    private var cogSummary: String {
        let s = builder.leastCrop
        let letGo = s.letGo.map { $0 == 0 ? "no let-go" : String(format: "let go %g", $0) } ?? "let go auto"
        return "\(s.tolerance.title.lowercased()) · window \(s.window) · \(s.ends.title.lowercased()) · \(s.fixpoint ? "fixpoint" : "one pass") · \(letGo)"
    }

    private func cogRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            content()
        }
    }

    /// The Fixed shape seat: the shipped Output-frame keys — size and place
    /// at the first and the last photo, the ease — and the tally.
    private func fixedCard(tiles: [ShapemationBuilder.BoardTile]) -> some View {
        let startPct = Int((builder.startKey.size * 100).rounded()), endPct = Int((builder.endKey.size * 100).rounded())
        let size = builder.rectSize(for: family)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Shape size").font(.system(size: 14, weight: .semibold))
            Stepper("Start \(startPct) % of the height", value: Binding(get: { startPct }, set: { builder.setStartSize(Double($0) / 100) }),
                    in: ShapemationBuilder.faceSizeRange, step: ShapemationBuilder.faceSizeStep).font(.system(size: 13))
            Stepper("End \(endPct) %" + (builder.endSizeFollowsStart ? " · Same" : ""), value: Binding(get: { endPct }, set: { builder.setEndSize(Double($0) / 100) }),
                    in: ShapemationBuilder.faceSizeRange, step: ShapemationBuilder.faceSizeStep).font(.system(size: 13))
            Text("Shape place").font(.system(size: 14, weight: .semibold))
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 6) {
                    ShapemationFacePlacePicker(aspect: size, selected: builder.startKey.face, name: "start") { builder.setStartFace($0) }
                    Text("Start").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                VStack(spacing: 6) {
                    ShapemationFacePlacePicker(aspect: size, selected: builder.endKey.face, name: "end") { builder.setEndFace($0) }
                    Text(builder.endPlaceFollowsStart ? "End · Same" : "End").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Text("Ease").font(.system(size: 14, weight: .semibold))
            Picker("Ease", selection: Binding(get: { builder.framing.ease }, set: { builder.setEase($0) })) {
                ForEach(ShapemationFraming.Ease.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(builder.feasibilitySummary(for: family)).font(.system(size: 12)).foregroundStyle(LL.accentDeep).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .llCard(cornerRadius: 18)
    }

    // MARK: - Bits

    private func badge(_ tile: ShapemationBuilder.BoardTile) -> some View {
        Text(tile.badgeLabel)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tile.badgeColour)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(.black.opacity(0.6), in: Capsule())
            .lineLimit(1)
    }

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }
}

private struct BoardWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - The tiles' pictures

/// One photo as it will render: under least crop its output window, clipped
/// and scaled to the tile; under Fixed shape the photo placed in the frame.
/// The shape's box in amber over it.
struct ShapemationBoardTileImage: View {
    let tile: ShapemationBuilder.BoardTile
    let image: CGImage?
    let size: CGSize
    let shapeBox: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let image {
                let placed = tile.placedRect   // where the whole photo lies, unit coordinates of the tile
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: placed.width * size.width, height: placed.height * size.height)
                    .offset(x: placed.minX * size.width, y: placed.minY * size.height)
            }
            if shapeBox {
                let b = tile.shapeRectInTile
                Rectangle().stroke(LL.amber, lineWidth: 1.5)
                    .frame(width: max(2, b.width * size.width), height: max(2, b.height * size.height))
                    .offset(x: b.minX * size.width, y: b.minY * size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

/// The source with the output window bright over it and the rest dimmed;
/// the window's edge in white, the shape in amber.
struct ShapemationSourceWindowView: View {
    let tile: ShapemationBuilder.BoardTile
    let image: CGImage?

    var body: some View {
        GeometryReader { geo in
            let a = tile.frame.width / max(tile.frame.height, 1)
            let w = min(geo.size.width, geo.size.height * a), h = w / a
            ZStack(alignment: .topLeading) {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1).resizable().frame(width: w, height: h)
                    Color.black.opacity(0.45).frame(width: w, height: h)
                    let win = tile.sourceWindow
                    Image(decorative: image, scale: 1).resizable().frame(width: w, height: h)
                        .mask(Rectangle().frame(width: win.width * w, height: win.height * h).offset(x: win.minX * w, y: win.minY * h).frame(width: w, height: h, alignment: .topLeading))
                    Rectangle().stroke(.white, lineWidth: 1.5)
                        .frame(width: win.width * w, height: win.height * h)
                        .offset(x: win.minX * w, y: win.minY * h)
                }
                let s = tile.shapeRectInSource
                Rectangle().stroke(LL.amber, lineWidth: 1.5)
                    .frame(width: max(2, s.width * w), height: max(2, s.height * h))
                    .offset(x: s.minX * w, y: s.minY * h)
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(maxWidth: .infinity)
        }
        .aspectRatio(tile.frame.width / max(tile.frame.height, 1), contentMode: .fit)
    }
}

// MARK: - The charts

/// The path `P` over the natural places, x on the accent and y on the deep
/// accent, the selected photo as a playhead, the keys and (when shown) the
/// ends as handles a drag moves.
struct ShapemationPositionChart: View {
    @ObservedObject var builder: ShapemationBuilder
    let board: ShapemationLeastCrop.Board
    let selected: UUID?
    let showEnds: Bool

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let n = board.rows.count
            let X: (Int) -> CGFloat = { i in n > 1 ? 8 + CGFloat(i) * (W - 16) / CGFloat(n - 1) : W / 2 }
            let Y: (Double) -> CGFloat = { v in 8 + CGFloat(v) * (H - 16) }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).fill(LL.controlFill.opacity(0.6))
                Canvas { ctx, _ in
                    var mid = Path(); mid.move(to: CGPoint(x: 8, y: H / 2)); mid.addLine(to: CGPoint(x: W - 8, y: H / 2))
                    ctx.stroke(mid, with: .color(.black.opacity(0.08)))
                    for (i, r) in board.rows.enumerated() {
                        let p = r.evaluation.natural.place
                        ctx.fill(Path(ellipseIn: CGRect(x: X(i) - 2.2, y: Y(p.y) - 2.2, width: 4.4, height: 4.4)), with: .color(LL.accentDeep.opacity(0.45)))
                        ctx.fill(Path(ellipseIn: CGRect(x: X(i) - 2.2, y: Y(p.x) - 2.2, width: 4.4, height: 4.4)), with: .color(LL.accent.opacity(0.45)))
                    }
                    var px = Path(), py = Path()
                    for (i, p) in board.path.enumerated() {
                        if i == 0 { px.move(to: CGPoint(x: X(i), y: Y(p.x))); py.move(to: CGPoint(x: X(i), y: Y(p.y))) }
                        else { px.addLine(to: CGPoint(x: X(i), y: Y(p.x))); py.addLine(to: CGPoint(x: X(i), y: Y(p.y))) }
                    }
                    ctx.stroke(px, with: .color(LL.accent), lineWidth: 2)
                    ctx.stroke(py, with: .color(LL.accentDeep), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    if let selected, let i = board.rows.firstIndex(where: { $0.id == selected }) {
                        var head = Path(); head.move(to: CGPoint(x: X(i), y: 8)); head.addLine(to: CGPoint(x: X(i), y: H - 8))
                        ctx.stroke(head, with: .color(LL.ink.opacity(0.5)), lineWidth: 1)
                    }
                }
                ForEach(handleIndices(n: n), id: \.self) { i in
                    let row = board.rows[i]
                    handle(row: row, x: X(i), y: Y(Double(row.path.x)), axis: \.x, colour: LL.accent, radius: 6, H: H)
                    handle(row: row, x: X(i), y: Y(Double(row.path.y)), axis: \.y, colour: LL.accentDeep, radius: 5, H: H)
                }
            }
        }
        .accessibilityLabel("Shape position chart")
    }

    private func handleIndices(n: Int) -> [Int] {
        var set = Set<Int>()
        for k in builder.leastCrop.keys { if let i = board.rows.firstIndex(where: { $0.id == k.id }) { set.insert(i) } }
        if showEnds, n > 0 { set.insert(0); set.insert(n - 1) }
        return set.sorted()
    }

    private func handle(row: ShapemationLeastCrop.Row, x: CGFloat, y: CGFloat, axis: WritableKeyPath<CGPoint, CGFloat>, colour: Color, radius: CGFloat, H: CGFloat) -> some View {
        Circle().fill(.white).overlay(Circle().stroke(colour, lineWidth: 2))
            .frame(width: radius * 2, height: radius * 2)
            .position(x: x, y: y)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                builder.boardSelection = row.id
                let v = min(1, max(0, Double((value.location.y - 8) / max(H - 16, 1))))
                var place = builder.leastCrop.key(for: row.id)?.place ?? row.path
                place[keyPath: axis] = v
                builder.setKeyPlace(row.id, place)
            })
            .accessibilityLabel("Key handle \(axis == \.x ? "x" : "y") for \(row.index + 1)")
    }
}

/// The rendered share along the sequence, the cover-fit share faint under it;
/// a dip against the sort's direction is a red dot.
struct ShapemationSizeChart: View {
    let board: ShapemationLeastCrop.Board
    let selected: UUID?
    let ascending: Bool

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let n = board.rows.count
            let maxS = max(0.05, board.rows.map(\.evaluation.renderedShare).max() ?? 0.05)
            let X: (Int) -> CGFloat = { i in n > 1 ? 8 + CGFloat(i) * (W - 16) / CGFloat(n - 1) : W / 2 }
            let Y: (Double) -> CGFloat = { v in H - 8 - CGFloat(v / maxS) * (H - 16) }
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(LL.controlFill.opacity(0.6))
                Canvas { ctx, _ in
                    var nat = Path(), ren = Path()
                    for (i, r) in board.rows.enumerated() {
                        let s = r.evaluation.renderedShare / max(r.evaluation.zoom, 1e-9)
                        if i == 0 { nat.move(to: CGPoint(x: X(i), y: Y(s))); ren.move(to: CGPoint(x: X(i), y: Y(r.evaluation.renderedShare))) }
                        else { nat.addLine(to: CGPoint(x: X(i), y: Y(s))); ren.addLine(to: CGPoint(x: X(i), y: Y(r.evaluation.renderedShare))) }
                    }
                    ctx.stroke(nat, with: .color(LL.accent.opacity(0.35)), lineWidth: 1)
                    ctx.stroke(ren, with: .color(LL.ink), lineWidth: 1.5)
                    for (i, r) in board.rows.enumerated() {
                        let dip = i > 0 && ((r.evaluation.renderedShare - board.rows[i - 1].evaluation.renderedShare) * (ascending ? 1 : -1)) < -0.002
                        ctx.fill(Path(ellipseIn: CGRect(x: X(i) - 2.6, y: Y(r.evaluation.renderedShare) - 2.6, width: 5.2, height: 5.2)), with: .color(dip ? LL.levelFar : LL.ink))
                    }
                    if let selected, let i = board.rows.firstIndex(where: { $0.id == selected }) {
                        var head = Path(); head.move(to: CGPoint(x: X(i), y: 8)); head.addLine(to: CGPoint(x: X(i), y: H - 8))
                        ctx.stroke(head, with: .color(LL.ink.opacity(0.5)), lineWidth: 1)
                    }
                }
            }
        }
        .accessibilityLabel("Shape share chart")
    }
}
