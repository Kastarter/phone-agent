import SwiftUI
import UIKit

enum AgentTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    static let storageKey = "agent.appearance"
    var id: String { rawValue }
    var title: String {
        switch self { case .system: "Match System"; case .light: "Light"; case .dark: "Dark" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

private struct AgentThemeModifier: ViewModifier {
    @AppStorage(AgentTheme.storageKey) private var selection = AgentTheme.system.rawValue
    private var theme: AgentTheme {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--ui-review"), let index = args.firstIndex(of: "--ui-appearance"),
           args.indices.contains(index + 1), let preview = AgentTheme(rawValue: args[index + 1]) {
            return preview
        }
        #endif
        return AgentTheme(rawValue: selection) ?? .system
    }
    func body(content: Content) -> some View { content.preferredColorScheme(theme.colorScheme) }
}

// A quiet chat canvas, grouped utility pages, and blue primary actions.
enum AgentPalette {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.16, green: 0.55, blue: 1, alpha: 1)
            : UIColor(red: 0, green: 0.38, blue: 0.84, alpha: 1)
    })
    static let background = Color(uiColor: .systemBackground)
    static let surface = gray(light: 0.955, dark: 0.12)
    static let inset = gray(light: 0.975, dark: 0.075)
    static let line = Color(uiColor: .separator)
    static let ink = Color(uiColor: .label)
    static let placeholder = gray(light: 0.43, dark: 0.62)
    static let secondaryText = gray(light: 0.40, dark: 0.70)
    static let onContrast = Color(uiColor: .systemBackground)
    static let userBubble = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.045, green: 0.13, blue: 0.23, alpha: 1)
            : UIColor(red: 0.90, green: 0.95, blue: 1, alpha: 1)
    })
    static let positive = Color.green
    private static func gray(light: CGFloat, dark: CGFloat) -> Color {
        Color(uiColor: UIColor { traits in UIColor(white: traits.userInterfaceStyle == .dark ? dark : light, alpha: 1) })
    }
}

// Home shortcuts and all composer states share the same large control geometry.
enum AgentInputMetrics {
    static let height: CGFloat = 56
    static let cornerRadius: CGFloat = 28
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }
}

// The visible glyph is outside the replacing input/voice branches. Keep its
// last measured position through the temporary empty preference on a swap.
private struct AgentComposerLeadingBoundsKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

struct AgentComposerLeadingSlot: View {
    var body: some View {
        Color.clear.frame(width: 44, height: 44)
            .background(AgentPalette.ink.opacity(0.08), in: Circle())
            .contentShape(Circle())
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: AgentComposerLeadingBoundsKey.self,
                        value: geometry.frame(in: .named("agentComposerControls")))
                }
            }
    }
}

private struct AgentComposerLeadingGlyphIcon: View {
    let recording: Bool
    @State private var angle: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(recording: Bool) {
        self.recording = recording
        _angle = State(initialValue: recording ? 45 : 0)
    }
    var body: some View {
        Image(systemName: "plus").font(.system(size: 18, weight: .medium))
            .foregroundStyle(.primary)
            .rotationEffect(.degrees(angle))
            .frame(width: 44, height: 44)
            .onChange(of: recording) { _, active in
                withAnimation(reduceMotion ? nil : .timingCurve(0.77, 0, 0.175, 1, duration: 0.18)) {
                    angle = active ? 45 : 0
                }
            }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct AgentComposerLeadingGlyph: ViewModifier {
    let recording: Bool
    @State private var bounds: CGRect = .zero
    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            AgentComposerLeadingGlyphIcon(recording: recording)
                .offset(x: bounds.minX, y: bounds.minY)
                .opacity(bounds.isEmpty ? 0 : 1)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .coordinateSpace(name: "agentComposerControls")
        .onPreferenceChange(AgentComposerLeadingBoundsKey.self) { value in
            if !value.isEmpty { bounds = value }
        }
    }
}

private struct AgentInsideGlassKey: EnvironmentKey {
    static let defaultValue = false
}
private extension EnvironmentValues {
    var agentInsideGlass: Bool {
        get { self[AgentInsideGlassKey.self] }
        set { self[AgentInsideGlassKey.self] = newValue }
    }
}

// A shared material keeps every utility page aligned with the settings shell.
struct AgentCard<Content: View>: View {
    @Environment(\.agentInsideGlass) private var insideGlass
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.environment(\.agentInsideGlass, true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .agentGlass(in: AgentInputMetrics.shape, clear: insideGlass)
    }
}

struct AgentSettingsRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let subtitle: String
    let icon: String
    var body: some View {
        HStack(spacing: 14) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: icon).font(.system(size: 19, weight: .medium))
                    .foregroundStyle(AgentPalette.secondaryText).frame(width: 24, height: 24)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(AgentPalette.secondaryText).lineLimit(typeSize.isAccessibilitySize ? nil : 2) }
            }
            Spacer(minLength: 8)
        }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

