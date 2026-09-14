import Foundation
import FirebaseCore
import FirebaseAppCheck
import DeviceCheck

/// Release App Check provider: App Attest on supported hardware, with
/// DeviceCheck as the fallback for devices that can't attest.
///
/// App Attest requires the "App Attest" capability to be enabled in the Apple
/// Developer portal for this bundle id.
final class OBDiagAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        if #available(iOS 14.0, *) {
            return AppAttestProvider(app: app)
        }
        return DeviceCheckProvider(app: app)
    }
}
