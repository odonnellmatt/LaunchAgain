//
//  Shared view components.
//
//  Two ideas run through all of these:
//
//  · The instance *number* is the identifier. Colour is decoration, never the only
//    thing distinguishing two instances, because colour alone excludes anyone with a
//    colour-vision deficiency.
//  · Limitations are shown, not hidden behind a disclosure triangle. A user deciding
//    whether to create three instances of their password manager deserves to read the
//    Keychain sentence before they click, not after.
//

#if canImport(AppKit)
import SwiftUI
import AppKit
import MALCore
import MALKit

// MARK: - Chips

struct Chip: View {
    enum Style { case neutral, good, caution, bad, accent }

    var text: String
    var style: Style = .neutral
    var systemImage: String?

    private var colors: (fg: Color, bg: Color) {
        switch style {
        case .neutral: return (.secondary, Color.secondary.opacity(0.12))
        case .good:    return (.green, Color.green.opacity(0.14))
        case .caution: return (.orange, Color.orange.opacity(0.16))
        case .bad:     return (.red, Color.red.opacity(0.14))
        case .accent:  return (.accentColor, Color.accentColor.opacity(0.14))
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.caption)
        .fontWeight(.medium)
        .foregroundStyle(colors.fg)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(colors.bg, in: Capsule())
        .accessibilityLabel(text)
    }
}

extension CompatibilityTier {
    var chipStyle: Chip.Style {
        switch self {
        case .supported: return .good
        case .limited: return .caution
        case .notSupported: return .bad
        }
    }
    var symbol: String {
        switch self {
        case .supported: return "checkmark.seal"
        case .limited: return "exclamationmark.triangle"
        case .notSupported: return "xmark.octagon"
        }
    }
}

struct RunningIndicator: View {
    var running: Bool
    var body: some View {
        Circle()
            .fill(running ? Color.green : Color.secondary.opacity(0.35))
            .frame(width: 8, height: 8)
            .accessibilityLabel(running ? "Running" : "Not running")
            .help(running ? "Running" : "Not running")
    }
}

// MARK: - Icons

/// The icon macOS itself would draw for a path. For a built instance this is the
/// badged icon, which is the honest thing to show — if the badge is not there, the
/// user should see that it is not there.
struct FileIcon: View {
    var path: String
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// The icon for a managed source. The tool fallback exists only so a legacy
/// Terminal-based row remains recognisable while the user uninstalls it.
struct SourceIcon: View {
    var app: ManagedApp
    var size: CGFloat = 16

    var body: some View {
        if app.appKey.hasPrefix("tool.") {
            // A legacy Terminal launcher. Its tool is not looked for on disk — the row
            // exists so the entry can be recognised and uninstalled — so it borrows
            // Terminal's icon, which is what such an instance used to open.
            Image(nsImage: NSWorkspace.shared.icon(
                forFile: "/System/Applications/Utilities/Terminal.app"))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            FileIcon(path: app.sourcePath, size: size)
        }
    }
}

/// The icon for a creation candidate. Candidates are always GUI application bundles.
struct CandidateIcon: View {
    var facts: AppFacts
    var size: CGFloat = 32

    var body: some View {
        FileIcon(path: facts.path, size: size)
    }
}

/// Live badge preview used by the create flow and the badge editor. Renders through
/// the same IconFactory the build uses, so what is previewed is what gets built.
struct BadgePreview: View {
    var sourceIcon: NSImage
    var number: Int
    var badge: BadgeSpec
    var size: CGFloat = 96
    var factory: IconFactory

    var body: some View {
        Image(nsImage: factory.preview(sourceIcon: sourceIcon,
                                       number: number,
                                       badge: badge,
                                       pixelSize: Int(size * 2)))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityLabel("Preview of the icon for instance \(number)")
    }
}

// MARK: - Badge editor

struct BadgeEditor: View {
    @Binding var badge: BadgeSpec
    var number: Int
    var sourceIcon: NSImage
    var factory: IconFactory

