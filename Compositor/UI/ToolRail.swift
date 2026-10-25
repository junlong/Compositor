import SwiftUI
import Combine

/// How the tool rail lays out its tools: one column as it always has, or two for a rail about half as tall when one
/// doesn't fit.
enum ToolRailLayout {
    static let buttonSize: CGFloat = 36
    static let columnSpacing: CGFloat = 8
    static let rowSpacing: CGFloat = 10

    /// 56 pt in one column; 92 in two (two buttons, the gap between them and 6 pt margins each side).
    static func width(columns: Int) -> CGFloat {
        columns >= 2 ? buttonSize * 2 + columnSpacing + 12 : 56
    }

    /// The tools in rows of `columns`, in the rail's order read left to right.
    static func rows(_ tools: [NavigationTool], columns: Int) -> [[NavigationTool]] {
        let count = min(2, max(1, columns))
        return stride(from: 0, to: tools.count, by: count).map { Array(tools[$0..<min($0 + count, tools.count)]) }
    }

    /// What one column needs vertically, including the swatches under it. ViewThatFits measured this exactly on
    /// macOS 13; the port measures the offered height against this estimate instead.
    static func singleColumnHeight(toolCount: Int) -> CGFloat {
        let rows = CGFloat(max(1, toolCount))
        return 16 + 12 + 8 + 44 + rows * buttonSize + (rows - 1) * rowSpacing
    }
}

/// The tools down the left of the window, with the color swatches under them: in one column while it fits the
/// window's height, otherwise in two, which scroll if the window is shorter still.
@MainActor
struct ToolRail: View {
    @ObservedObject var session: EditorSession

    /// One column while the window has room, otherwise two, which scroll when it is shorter still.
    @State private var columns = 1
    private var toolCount: Int { NavigationTool.allCases.filter { $0 != .idle }.count }

    var body: some View {
        rail
            .frame(width: ToolRailLayout.width(columns: columns))
            .frame(maxHeight: .infinity, alignment: .top)
            .onAppear {
                updateColumnsFromWindow()
                // The rail may appear before its window has its final size.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { updateColumnsFromWindow() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { _ in
                updateColumnsFromWindow()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                updateColumnsFromWindow()
            }
    }

    @ViewBuilder private var rail: some View {
        if columns == 1 {
            ToolRailStack(session: session, columns: 1)
        } else {
            // Scrolls when the window is too short for every tool, rather than pushing the bars above and below away.
            IndicatorlessScrollView { ToolRailStack(session: session, columns: 2) }
                .frame(width: ToolRailLayout.width(columns: 2))
        }
    }

    /// The window's content height less the tool header and status bar, which sit above and below the rail.
    private func updateColumnsFromWindow() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }),
              let content = window.contentView else { return }
        let available = content.bounds.height - 85
        let wanted = available >= ToolRailLayout.singleColumnHeight(toolCount: toolCount) ? 1 : 2
        if wanted != columns { columns = wanted }
    }
}

/// The rail's contents: the tools in rows, and the color swatches.
@MainActor
struct ToolRailStack: View {
    @ObservedObject var session: EditorSession
    let columns: Int

    private var tools: [NavigationTool] { NavigationTool.allCases.filter { $0 != .idle } }

    var body: some View {
        let width = ToolRailLayout.width(columns: columns)
        let twoColumns = columns >= 2
        VStack(spacing: ToolRailLayout.rowSpacing) {
            ForEach(Array(ToolRailLayout.rows(tools, columns: columns).enumerated()), id: \.offset) { _, row in
                HStack(spacing: ToolRailLayout.columnSpacing) {
                    ForEach(row, id: \.self) { toolButton($0) }
                }
                // A lone last tool stays in the left column.
                .frame(width: twoColumns ? ToolRailLayout.buttonSize * 2 + ToolRailLayout.columnSpacing : ToolRailLayout.buttonSize,
                       alignment: .leading)
            }
            ColorPaletteControls(session: session).padding(.top, 8)
        }
        .padding(.top, 16).padding(.bottom, 12)
        .frame(width: width)
    }

    private func toolButton(_ tool: NavigationTool) -> some View {
        Button { session.selectTool(tool) } label: {
            Group {
                if tool == .gradient { GradientToolIcon().frame(width: 18, height: 18) }
                else if tool == .cloneStamp { CloneStampToolIcon().frame(width: 18, height: 18) }
                else if tool == .lasso, session.lassoKind == .polygonal { PolygonalLassoToolIcon().frame(width: 18, height: 18) }
                else if tool == .wand, session.wandMode == .object { ObjectSelectionToolIcon().frame(width: 18, height: 18) }
                // The Marquee's icon follows its shape: a dashed circle in Ellipse mode.
                else { Image(systemName: tool == .marquee && session.marqueeKind == .ellipse ? "circle.dashed" : session.symbol(for: tool)).font(.system(size: 17)) }
            }
            .frame(width: ToolRailLayout.buttonSize, height: ToolRailLayout.buttonSize)
            .background(session.tool == tool ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(session.tool == tool ? Color.white.opacity(0.14) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(tool.label).accessibilityLabel(tool.label)
        .foregroundStyle(.primary)
        .accessibilityAddTraits(session.tool == tool ? .isSelected : [])
    }
}