struct AgentBackdrop: View {
    var body: some View { AgentPalette.background.ignoresSafeArea().accessibilityHidden(true) }
}

struct AgentOrb: View {
    var size: CGFloat = 80
    var active: Bool = false
    var idleIcon: String = "sparkle"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        Image(systemName: active ? "waveform" : idleIcon)
            .font(.system(size: size * 0.52, weight: .light))
            .foregroundStyle(active ? AgentPalette.accent : AgentPalette.ink)
            .frame(width: size, height: size)
            .symbolEffect(.variableColor, isActive: active && !reduceMotion)
            .accessibilityHidden(true)
    }
}

// Keep system Liquid Glass interaction and button roles instead of reproducing
// the material with a blurred background or a custom press animation.
struct AgentButtonStyle: PrimitiveButtonStyle {
    var primary = true
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if reduceTransparency || contrast == .increased {
                if primary { button(configuration).buttonStyle(.borderedProminent) }
                else { button(configuration).buttonStyle(.bordered) }
            } else if primary {
                button(configuration).buttonStyle(.glassProminent)
            } else {
                button(configuration).buttonStyle(.glass)
            }
        }.tint(primary ? AgentPalette.accent : AgentPalette.ink).buttonBorderShape(.roundedRectangle(radius: 16))
    }
    private func button(_ configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.font(.subheadline.weight(.semibold))
                .foregroundStyle(configuration.role == .destructive ? Color.red : (primary ? Color.white : AgentPalette.ink))
                .frame(maxWidth: .infinity, minHeight: 48).opacity(enabled ? 1 : 0.38)
        }
    }
}

struct AgentSectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(AgentPalette.secondaryText) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AgentNotice: View {
    let text: String
    var error = false
    var body: some View {
        Label {
            Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: error ? "exclamationmark.circle" : "info.circle")
        }.foregroundStyle(error ? Color.red : AgentPalette.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
    }
}

struct AgentCircleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 23, weight: .regular))
            .foregroundStyle(.primary).frame(width: 62, height: 62)
            .agentGlass(in: Circle(), interactive: true)
            .opacity(enabled ? 1 : 0.4).opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: configuration.isPressed)
    }
}

struct AgentPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .smooth(duration: 0.14), value: configuration.isPressed)
    }
}

private struct AgentPanel: ViewModifier {
    var padding: CGFloat
    @Environment(\.agentInsideGlass) private var insideGlass
    func body(content: Content) -> some View {
        content.environment(\.agentInsideGlass, true)
            .padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .agentGlass(in: AgentInputMetrics.shape, clear: insideGlass)
    }
}

private struct AgentFieldSurface: ViewModifier {
    @Environment(\.agentInsideGlass) private var insideGlass
    func body(content: Content) -> some View {
        content.padding(14)
            .frame(minHeight: AgentInputMetrics.height)
            .agentGlass(in: AgentInputMetrics.shape, interactive: true, clear: insideGlass)
    }
}

private struct AgentGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let tint: Color?
    let clear: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(AgentPalette.surface, in: shape)
                .overlay { shape.stroke(AgentPalette.ink.opacity(contrast == .increased ? 0.55 : 0.18), lineWidth: 1) }
        } else {
            content.glassEffect((clear ? Glass.clear : Glass.regular).tint(tint)
                .interactive(interactive && !reduceMotion), in: shape)
        }
    }
}

extension View {
    func agentComposerLeadingGlyph(recording: Bool) -> some View {
        modifier(AgentComposerLeadingGlyph(recording: recording))
    }
    func agentTheme() -> some View { modifier(AgentThemeModifier()) }
    func agentPanel(padding: CGFloat = 16) -> some View { modifier(AgentPanel(padding: padding)) }
    func agentGlass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil, clear: Bool = false) -> some View {
        modifier(AgentGlassSurface(shape: shape, interactive: interactive, tint: tint, clear: clear))
    }
    func agentSheetStyle() -> some View {
        presentationDetents([.large]).presentationDragIndicator(.visible)
            .presentationCornerRadius(28).presentationBackground(AgentPalette.background)
    }
    func agentField() -> some View {
        modifier(AgentFieldSurface())
    }
}

struct AgentPageIntro: View {
    let title: String
    let subtitle: String
    var icon: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let icon { Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(AgentPalette.accent).padding(.bottom, 4) }
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.subheadline).foregroundStyle(AgentPalette.secondaryText).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct AgentHelp: View {
    let title: String
    let text: String
    var body: some View {
        DisclosureGroup(title) {
            Text(text).font(.footnote).foregroundStyle(AgentPalette.secondaryText).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
        }.font(.subheadline).foregroundStyle(.primary).tint(.primary).agentPanel()
    }
}
struct AgentEmptyState: View {
    let title: String
    let detail: String
    let icon: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 36, weight: .light)).foregroundStyle(AgentPalette.secondaryText)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(AgentPalette.secondaryText).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 42).padding(.horizontal, 20)
    }
}
