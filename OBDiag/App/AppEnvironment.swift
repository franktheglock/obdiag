import Foundation
import Observation
import UIKit

/// Composition root. Views read services from the environment; nothing else
/// constructs them.
@MainActor
@Observable
final class AppEnvironment {
    let settings: AppSettings
    let garage: GarageStore
    let conversations: ConversationStore
    let credits: CreditLedger
    let subscriptions: SubscriptionStore
    let search: SearchService
    let obd: OBDSession
    let chat: ChatEngine
    let catalog: VehicleCatalogClient

    /// Cross-feature navigation requests handled by `RootView`.
    var requestedSection: AppSection?
    /// Text to send automatically when the chat opens (e.g. from a DTC detail).
    var pendingChatPrompt: String?
    /// Photos handed to the composer by another feature or a debug hook.
    var pendingAttachments: [MessageAttachment] = []

    init() {
        let settings = AppSettings()
        let garage = GarageStore()
        let conversations = ConversationStore()
        let credits = CreditLedger()
        let search = SearchService(settings: settings)
        let obd = OBDSession(settings: settings, garage: garage)
        let chat = ChatEngine(
            settings: settings,
            garage: garage,
            conversations: conversations,
            credits: credits,
            obd: obd,
            search: search
        )
        let subscriptions = SubscriptionStore(credits: credits)

        self.settings = settings
        self.garage = garage
        self.conversations = conversations
        self.credits = credits
        self.search = search
        self.obd = obd
        self.chat = chat
        self.subscriptions = subscriptions
        self.catalog = VehicleCatalogClient()

        chat.planProvider = { [weak subscriptions] in subscriptions?.plan ?? .free }

        // Tidy up attachment files that no message references any more. Disk
        // I/O, so it stays off the launch path.
        let referenced = Set(conversations.conversations.flatMap { $0.messages.flatMap(\.attachments) }.map(\.fileName))
        Task.detached(priority: .utility) {
            AttachmentStore.prune(referencedFileNames: referenced)
        }

        #if DEBUG
        applyLaunchArguments()
        #endif
    }

    #if DEBUG
    /// Debug-only launch hooks used by UI verification:
    /// `-uiDemo` seeds a garage/demo vehicle, `-startSection chat|dashboard|garage|settings`
    /// selects a tab, and `-demoAdapter` connects the simulated adapter.
    private func applyLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-resetOnboarding") {
            settings.resetOnboarding()
            if arguments.count == 1 { return }
        }

        let hasDemo = arguments.contains("-uiDemo")
        guard hasDemo
            || arguments.contains("-demoAdapter")
            || arguments.contains("-attachDemoImage")
            || arguments.contains(where: { $0.hasPrefix("-startSection") })
        else { return }

        if hasDemo {
            settings.onboardingComplete = true
            if !garage.hasVehicles {
                let vehicle = Vehicle(
                    nickname: "Daily driver",
                    year: 2018, make: "Honda", model: "Civic", trim: "EX-L",
                    vin: "1HGCM82633A004352", engineDescription: "1.5L 4-cyl turbo", fuelType: "Gasoline"
                )
                garage.add(vehicle)
            }
        }

        if arguments.contains("-demoAdapter") || hasDemo {
            Task { await obd.connectDemo() }
        }

        if let sectionArgument = arguments.first(where: { $0.hasPrefix("-startSection=") }) {
            let raw = sectionArgument.replacingOccurrences(of: "-startSection=", with: "")
            if let section = AppSection(rawValue: raw) {
                requestedSection = section
            }
        }

        if let promptArgument = arguments.first(where: { $0.hasPrefix("-autoPrompt=") }) {
            pendingChatPrompt = promptArgument.replacingOccurrences(of: "-autoPrompt=", with: "")
            requestedSection = .chat
        }

        if arguments.contains("-attachDemoImage"), let attachment = makeDemoAttachment() {
            pendingAttachments = [attachment]
            if pendingChatPrompt == nil, let promptArgument = arguments.first(where: { $0.hasPrefix("-autoPrompt=") }) {
                pendingChatPrompt = promptArgument.replacingOccurrences(of: "-autoPrompt=", with: "")
            }
            requestedSection = .chat
        }
    }

    /// Draws a plausible "check engine" dashboard photo for screenshot/UI
    /// verification of the attachment pipeline.
    private func makeDemoAttachment() -> MessageAttachment? {
        let size = CGSize(width: 900, height: 620)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(white: 0.05, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let centerX = size.width / 2
            let triangle = UIBezierPath()
            triangle.move(to: CGPoint(x: centerX, y: 90))
            triangle.addLine(to: CGPoint(x: centerX + 180, y: 400))
            triangle.addLine(to: CGPoint(x: centerX - 180, y: 400))
            triangle.close()
            UIColor(red: 1.0, green: 0.72, blue: 0.08, alpha: 1).setFill()
            triangle.fill()

            let stem = UIBezierPath(roundedRect: CGRect(x: centerX - 16, y: 190, width: 32, height: 120), cornerRadius: 16)
            UIColor(white: 0.05, alpha: 1).setFill()
            stem.fill()
            let dot = UIBezierPath(ovalIn: CGRect(x: centerX - 17, y: 330, width: 34, height: 34))
            dot.fill()

            let caption = "CHECK ENGINE" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 58, weight: .heavy),
                .foregroundColor: UIColor.white
            ]
            let textSize = caption.size(withAttributes: attributes)
            caption.draw(at: CGPoint(x: centerX - textSize.width / 2, y: 450), withAttributes: attributes)

            let subtitle = "photo attached for verification" as NSString
            let subtitleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 28, weight: .medium),
                .foregroundColor: UIColor(white: 0.7, alpha: 1)
            ]
            let subtitleSize = subtitle.size(withAttributes: subtitleAttributes)
            subtitle.draw(at: CGPoint(x: centerX - subtitleSize.width / 2, y: 530), withAttributes: subtitleAttributes)
        }
        return AttachmentStore.save(image)
    }
    #endif

    // MARK: Convenience

    /// The conversation shown in the chat tab for the selected vehicle,
    /// creating one lazily.
    func activeConversationID(createIfNeeded: Bool = true) -> UUID? {
        let vehicleID = garage.selectedVehicleID
        if let existing = conversations.conversations(for: vehicleID).first {
            return existing.id
        }
        guard createIfNeeded else { return nil }
        let conversation = conversations.create(for: garage.selectedVehicle, modelID: chat.selectedModel.id)
        return conversation.id
    }

    func startFreshConversation() -> UUID {
        let conversation = conversations.create(for: garage.selectedVehicle, modelID: chat.selectedModel.id)
        chat.modelOverride = nil
        return conversation.id
    }
}
