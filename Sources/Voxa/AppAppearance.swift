import AppKit
import SwiftUI

enum VoxaAppearance {
    static let blue = Color(nsColor: .systemBlue)
}

/// Compact sidebar labels share macOS Settings' icon and text proportions.
struct VoxaSidebarLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        Label {
            Text(title).font(.system(size: 13))
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(VoxaAppearance.blue, in: RoundedRectangle(cornerRadius: 4))
        }
    }
}
