import SwiftUI

enum QuickPanelEdge {
    case top
    case bottom
}

enum QuickPanelMetrics {
    static let headerHeight: CGFloat = 56
    static let footerHeight: CGFloat = 48
    static let fadeLength: CGFloat = 16

    static let topEdgeHeight = headerHeight + fadeLength
    static let bottomEdgeHeight = footerHeight + fadeLength
}

/// Places scrollable panel content beneath a floating material header and an
/// optional footer. Callers retain ownership of their content and scroll insets.
struct QuickPanelScaffold<Content: View, Header: View, Footer: View>: View {
    private let content: Content
    private let header: Header
    private let footer: Footer?
    private let footerHeight: CGFloat
    @State private var measuredFooterEdgeHeight: CGFloat = 0

    init(
        footerHeight: CGFloat = QuickPanelMetrics.footerHeight,
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header,
        @ViewBuilder footer: () -> Footer
    ) {
        self.content = content()
        self.header = header()
        self.footer = footer()
        self.footerHeight = footerHeight
    }

    var body: some View {
        ZStack {
            content
                // Existing callers already reserve the normal footer. Reserve
                // only its additional height when shared action labels wrap.
                .padding(.bottom, max(0, measuredFooterEdgeHeight - footerHeight - QuickPanelMetrics.fadeLength))

            VStack(spacing: 0) {
                QuickPanelScrollEdge(edge: .top) {
                    header
                }

                Spacer(minLength: 0)

                if let footer {
                    QuickPanelScrollEdge(edge: .bottom, contentHeight: footerHeight) {
                        footer
                    }
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: QuickPanelFooterHeightKey.self, value: proxy.size.height)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(QuickPanelFooterHeightKey.self) { measuredFooterEdgeHeight = $0 }
    }
}

extension QuickPanelScaffold where Footer == EmptyView {
    init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header
    ) {
        self.content = content()
        self.header = header()
        self.footer = nil
        self.footerHeight = QuickPanelMetrics.footerHeight
    }
}

private struct QuickPanelFooterHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct QuickPanelScrollEdge<Content: View>: View {
    let edge: QuickPanelEdge
    var contentHeight: CGFloat? = nil
    @ViewBuilder let content: () -> Content

    private var edgeHeight: CGFloat {
        let height = contentHeight ?? (edge == .top
            ? QuickPanelMetrics.headerHeight
            : QuickPanelMetrics.footerHeight)
        return height + QuickPanelMetrics.fadeLength
    }

    @ViewBuilder
    var body: some View {
        if edge == .bottom {
            content()
                .padding(.vertical, QuickPanelMetrics.fadeLength / 2)
                .frame(minHeight: edgeHeight, alignment: .bottom)
                .background { materialBackground }
        } else {
            content()
                .padding(.top, 8)
                .frame(height: edgeHeight, alignment: .top)
                .background { materialBackground }
        }
    }

    private var materialBackground: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .mask(edgeMask)
                .allowsHitTesting(false)

            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .opacity(0.30)
                .mask(emphasisMask)
                .allowsHitTesting(false)

        }
    }

    private var edgeMask: some View {
        LinearGradient(
            stops: edge == .top
                ? [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.92), location: 0.60),
                    .init(color: .clear, location: 1),
                ]
                : [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.92), location: 0.40),
                    .init(color: .black, location: 1),
                ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var emphasisMask: some View {
        LinearGradient(
            stops: edge == .top
                ? [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.88), location: 0.58),
                    .init(color: .clear, location: 1),
                ]
                : [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.88), location: 0.42),
                    .init(color: .black, location: 1),
                ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

struct QuickPanelButtonBackground: View {
    var isSelected = false

    var body: some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
            .fill(AppTheme.Surface.control)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                        .fill(AppTheme.Selection.fill)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                    .strokeBorder(
                        isSelected ? AppTheme.Selection.border : AppTheme.Border.card,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
    }
}

struct QuickPanelEscapeButton: View {
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("esc")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.Text.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(AppTheme.Surface.controlActive, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("Escape")
        .accessibilityHint(help)
    }
}
