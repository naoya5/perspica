import SwiftUI

extension View {
    /// The brief 「コピーしました」 mark after a copy. `copied` turns on with
    /// each bump of `count` (a surface's `copyCount`) and off 1.2 seconds after
    /// the last bump, whether the copy came from the button or the shortcut.
    func copiedMark(count: Int, copied: Binding<Bool>) -> some View {
        modifier(CopiedMark(count: count, copied: copied))
    }
}

/// The mark turns on in the same update as the copy, so it shows on the frame
/// of the click or key. The wait is a `.task(id:)`: SwiftUI cancels it when
/// the count moves on or the view goes away, so a second copy restarts the 1.2
/// seconds instead of being cut short by the first copy's wait.
private struct CopiedMark: ViewModifier {
    var count: Int
    @Binding var copied: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: count) { old, new in
                guard new > old else { return }
                withAnimation(.snappy(duration: 0.25)) { copied = true }
            }
            .task(id: count) {
                do {
                    try await Task.sleep(for: .seconds(1.2))
                } catch {
                    return
                }
                withAnimation(.snappy(duration: 0.25)) { copied = false }
            }
    }
}
