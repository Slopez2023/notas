import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RichBlockView: View {
    let attachment: RichBlockAttachment
    @ObservedObject var state: RichBlockState
    @State private var preview: String?
    @State private var tableFocus: String?
    @State private var pen: SketchCanvas.Tool = .pen
    @State private var ink: UInt32?

    private var style: ResolvedStyle { state.style }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: state.kind.symbol)
                Text(state.kind.displayName).fontWeight(.medium)
                Spacer()
                controls
                Menu {
                    Button("Delete block", role: .destructive) { attachment.editor?.removeRichBlock(attachment) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().help("Block options")
            }
            .font(.system(size: 11)).foregroundStyle(style.tertiary)
            .padding(.horizontal, 14).frame(height: 42)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(style.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(style.text.opacity(0.09), lineWidth: 1))
        .foregroundStyle(style.text).tint(style.accentColor)
        .environment(\.colorScheme, style.colorScheme)
        .sheet(item: Binding(get: { preview.map(PhotoPreviewID.init) }, set: { preview = $0?.id })) { item in
            VStack(spacing: 12) {
                HStack {
                    Text("Photo").font(.headline)
                    Spacer()
                    Button("Done") { preview = nil }.keyboardShortcut(.cancelAction)
                }
                PhotoImage(url: attachment.assets?.url(for: item.id), maxPixel: 2400, fill: false) {
                    ContentUnavailableView("Photo unavailable", systemImage: "photo", description: Text("Wait for iCloud to download this photo."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }.padding(20).frame(width: 760, height: 560)
        }
    }

    @ViewBuilder private var controls: some View {
        switch state.kind {
        case .gallery:
            Picker("Photos across", selection: Binding(get: { state.payload.galleryColumns ?? min(3, max(1, state.payload.images?.count ?? 0)) }, set: { value in change { $0.galleryColumns = value } })) {
                ForEach(1...4, id: \.self) { Text("\($0) across").tag($0) }
            }.labelsHidden().frame(width: 90)
            Button { attachment.editor?.importPhotos(into: attachment) } label: { Image(systemName: "plus") }.help("Add photos or scanned pages")
        case .table:
            Button { changeTable { $0.rows.append(Array(repeating: "", count: $0.columnCount)) } } label: { Label("Row", systemImage: "plus") }
            Button { changeTable { table in for i in table.rows.indices { table.rows[i].append("") } } } label: { Label("Column", systemImage: "plus") }
            Menu {
                Button(state.payload.table?.header == true ? "Hide header" : "Show header") { changeTable { $0.header.toggle() } }
                Button("Delete last row") { changeTable { if $0.rows.count > 1 { $0.rows.removeLast() } } }
                Button("Delete last column") { changeTable { table in if table.columnCount > 1 { for i in table.rows.indices { table.rows[i].removeLast() } } } }
            } label: { Image(systemName: "tablecells") }.menuStyle(.borderlessButton).fixedSize().help("Table options")
        case .board:
            Button { changeBoard { $0.columns.append(BoardColumn(title: "New column", cards: [])) } } label: { Label("Column", systemImage: "plus") }
        case .sketch:
            Picker("Drawing tool", selection: $pen) {
                Image(systemName: "pencil.tip").tag(SketchCanvas.Tool.pen).help("Pen")
                Image(systemName: "highlighter").tag(SketchCanvas.Tool.marker).help("Highlighter")
                Image(systemName: "eraser").tag(SketchCanvas.Tool.eraser).help("Eraser")
            }.labelsHidden().pickerStyle(.segmented).frame(width: 106)
            ForEach([InkColor.purple, .pink, .blue, .green], id: \.self) { color in
                Button { ink = color.hex } label: {
                    Circle().fill(Color(nsColor: NSColor(hex: color.hex))).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(style.text.opacity(ink == color.hex ? 0.9 : 0), lineWidth: 1.5).padding(-3))
                }.buttonStyle(.plain).help(color.label)
            }
            Button { ink = nil } label: { Circle().fill(style.text).frame(width: 12, height: 12) }.help("Theme ink")
            Button("Clear") { change { $0.sketch?.strokes.removeAll() } }
        default: EmptyView()
        }
    }

    @ViewBuilder private var content: some View {
        switch state.kind {
        case .gallery: gallery
        case .table: table
        case .board: board
        case .columns: columns
        case .sketch:
            SketchCanvas(data: state.payload.sketch ?? SketchData(width: 640, height: 260, strokes: []), tool: pen, ink: ink, style: style) { data in change { $0.sketch = data } }
                .padding(.horizontal, 12).padding(.bottom, 12)
        default: EmptyView()
        }
    }

    private func change(coalesce key: String? = nil, _ update: (inout BlockPayload) -> Void) {
        var payload = state.payload
        update(&payload)
        attachment.update(payload, coalesce: key)
    }

    private func changeTable(coalesce key: String? = nil, _ update: (inout TableData) -> Void) {
        change(coalesce: key) { payload in
            var table = payload.table ?? TableData(rows: [["", "", ""]])
            table.normalize()
            update(&table)
            payload.table = table
        }
    }

    private func changeBoard(coalesce key: String? = nil, _ update: (inout BoardData) -> Void) {
        change(coalesce: key) { payload in
            var board = payload.board ?? BoardData(columns: [])
            update(&board)
            payload.board = board
        }
    }

    private var gallery: some View {
        GeometryReader { geometry in
            let images = state.payload.images ?? []
            let count = max(1, min(4, state.payload.galleryColumns ?? min(3, max(1, images.count))))
            if images.isEmpty {
                Button { attachment.editor?.importPhotos(into: attachment) } label: {
                    VStack(spacing: 9) {
                        Image(systemName: "photo.badge.plus").font(.system(size: 25, weight: .light))
                        Text("Add photos").font(.system(size: 13, weight: .medium))
                        Text("Drop images here, or choose files").font(.system(size: 11)).foregroundStyle(style.tertiary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.buttonStyle(.plain)
            } else {
                let height = min(220, (geometry.size.width - CGFloat(count - 1) * 8) / CGFloat(count) * 0.72)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: count), spacing: 8) {
                    ForEach(Array(images.enumerated()), id: \.offset) { index, name in
                        Button { preview = name } label: {
                            PhotoImage(url: attachment.assets?.url(for: name), maxPixel: 1400, fill: true) {
                                Image(systemName: "icloud.and.arrow.down").frame(maxWidth: .infinity, maxHeight: .infinity)
                            }.frame(height: height).frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).accessibilityLabel("Photo \(index + 1)")
                        .contextMenu {
                            Button("View photo") { preview = name }
                            Button("Move earlier") { change { payload in if index > 0 { payload.images?.swapAt(index, index - 1) } } }.disabled(index == 0)
                            Button("Remove photo", role: .destructive) { change { $0.images?.remove(at: index) } }
                        }
                    }
                }
            }
        }.padding(.horizontal, 14).padding(.bottom, 12)
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            importDrop(providers)
        }
    }

    private func importDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let assets = attachment.assets else { return false }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    DispatchQueue.main.async {
                        guard let url else { return }
                        do { let names = try assets.importFile(url); change { $0.images = ($0.images ?? []) + names } }
                        catch { attachment.editor?.presentAssetError(error) }
                    }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    DispatchQueue.main.async {
                        guard let image = object as? NSImage else { return }
                        do { let name = try assets.importImage(image); change { $0.images = ($0.images ?? []) + [name] } }
                        catch { attachment.editor?.presentAssetError(error) }
                    }
                }
            }
        }
        return !providers.isEmpty
    }

    private var table: some View {
        let data = state.payload.table ?? TableData(rows: [["", "", ""]])
        return GeometryReader { geometry in
        ScrollView(.horizontal) {
            VStack(spacing: 1) {
                ForEach(data.rows.indices, id: \.self) { row in
                    HStack(spacing: 1) {
                        ForEach(0..<data.columnCount, id: \.self) { column in
                            let key = "\(row)-\(column)"
                            BlockInput(text: Binding(get: { state.payload.table?.rows[safe: row]?[safe: column] ?? "" }, set: { value in changeTable(coalesce: "cell-\(row)-\(column)") { $0.rows[row][column] = value } }),
                                       placeholder: row == 0 && data.header ? "Heading" : "", style: style,
                                       bold: row == 0 && data.header, focus: tableFocus == key, label: "Row \(row + 1), column \(column + 1)",
                                       onTab: { backwards in tableTab(row: row, column: column, backwards: backwards) },
                                       onEscape: { attachment.editor?.refocus() })
                                .padding(.horizontal, 10).frame(minWidth: 110, maxWidth: .infinity).frame(height: 37)
                                .background(row == 0 && data.header ? style.accentColor.opacity(0.1) : style.background.opacity(0.35))
                        }
                    }
                }
            }.background(style.text.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(width: max(geometry.size.width, CGFloat(data.columnCount) * 111))
        }
        }.padding(.horizontal, 14).padding(.bottom, 14)
    }

    private func tableTab(row: Int, column: Int, backwards: Bool) {
        guard let table = state.payload.table else { return }
        let count = table.columnCount
        let next = row * count + column + (backwards ? -1 : 1)
        if next < 0 { tableFocus = nil; attachment.editor?.refocus(); return }
        if next >= table.rows.count * count { changeTable { $0.rows.append(Array(repeating: "", count: count)) } }
        tableFocus = "\(next / count)-\(next % count)"
    }

    private var board: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(state.payload.board?.columns ?? []) { column in
                    VStack(spacing: 8) {
                        HStack(spacing: 6) {
                            BlockInput(text: Binding(get: { state.payload.board?.columns.first { $0.id == column.id }?.title ?? "" }, set: { value in changeBoard(coalesce: "title-" + column.id) { board in if let i = board.columns.firstIndex(where: { $0.id == column.id }) { board.columns[i].title = value } } }), placeholder: "Column", style: style, bold: true, label: "Board column name")
                            Text("\(column.cards.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(style.tertiary)
                            Menu {
                                Button("Delete column", role: .destructive) { changeBoard { $0.columns.removeAll { $0.id == column.id } } }
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                        }
                        ScrollView {
                            VStack(spacing: 7) {
                                ForEach(column.cards) { card in
                                    boardCard(card, in: column)
                                        .onDrop(of: [.text], isTargeted: nil) { dropCard($0, column: column.id, before: card.id) }
                                }
                                Color.clear.frame(height: 18).contentShape(Rectangle())
                            }
                        }.scrollIndicators(.hidden)
                        Button { changeBoard { board in if let i = board.columns.firstIndex(where: { $0.id == column.id }) { board.columns[i].cards.append(BoardCard(text: "")) } } } label: {
                            Label("Add card", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).foregroundStyle(style.tertiary).font(.system(size: 11))
                    }
                    .padding(10).frame(width: 192, height: 292).background(style.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .onDrop(of: [.text], isTargeted: nil) { dropCard($0, column: column.id) }
                }
            }.padding(.horizontal, 14)
        }.padding(.bottom, 12)
    }

    private func boardCard(_ card: BoardCard, in column: BoardColumn) -> some View {
        HStack(spacing: 5) {
            BoardDragHandle(cardID: card.id, color: style.nsTertiary).frame(width: 16, height: 24)
            BlockInput(text: Binding(get: { state.payload.board?.columns.flatMap(\.cards).first { $0.id == card.id }?.text ?? "" }, set: { value in changeBoard(coalesce: "card-" + card.id) { board in for i in board.columns.indices { if let j = board.columns[i].cards.firstIndex(where: { $0.id == card.id }) { board.columns[i].cards[j].text = value } } } }), placeholder: "Write a card", style: style, label: "Board card")
            Menu {
                ForEach(state.payload.board?.columns.filter { $0.id != column.id } ?? []) { destination in
                    Button("Move to \(destination.title)") { changeBoard { $0.move(card: card.id, to: destination.id) } }
                }
                Button("Delete card", role: .destructive) { changeBoard { board in for i in board.columns.indices { board.columns[i].cards.removeAll { $0.id == card.id } } } }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
        }.padding(9).background(style.surface, in: RoundedRectangle(cornerRadius: 6))
    }

    private func dropCard(_ providers: [NSItemProvider], column: String, before: String? = nil) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, string.hasPrefix("notas-card:") else { return }
            let id = String(string.dropFirst("notas-card:".count))
            DispatchQueue.main.async { changeBoard { $0.move(card: id, to: column, before: before) } }
        }
        return true
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(0..<2, id: \.self) { index in
                BlockTextArea(text: Binding(get: { state.payload.columns?[safe: index] ?? "" }, set: { value in change(coalesce: "column-\(index)") { payload in var columns = payload.columns ?? ["", ""]; while columns.count < 2 { columns.append("") }; columns[index] = value; payload.columns = columns } }), style: style, label: index == 0 ? "Left column" : "Right column", escape: { attachment.editor?.refocus() })
                    .frame(maxWidth: .infinity)
                if index == 0 { Rectangle().fill(style.text.opacity(0.08)).frame(width: 1) }
            }
        }.padding(.horizontal, 14).padding(.bottom, 14)
    }
}

private struct PhotoPreviewID: Identifiable { let id: String }

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}


/// A photo from the note's assets, decoded once at display size and cached. Shows `missing`
/// when the file isn't there (for example, still downloading from iCloud).
struct PhotoImage<Missing: View>: View {
    let url: URL?
    let maxPixel: Int
    let fill: Bool
    @ViewBuilder let missing: () -> Missing
    @State private var image: NSImage?
    @State private var failed = false

    init(url: URL?, maxPixel: Int, fill: Bool, @ViewBuilder missing: @escaping () -> Missing) {
        self.url = url
        self.maxPixel = maxPixel
        self.fill = fill
        self.missing = missing
        _image = State(initialValue: url.flatMap { PhotoCache.cached($0, maxPixel: maxPixel) })
    }

    var body: some View {
        Group {
            if let image {
                if fill { Image(nsImage: image).resizable().scaledToFill() }
                else { Image(nsImage: image).resizable().scaledToFit() }
            } else if failed || url == nil {
                missing()
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            guard let url, image == nil else { return }
            image = await PhotoCache.load(url, maxPixel: maxPixel)
            failed = image == nil
        }
    }
}
