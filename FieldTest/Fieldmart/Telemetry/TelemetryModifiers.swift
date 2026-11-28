import SwiftUI
import UIKit
#if FM_SDK
import Traceway
#endif

// SwiftUI sides of the telemetry seam. In the `off` build each one is only
// the accessibility identifier (or nothing).

extension View {
    /// The automation id (`accessibilityIdentifier`) and, with the SDK, the
    /// name recorded taps carry (`tracewayIdentifier`): SwiftUI controls
    /// have no views of their own, so the SDK cannot read the identifier.
    @ViewBuilder
    func fmID(_ id: String) -> some View {
        #if FM_SDK
        self.accessibilityIdentifier(id).tracewayIdentifier(id)
        #else
        self.accessibilityIdentifier(id)
        #endif
    }

    /// Hides this view in session replays (`tracewayMask`).
    @ViewBuilder
    func fmMask(_ mode: FMMaskMode) -> some View {
        #if FM_SDK
        switch mode {
        case .blur: self.tracewayMask(.blur)
        case .blank: self.tracewayMask(.blank())
        }
        #else
        self
        #endif
    }

    /// Names this SwiftUI screen for the SDK (`tracewayScreen`) and writes
    /// the `FM_SCREEN` marker and the `FM log <n>` line when it appears.
    func fmScreen(_ name: String) -> some View {
        modifier(FMScreenModifier(name: name))
    }

    /// A container element with an automation id that keeps its children
    /// visible to UI automation.
    func fmContainer(_ id: String) -> some View {
        accessibilityElement(children: .contain).accessibilityIdentifier(id)
    }
}

private struct FMScreenModifier: ViewModifier {
    let name: String

    func body(content: Content) -> some View {
        tracked(content).onAppear { AppEnvironment.shared.screenAppeared(name) }
    }

    @ViewBuilder
    private func tracked(_ content: Content) -> some View {
        #if FM_SDK
        content.tracewayScreen("/" + name)
        #else
        content
        #endif
    }
}
