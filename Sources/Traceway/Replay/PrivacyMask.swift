#if canImport(UIKit)
import UIKit
#if canImport(SwiftUI)
import SwiftUI
#endif

/// How a privacy mask hides a view in session replays. The app itself shows
/// no change.
public enum TracewayMaskMode {
    /// The layout stays; text becomes `*` and images placeholders.
    case blur
    /// A box of this color; nothing inside the view is recorded.
    case blank(color: UIColor = .black)
}

private var tracewayMaskKey: UInt8 = 0

private final class MaskBox {
    let mode: TracewayMaskMode
    init(_ mode: TracewayMaskMode) { self.mode = mode }
}

public extension UIView {
    /// Hides this view and everything inside it in session replays, and keeps
    /// its text out of recorded taps. Secure text fields are always masked.
    var tracewayPrivacyMask: TracewayMaskMode? {
        get { (objc_getAssociatedObject(self, &tracewayMaskKey) as? MaskBox)?.mode }
        set {
            objc_setAssociatedObject(
                self, &tracewayMaskKey, newValue.map(MaskBox.init), .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}

/// The view a SwiftUI `tracewayPrivacyMask` modifier puts over its content.
/// SwiftUI draws most content without views of its own, so the recorder
/// masks whatever lies under this view's frame.
final class TracewayMaskMarkerView: UIView {
    init(mode: TracewayMaskMode) {
        super.init(frame: .zero)
        tracewayPrivacyMask = mode
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

#if canImport(SwiftUI)
@available(iOS 13.0, *)
private struct TracewayMaskMarker: UIViewRepresentable {
    let mode: TracewayMaskMode

    func makeUIView(context: Context) -> TracewayMaskMarkerView {
        TracewayMaskMarkerView(mode: mode)
    }

    func updateUIView(_ view: TracewayMaskMarkerView, context: Context) {
        view.tracewayPrivacyMask = mode
    }
}

@available(iOS 13.0, *)
public extension View {
    /// Hides this view in session replays: `.blur` keeps its layout and
    /// replaces its text with `*`, `.blank()` draws a box over it.
    func tracewayPrivacyMask(_ mode: TracewayMaskMode = .blur) -> some View {
        overlay(TracewayMaskMarker(mode: mode).allowsHitTesting(false))
    }
}
#endif
#endif
