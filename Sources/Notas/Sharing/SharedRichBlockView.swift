import SwiftUI

/// Export blocks have no scrolling or editing controls, so their whole contents are visible.
struct SharedRichBlockView: View {
    let block: Block
    let style: ResolvedStyle
    let images: [String: Data]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(block.kind.displayName, systemImage: block.kind.symbol)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(style.tertiary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(style.text.opacity(0.09), lineWidth: 1))
        .foregroundStyle(style.text)
        .environment(\.colorScheme, style.colorScheme)
    }

    @ViewBuilder private var content: some View {
        switch block.kind {
        case .gallery:
            let names = block.payload?.images ?? []
            let count = max(1, min(4, block.payload?.galleryColumns ?? min(3, max(1, names.count))))
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(Array(stride(from: 0, to: names.count, by: count)), id: \.self) { start in
                    GridRow {
                        ForEach(start..<min(start + count, names.count), id: \.self) { index in
                            if let data = images[names[index]], let image = NSImage(data: data) {
                                Image(nsImage: image).resizable().scaledToFit()
                                    .frame(maxWidth: .infinity, maxHeight: 280)
                            }
                        }
                    }
                }
            }
        case .table:
            let table = block.payload?.table ?? TableData(rows: [])
            VStack(spacing: 1) {
                ForEach(table.rows.indices, id: \.self) { row in
                    HStack(alignment: .top, spacing: 1) {
                        ForEach(0..<max(1, table.columnCount), id: \.self) { column in
                            Text(table.rows[row][safe: column] ?? "")
                                .font(.system(size: 13, weight: row == 0 && table.header ? .semibold : .regular))
                                .frame(maxWidth: .infinity, minHeight: 17, alignment: .topLeading)
                                .padding(10)
                                .background(row == 0 && table.header ? style.accentColor.opacity(0.1) : style.background.opacity(0.35))
                        }
                    }
                }
            }.background(style.text.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 6))
        case .board:
            HStack(alignment: .top, spacing: 10) {
                ForEach(block.payload?.board?.columns ?? []) { column in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(column.title).font(.system(size: 13, weight: .semibold))
                            Spacer(minLength: 3)
                            Text("\(column.cards.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(style.tertiary)
                        }
                        ForEach(column.cards) { card in
                            Text(card.text).font(.system(size: 13))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(style.surface, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(style.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        case .columns:
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array((block.payload?.columns ?? []).enumerated()), id: \.offset) { index, text in
                    if index > 0 { Rectangle().fill(style.text.opacity(0.08)).frame(width: 1) }
                    Text(text).font(.system(size: 13)).lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        case .sketch:
            if let sketch = block.payload?.sketch {
                Canvas { context, size in
                    context.withCGContext { cg in sketch.draw(in: cg, size: size, ink: style.nsText) }
                }
                .frame(height: 260)
                .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
            }
        default: EmptyView()
        }
    }
}
