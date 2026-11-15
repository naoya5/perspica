import SwiftUI

/// The poses of Polly, the mascot, that the app shows (SPEC 6.6). Each is a
/// picture in `Resources/Polly.xcassets` under `Polly/<rawValue>`.
enum PollyPose: String {
    /// Waving: the first page of the onboarding.
    case wave
    /// Pointing to the right: the onboarding page about the menu bar.
    case point
    /// Asleep: the empty history.
    case sleep
}

/// Polly in one pose. It springs in once when it appears and then stands
/// still, so an open window that shows it costs no CPU (SPEC 14): a
/// continuously redrawn mascot measured 17-18% on the empty history page.
/// With Reduce Motion it fades in instead (SPEC 6.5).
struct PollyImage: View {
    var pose: PollyPose

    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image("Polly/\(pose.rawValue)")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .scaleEffect(shown || reduceMotion ? 1 : 0.86, anchor: .bottom)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.8)) {
                    shown = true
                }
            }
            // A picture: the text beside it says everything, so VoiceOver skips it.
            .accessibilityHidden(true)
    }
}
