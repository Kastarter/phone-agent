import SwiftUI

struct SidebarMainSurface: ViewModifier {
    let open: Bool
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        let edge = MainSurfaceLeadingEdge(radius: 32)
        content
            .mask {
                UnevenRoundedRectangle(topLeadingRadius: open ? 32 : 0,
                                       bottomLeadingRadius: open ? 32 : 0, style: .continuous)
                    .ignoresSafeArea(.container, edges: .vertical)
            }
            .overlay {
                if open {
                    edge.stroke(AgentPalette.ink.opacity(colorScheme == .light ? 0.18 : 0.08),
                                style: StrokeStyle(lineWidth: 0.75, lineCap: .round))
                        .ignoresSafeArea(.container, edges: .vertical)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

private struct MainSurfaceLeadingEdge: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = min(radius, min(rect.width, rect.height / 2))
        var path = Path()
        path.move(to: CGPoint(x: r, y: 0))
        path.addCurve(to: CGPoint(x: 0, y: r),
                      control1: CGPoint(x: r * 0.46, y: 0),
                      control2: CGPoint(x: 0, y: r * 0.46))
        path.addLine(to: CGPoint(x: 0, y: rect.maxY - r))
        path.addCurve(to: CGPoint(x: r, y: rect.maxY),
                      control1: CGPoint(x: 0, y: rect.maxY - r * 0.46),
                      control2: CGPoint(x: r * 0.46, y: rect.maxY))
        return path
    }
}
