import AppKit
import SwiftUI

/// Shared native typography and spacing for Settings and the learning workspace.
enum VoxaAppearance {
    static let pageTitle = Font.title2.weight(.semibold)
    static let contentPadding: CGFloat = 24
    static let sidebarWidth: CGFloat = 232
    static let sidebarRowHeight: CGFloat = 32
    static let sidebarIconSize: CGFloat = 20
}

/// Unboxed, monochrome SF Symbols inspired by the Apple Books sidebar.
struct VoxaSidebarLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let symbol: String
    var count: Int? = nil
    var isSelected = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .symbolVariant(.none)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isSelected ? Color.white : Color(nsColor: .secondaryLabelColor))
                .frame(width: VoxaAppearance.sidebarIconSize, height: VoxaAppearance.sidebarIconSize)
                .accessibilityHidden(true)
            Text(title).font(.body.weight(isSelected ? .semibold : .regular)).lineLimit(1)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            Spacer(minLength: 0)
            if let count {
                Text(count, format: .number).font(.caption).monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: VoxaAppearance.sidebarRowHeight - 8, alignment: .leading)
        .listRowInsets(EdgeInsets(top: 4, leading: 3, bottom: 4, trailing: 8))
        .listItemTint(.monochrome)
        .listRowBackground(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? Color(white: colorScheme == .dark ? 0.30 : 0.15) : Color.clear)
            .padding(.horizontal, 10))
        .accessibilityElement(children: .combine)
    }
}

private struct VoxaSidebarStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listStyle(.sidebar)
            .environment(\.sidebarRowSize, .medium)
            .environment(\.defaultMinListRowHeight, VoxaAppearance.sidebarRowHeight)
            .font(.body)
            .navigationSplitViewColumnWidth(min: 210, ideal: VoxaAppearance.sidebarWidth, max: 280)
    }
}

extension View {
    func voxaSidebarStyle() -> some View {
        modifier(VoxaSidebarStyle())
    }

    func voxaSettingsFormStyle() -> some View {
        formStyle(.grouped).scrollContentBackground(.hidden)
    }
}
