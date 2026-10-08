import SwiftUI

struct DisplayRowView: View {
    @Environment(DisplayManagerViewModel.self) private var viewModel
    @Environment(LocaleManager.self) private var locale
    let display: DisplayInfo

    private var isConfiguring: Bool {
        viewModel.navigationState == .configuringDisplay(display.id)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Configure button (virtual displays only)
            if display.isVirtual {
                Button {
                    if isConfiguring {
                        viewModel.navigate(to: .displayList)
                    } else {
                        viewModel.navigate(to: .configuringDisplay(display.id))
                    }
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.callout)
                        .foregroundStyle(isConfiguring ? .blue : .secondary)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isBusy || viewModel.isNavigating)
            }

            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if display.isMain {
                        BadgeView(text: locale.t("badge_main"), color: .blue)
                    } else if display.isActive && !display.isVirtual {
                        Button {
                            viewModel.setAsMainDisplay(display)
                        } label: {
                            BadgeView(text: locale.t("badge_set_main"), color: .secondary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(viewModel.isBusy)
                    }
                    Text(verbatim: display.name)
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundStyle(display.isActive ? .primary : .secondary)
                    if display.isVirtual {
                        BadgeView(text: locale.t("badge_virtual"), color: .purple)
                    }
                    if !display.isActive {
                        BadgeView(text: locale.t("badge_disabled"), color: .orange)
                    }
                }
                if !display.isPlaceholder {
                    Text(verbatim: display.currentMode.localizedResolutionString(locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if display.isGhost {
                Button {
                    viewModel.forgetDisabledDisplay(display)
                } label: {
                    if display.isPlaceholder {
                        Text(verbatim: locale.t("clear_display_short"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.borderless)
                .help(locale.t("clear_display_help"))
                .accessibilityLabel(locale.t("clear_display"))
                .disabled(viewModel.isBusy)
            }

            // Placeholder ghosts have no live display to toggle; enable is on
            // the right-click menu. Live and still-remembered disabled rows
            // keep the switch so they can be turned back on directly.
            if !display.isGhost || !display.isPlaceholder {
                Toggle("", isOn: Binding(
                    get: { display.isActive },
                    set: { _ in viewModel.toggleDisplay(display) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(viewModel.isBusy || (display.isActive && viewModel.activeDisplays.count <= 1))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(display.isActive ? 0.5 : 0.25))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
        .opacity(display.isActive ? 1.0 : 0.7)
        .modifier(GhostRowContextMenu(
            isGhost: display.isGhost,
            enableTitle: locale.t("enable_display"),
            clearTitle: locale.t("clear_display"),
            isBusy: viewModel.isBusy,
            onEnable: { viewModel.toggleDisplay(display) },
            onClear: { viewModel.forgetDisabledDisplay(display) }
        ))
    }

    private var iconName: String {
        if display.isVirtual { return "rectangle.dashed" }
        if display.isBuiltIn { return "laptopcomputer" }
        return "display"
    }

    private var iconColor: Color {
        if !display.isActive { return .gray }
        if display.isVirtual { return .purple }
        return .blue
    }
}

/// Applies a right-click menu only on remembered (ghost) disabled rows, so
/// active rows don't swallow clicks into an empty menu.
private struct GhostRowContextMenu: ViewModifier {
    let isGhost: Bool
    let enableTitle: String
    let clearTitle: String
    let isBusy: Bool
    let onEnable: () -> Void
    let onClear: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isGhost {
            content.contextMenu {
                Button(enableTitle, action: onEnable)
                    .disabled(isBusy)
                Button(clearTitle, role: .destructive, action: onClear)
                    .disabled(isBusy)
            }
        } else {
            content
        }
    }
}

struct BadgeView: View {
    let text: String
    let color: Color

    var body: some View {
        Text(verbatim: text)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
