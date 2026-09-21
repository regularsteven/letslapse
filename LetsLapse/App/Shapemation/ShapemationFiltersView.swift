import SwiftUI
import CoreGraphics
import LetsLapseKit

// Step 1: Apply filters — the prototype's shortlist screen (docs/shapemation/
// prototype/ShapemationSteps.dc.html, review §5a; Steven, 2026-09-21: the
// Gallery's full-row tags waste this wider sheet — draw them as the tag
// editor's chips, `docs/design/components/tag-suggestions.default.svg`,
// sorted by volume). The tags as wrapping chips, the applied ones in accent
// above with an ✕ and Clear tags; an aspect filter and the 3×3 position
// filter with a count in every cell; the count line and a contact sheet of
// the survivors, each with its shape box and its cover-fit window into the
// set's own aspect. Optional: with nothing set the count is the whole
// library and Next still goes on. Code first; the SVG mirrors are owed.

struct ShapemationFiltersView: View {
    @ObservedObject var builder: ShapemationBuilder
    @State private var measuredWidth: CGFloat = 0

    /// Two filter cards side by side from here; stacked below — the 560 pt
    /// sheet stacks them, the position grid needs the width.
    static let twoColumnsFrom = 700.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Narrow the photos before choosing the shape — the way the Gallery's Tags rows do.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SceneSearchField(text: $builder.queryText, placeholder: "Search titles and tags")
                tagsCard
                if measuredWidth >= Self.twoColumnsFrom {
                    HStack(alignment: .top, spacing: 12) {
                        aspectCard.frame(maxWidth: .infinity)
                        positionCard.frame(maxWidth: .infinity)
                    }
                } else {
                    aspectCard
                    positionCard
                }
                Text(countLine)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                if builder.shortlistCount == 0 {
                    Text("Nothing matches these filters. Clear a tag, widen the aspect or the position.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(16)
                        .llCard(cornerRadius: 12)
                } else {
                    contactSheet
                }
            }
            .padding(16)
            .padding(.bottom, 80)
        }
        .background(GeometryReader { geo in Color.clear.preference(key: FiltersWidthKey.self, value: geo.size.width) })
        .onPreferenceChange(FiltersWidthKey.self) { measuredWidth = $0 }
        .background(LL.screenBackground.ignoresSafeArea())
        .navigationTitle("Apply filters")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                NavigationLink(value: ShapemationBuildStep.family) {
                    Text("Next · shape")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(LL.accent)
                .disabled(builder.shortlistCount == 0)
            }
            .padding(16)
            .background(.regularMaterial)
        }
    }

    private var countLine: String {
        let n = builder.shortlistCount
        return "\(n) photo project\(n == 1 ? "" : "s")"
    }

    // MARK: - Tags as chips

    /// The applied chips in accent with their count and an ✕, Clear tags
    /// trailing; then every other tag present, largest volume first, each
    /// with "n of N" once a filter narrows the set.
    private var tagsCard: some View {
        let chips = builder.tagChipRows()
        return VStack(alignment: .leading, spacing: 9) {
            if !chips.applied.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    LLSectionHeader("Applied")
                    Spacer()
                    Button("Clear tags") { builder.tagSelection = [] }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LL.accent)
                }
                ShapemationFlowLayout(spacing: 8) {
                    ForEach(chips.applied, id: \.tag) { chip in
                        Button { builder.tagSelection.remove(chip.tag) } label: {
                            HStack(spacing: 8) {
                                Text(chip.label).font(.system(size: 14, weight: .semibold))
                                Text(chip.count).font(.system(size: 14)).opacity(0.8)
                                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).opacity(0.8)
                            }
                            .foregroundStyle(.white)
                            .padding(.leading, 12).padding(.trailing, 10)
                            .frame(height: 33)
                            .background(LL.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(chip.label), \(chip.count), applied")
                    }
                }
                .padding(.bottom, 5)
            }
            LLSectionHeader("Tags")
            if chips.others.isEmpty && chips.applied.isEmpty {
                Text(builder.tagSelection.isEmpty
                     ? "No tags on these photos yet — Auto rename & tag in the Gallery adds them. Search still narrows."
                     : "No photo carries every lit tag with these words.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            } else if chips.others.isEmpty {
                Text("Every other tag would empty the set.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                ShapemationFlowLayout(spacing: 8) {
                    ForEach(chips.others, id: \.tag) { chip in
                        Button { builder.tagSelection.insert(chip.tag) } label: {
                            HStack(spacing: 7) {
                                Text(chip.label).font(.system(size: 14)).foregroundStyle(.primary.opacity(0.75))
                                Text(chip.count).font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 33)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(chip.label), \(chip.count)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .llCard(cornerRadius: 18)
    }

    // MARK: - Aspect and position

    private var aspectCard: some View {
        let counts = builder.aspectCounts()
        return VStack(alignment: .leading, spacing: 10) {
            LLSectionHeader("Aspect")
            Picker("Aspect", selection: $builder.aspectFilter) {
                ForEach(ShapemationBuilder.AspectFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityLabel("Aspect: \(builder.aspectFilter.title)")
            Text("\(counts.landscape) landscape · \(counts.portrait) portrait · \(counts.square) square — a mixed-orientation set pays cover-fit crop on every photo of the minority.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .llCard(cornerRadius: 18)
    }

    /// A column or a cell keeps the photos whose shape's centre lies in it
    /// — a shortlist for the eye, never a classifier (review Q5).
    private var positionCard: some View {
        let counts = builder.cellCounts()
        let columns = ["Left", "Centre", "Right"]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                LLSectionHeader("Position")
                Spacer()
                Text("where the shape's centre lies").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    ForEach(0..<3, id: \.self) { c in
                        let on = builder.cellFilter == .column(c)
                        let n = counts[c] + counts[c + 3] + counts[c + 6]
                        Button { builder.cellFilter = on ? nil : .column(c) } label: {
                            HStack(spacing: 5) {
                                Text(columns[c]).font(.system(size: 12, weight: .medium))
                                Text("\(n)").font(.system(size: 12)).opacity(0.6)
                            }
                            .frame(maxWidth: .infinity).frame(height: 24)
                            .background(on ? LL.accent : LL.controlFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .foregroundStyle(on ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(columns[c]) column, \(n)")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                ForEach(0..<3, id: \.self) { r in
                    GridRow {
                        ForEach(0..<3, id: \.self) { c in
                            let cell = r * 3 + c
                            let on = builder.cellFilter == .cell(cell)
                            let inColumn = builder.cellFilter == .column(c)
                            Button { builder.cellFilter = on ? nil : .cell(cell) } label: {
                                Text("\(counts[cell])")
                                    .font(.system(size: 11))
                                    .frame(maxWidth: .infinity).frame(height: 22)
                                    .background(on ? LL.accent : (inColumn ? LL.accent.opacity(0.18) : LL.controlFill.opacity(0.6)),
                                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                    .foregroundStyle(on ? .white : .secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(["top", "middle", "bottom"][r]) \(columns[c].lowercased()) cell, \(counts[cell])")
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .llCard(cornerRadius: 18)
    }

    // MARK: - The contact sheet

    /// Every survivor at 84 pt: its shape's box in amber and, dimmed, what a
    /// cover fit into the set's own aspect would already take.
    private var contactSheet: some View {
        let ratio = builder.sourceRatioOfShortlist()
        let projects = builder.admittedProjects
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 84), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(projects) { project in
                ShapemationContactTile(project: project, image: builder.thumbnails[project.id], ratio: ratio)
                    .onAppear { builder.thumbnail(for: project) }
            }
        }
    }
}

private struct FiltersWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One survivor: the picture fit in a square tile over black, the largest
/// shape's box in amber, everything outside its cover-fit window into
/// `ratio` dimmed.
struct ShapemationContactTile: View {
    let project: ShapemationBuilder.ProjectShapes
    let image: CGImage?
    let ratio: Double

    var body: some View {
        let frame = project.frameSize
        let a = Double(frame.width) / max(Double(frame.height), 1)
        let side = 84.0
        let w = a >= 1 ? side : side * a, h = a >= 1 ? side / a : side
        ZStack(alignment: .topLeading) {
            Color.black
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(decorative: image, scale: 1).resizable().frame(width: w, height: h)
                } else {
                    Color.secondary.opacity(0.2).frame(width: w, height: h)
                }
                // The cover-fit window into the set's aspect: the overhang on the longer axis is what the fit alone takes.
                let ex = a > ratio ? a / ratio - 1 : 0, ey = a < ratio ? ratio / a - 1 : 0
                let ww = 1 / (1 + ex), wh = 1 / (1 + ey)
                Rectangle().fill(.black.opacity(0.45)).frame(width: w, height: h)
                    .mask(
                        Rectangle().frame(width: w, height: h)
                            .overlay(Rectangle().frame(width: ww * w, height: wh * h).offset(x: (1 - ww) / 2 * w, y: (1 - wh) / 2 * h).blendMode(.destinationOut))
                            .compositingGroup()
                    )
                if let shape = project.largestShape {
                    let b = shape.bounds(in: frame)
                    Rectangle().stroke(LL.amber, lineWidth: 1.5)
                        .frame(width: max(2, b.width / frame.width * w), height: max(2, b.height / frame.height * h))
                        .offset(x: b.minX / frame.width * w, y: b.minY / frame.height * h)
                }
            }
            .frame(width: w, height: h)
            .frame(width: side, height: side)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityLabel(project.capture.displayTitle)
    }
}

/// Capsule chips that wrap to the next line when the row is full — the
/// tag editor's layout (`components/tag-suggestions`), a real flow rather
/// than `FlowChips`' fixed rows.
struct ShapemationFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x = 0.0, y = 0.0, rowHeight = 0.0, maxX = 0.0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width.isFinite ? width : maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight = 0.0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// The Sort menu the Projects step and the Sequence board share: the order
/// the photos play in, changed in place.
struct ShapemationSortMenu: View {
    @ObservedObject var builder: ShapemationBuilder

    var body: some View {
        Menu {
            ForEach(ShapemationSort.allCases, id: \.self) { sort in
                Button {
                    builder.sort = sort
                } label: {
                    if builder.sort == sort { Label(sort.title, systemImage: "checkmark") } else { Text(sort.title) }
                }
            }
        } label: {
            // One Text: the Mac's borderless menu shows only the first view of a label.
            (Text("Sort · ").foregroundColor(.secondary) + Text(builder.sort.title).foregroundColor(LL.accent).fontWeight(.semibold))
                .font(.system(size: 13))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Sort: \(builder.sort.title)")
    }
}
