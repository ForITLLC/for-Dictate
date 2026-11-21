#if DEBUG
import SwiftUI
import UIKit

/// The keyboard's own view, drawn inside the app for the device matrix.
///
/// iOS runs a keyboard extension in its own process, inside whichever app is being typed in,
/// and a screenshot run of this app cannot reach it there. So a Debug build of the app compiles
/// the keyboard's view controller too (ios/project.yml) and stands it where a keyboard sits:
/// full width, at the bottom, under a line of typed text.
///
/// This shows the keyboard's layout and its states at every text size. It does not show the
/// extension loading in another app, Full Access, or the hop to this app: those need a phone.
/// The grey behind the keys stands in for the backdrop iOS draws behind a real keyboard.
struct KeyboardPreviewScene: View {
    let state: DictateKeyboardViewController.Preview

    var body: some View {
        VStack(spacing: 0) {
            Text(ScreenshotScene.sampleText)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding()
            HostedKeyboard(state: state)
                .background(Color(uiColor: .secondarySystemBackground).ignoresSafeArea(edges: .bottom))
        }
    }
}

private struct HostedKeyboard: UIViewControllerRepresentable {
    let state: DictateKeyboardViewController.Preview

    func makeUIViewController(context: Context) -> DictateKeyboardViewController {
        let controller = DictateKeyboardViewController()
        controller.preview = state
        return controller
    }

    func updateUIViewController(_ controller: DictateKeyboardViewController, context: Context) {}

    /// The height the keyboard asks iOS for: 250 points, or more when the text size needs it.
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController controller: DictateKeyboardViewController,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let fitted = controller.view.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: width, height: fitted.height)
    }
}
#endif
