import SwiftUI

/// The focused feedback gallery uses the same morphing shell as production.
struct FeedbackIslandView: View {
    @ObservedObject var controller: FeedbackController
    var maximumHeight: CGFloat = 680
    @StateObject private var activity = ActivityOverlayModel()

    var body: some View {
        VoxaIslandView(activity: activity, feedback: controller, maximumHeight: maximumHeight)
    }
}
