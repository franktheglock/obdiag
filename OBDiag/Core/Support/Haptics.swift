import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Light haptic vocabulary. Every generator is fire-and-forget; failures are
/// silently ignored on devices without a taptic engine / in the simulator.
enum Haptics {
    static var isEnabled: Bool = true

    static func tap() {
        #if canImport(UIKit)
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    static func soft() {
        #if canImport(UIKit)
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        #endif
    }

    static func heavy() {
        #if canImport(UIKit)
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        #endif
    }

    static func success() {
        #if canImport(UIKit)
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    static func warning() {
        #if canImport(UIKit)
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    static func error() {
        #if canImport(UIKit)
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }

    static func selection() {
        #if canImport(UIKit)
        guard isEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }
}
