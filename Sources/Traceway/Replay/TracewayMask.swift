#if canImport(UIKit)
import UIKit
#if canImport(SwiftUI)
import SwiftUI
#endif

/// How a traceway mask hides a view in session replays. The app itself shows
/// no change.
public enum TracewayMaskMode {
    /// The layout stays; text becomes `*` and images placeholders.
    case blur
    /// A box of this color; nothing inside the view is recorded.
    case blank(color: UIColor = .black)
}

/// The `accessibilityIdentifier` that masks a UIKit view like `.blur`
/// without code (in Interface Builder too): the marker the browser has as a
/// CSS class, Android as a view tag and Flutter as a key.
let tracewayMaskMarker = "traceway-mask"
/// The `accessibilityIdentifier` that masks a UIKit view like `.blank()`.
let tracewayBlankMarker = "traceway-blank"

/// Whether an accessibility identifier is a mask marker rather than a name.
func isTracewayMaskMarker(_ identifier: String?) -> Bool {
    identifier == tracewayMaskMarker || identifier == tracewayBlankMarker
}

private var tracewayMaskKey: UInt8 = 0

private final class MaskBox {
    let mode: TracewayMaskMode
    init(_ mode: TracewayMaskMode) { self.mode = mode }
}

public extension UIView {
    /// Hides this view and everything inside it in session replays, and keeps
    /// its text out of recorded taps. Secure text fields are always masked.
    /// Without code, `accessibilityIdentifier = "traceway-mask"` masks a view
    /// like `.blur` and `"traceway-blank"` like `.blank()`.
    var tracewayMask: TracewayMaskMode? {
        get { (objc_getAssociatedObject(self, &tracewayMaskKey) as? MaskBox)?.mode }
        set {
            objc_setAssociatedObject(
                self, &tracewayMaskKey, newValue.map(MaskBox.init), .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    @available(*, deprecated, renamed: "tracewayMask")
    var tracewayPrivacyMask: TracewayMaskMode? {
        get { tracewayMask }
        set { tracewayMask = newValue }
    }
}

extension UIView {
    /// The mask on this view: `tracewayMask`, else the one its
    /// `accessibilityIdentifier` marker names.
    var maskInEffect: TracewayMaskMode? {
        if let mode = tracewayMask { return mode }
        let identifier = accessibilityIdentifier
        if identifier == tracewayMaskMarker { return .blur }
        if identifier == tracewayBlankMarker { return .blank() }
        return nil
    }
}

/// The view a SwiftUI `tracewayMask` modifier puts over its content.
/// SwiftUI draws most content without views of its own, so the recorder
/// masks whatever lies under this view's frame.
final class TracewayMaskMarkerView: UIView {
    init(mode: TracewayMaskMode) {
        super.init(frame: .zero)
        tracewayMask = mode
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
        view.tracewayMask = mode
    }
}

@available(iOS 13.0, *)
public extension View {
    /// Hides this view in session replays: `.blur` keeps its layout and
    /// replaces its text with `*`, `.blank()` draws a box over it. (SwiftUI's
    /// `accessibilityIdentifier` is not readable from the view hierarchy, so
    /// SwiftUI masks with this modifier, not the identifier marker.)
    func tracewayMask(_ mode: TracewayMaskMode = .blur) -> some View {
        overlay(TracewayMaskMarker(mode: mode).allowsHitTesting(false))
    }

    @available(*, deprecated, renamed: "tracewayMask(_:)")
    func tracewayPrivacyMask(_ mode: TracewayMaskMode = .blur) -> some View {
        tracewayMask(mode)
    }
}
#endif
#endif