    private let palette = [1, 2, 3, 4, 5, 6, 7, 8].map { BadgeSpec.suggestedColor(forNumber: $0) }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 8) {
                BadgePreview(sourceIcon: sourceIcon, number: number, badge: badge,
                             size: 104, factory: factory)
                HStack(spacing: 10) {
                    BadgePreview(sourceIcon: sourceIcon, number: number, badge: badge,
                                 size: 32, factory: factory)
                    BadgePreview(sourceIcon: sourceIcon, number: number, badge: badge,
                                 size: 16, factory: factory)
                }
                Text("Dock sizes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(palette, id: \.self) { hex in
                        Button {
                            badge.colorHex = hex
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 20, height: 20)
                                .overlay {
                                    Circle().strokeBorder(
                                        badge.colorHex == hex ? Color.primary : Color.primary.opacity(0.15),
                                        lineWidth: badge.colorHex == hex ? 2 : 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .help(hex)
                    }
                }

                Picker("Corner", selection: $badge.position) {
                    ForEach(BadgePosition.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Shape", selection: $badge.shape) {
                    ForEach(BadgeShape.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                HStack {
                    Text("Size")
                    Slider(value: Binding(get: { badge.scale },
                                          set: { badge.scale = BadgeSpec.clampScale($0) }),
                           in: 0.22...0.5)
                    .frame(width: 140)
                }
                Toggle("Outline", isOn: $badge.outlined)
                    .help("Keeps the badge visible on an icon of the same colour.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension Color {
    init(hex: String) {
        let spec = BadgeSpec(colorHex: hex)
        let (r, g, b) = spec.rgb
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

// MARK: - Compatibility card

/// Shown before anything is created. Every tier, including the good one, states the
/// Keychain and concurrent-session facts — those are properties of the approach, not
/// warnings that only apply to awkward apps.
struct CompatibilityCard: View {
    var facts: AppFacts
    var verdict: CompatibilityVerdict

    /// The condition the card's own `if` below uses. A test asserts on this rather than
    /// re-deriving it, so the two cannot drift apart.
    static func showsSharedCredentialWarning(_ verdict: CompatibilityVerdict) -> Bool {
        verdict.sharesCredentialStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                CandidateIcon(facts: facts, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(facts.displayName).font(.headline)
                    Text("\(facts.version) · \(facts.runtime.displayName) · \(FSOps.humanBytes(facts.bundleSizeBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Chip(text: verdict.tierLabel, style: verdict.tier.chipStyle,
                     systemImage: verdict.tier.symbol)
            }

            Text(verdict.headline)
                .font(.callout)
                .fontWeight(.medium)
                // The headline can be a full sentence now — an app whose Full clone
                // shares its session says so here — and a single line truncated it.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Above the reasons and above the limitations list, because for an app that
            // keeps its session outside the profile this is not a caveat on the answer —
            // it is the answer. A user reading this card is deciding whether instances
            // will give them a second account, and here they will not.
            if Self.showsSharedCredentialWarning(verdict) {
                SharedCredentialWarning(stores: verdict.sharedCredentialStores)
            }

            if !verdict.reasons.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(verdict.reasons, id: \.self) { r in
                        Label(r, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .labelStyle(BulletLabelStyle())
                    }
                }
            }

            Divider()

            Text("What will not work")
                .font(.caption)
                .fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(verdict.limitations, id: \.self) { l in
                    Label(l, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(BulletLabelStyle())
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08))
        }
    }
}

/// The one thing on the compatibility card that can make creating an instance pointless.
///
/// Kept as its own view rather than another bullet in "What will not work" because it is
/// categorically different from the rest of that list: everything else there describes
/// something that behaves differently, and this describes something that does not work
/// at all.
struct SharedCredentialWarning: View {
    var stores: [SharedCredentialStore]

    /// Every string this view puts on screen, in order.
    ///
    /// Exposed so a test can assert what the card says without depending on SwiftUI
    /// publishing an accessibility tree to an offscreen window — it does not, reliably,
    /// with no assistive client attached. The view below renders exactly these strings
    /// and nothing else, so a change to the wording changes the test.
    static func lines(for stores: [SharedCredentialStore]) -> [String] {
        guard !stores.isEmpty else { return [] }
        var lines = [title, body]
        lines.append(contentsOf: stores.map { "\($0.evidence) — \($0.consequence)" })
        if let variable = stores.compactMap(\.relocationVariable).first {
            lines.append(routeOut(variable: variable))
        }
        return lines
    }

    static let title = "These will not be separate accounts"
    static let body = "This app keeps its signed-in session outside the profile LaunchAgain redirects. Signing out of one instance may sign you out of every copy, including the original application."
    static func routeOut(variable: String) -> String {
        "There is a route out for this one: set \(variable) to the instance's own directory under Advanced → environment variables and it gets a session of its own. LaunchAgain does not set it for you — moving where an application keeps its configuration is a decision about your data."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(Self.title)
                    .font(.callout).fontWeight(.semibold)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            Text(Self.body)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(stores, id: \.evidence) { store in
                    Label {
                        Text(store.evidence).fontWeight(.medium)
                            + Text(" — " + store.consequence)
                    } icon: {
                        Image(systemName: "key.slash")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(BulletLabelStyle())
                }
            }

            if let variable = stores.compactMap(\.relocationVariable).first {
                Text(Self.routeOut(variable: variable))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35))
        }
    }
}

struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.imageScale(.small).frame(width: 12)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Banner

struct BannerView: View {
    var banner: AppState.Banner
    var dismiss: () -> Void

    private var tint: Color {
        switch banner.kind {
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        }
    }
    private var symbol: String {
        switch banner.kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(banner.title).font(.callout).fontWeight(.semibold)
                Text(banner.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                ForEach(banner.details, id: \.self) { d in
                    Text(d)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").imageScale(.small)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.25)) }
    }
}

// MARK: - Activity

struct ActivityOverlay: View {
    var activity: AppState.Activity

    var body: some View {
        VStack(spacing: 12) {
            if let f = activity.fraction {
                ProgressView(value: f).frame(width: 220)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(activity.title).font(.headline)
            Text(activity.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
    }
}

// MARK: - Section helpers

struct FieldRow<Content: View>: View {
    var label: String
    var help: String?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .trailing)
            content
        }
        .help(help ?? "")
    }
}

struct KeyValueRow: View {
    var key: String
    var value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .trailing)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
#endif
