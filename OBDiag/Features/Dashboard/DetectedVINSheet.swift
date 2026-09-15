import SwiftUI

/// Automatic vehicle detection: the adapter reported a VIN that doesn't match
/// the selected vehicle. Decode it and switch or create.
struct DetectedVINSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let vin: String

    @State private var decoded: DecodedVehicle?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var createdVehicle: Vehicle?

    var body: some View {
        SheetNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("VIN reported by the vehicle", systemImage: "car.badge.gearshape")
                            .font(.obHeadline)
                            .foregroundStyle(Palette.textPrimary)
                        Text(vin)
                            .obMono(17, weight: .semibold)
                            .foregroundStyle(Palette.accent)
                            .textSelection(.enabled)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel()

                    if isLoading {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Decoding with the NHTSA vehicle database…")
                                .font(.obCallout)
                                .foregroundStyle(Palette.textSecondary)
                        }
                        .padding(14)
                        .panel()
                    } else if let decoded, decoded.isValid {
                        VStack(alignment: .leading, spacing: 9) {
                            detailRow("Year", decoded.year.map(String.init))
                            detailRow("Make", decoded.make)
                            detailRow("Model", decoded.model)
                            detailRow("Trim", decoded.trimName)
                            detailRow("Engine", decoded.engineDescription)
                            detailRow("Fuel", decoded.fuelType)
                        }
                        .padding(14)
                        .panel()

                        actions(for: decoded)
                    } else if let errorMessage {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Couldn't decode this VIN", systemImage: "exclamationmark.triangle.fill")
                                .font(.obHeadline)
                                .foregroundStyle(Palette.amber)
                            Text(errorMessage)
                                .font(.obCaption)
                                .foregroundStyle(Palette.textSecondary)
                            Button("Try again") { Task { await decode() } }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                        }
                        .padding(14)
                        .panel()
                    }
                }
                .padding(18)
                .padding(.bottom, 30)
            }
            .transparentSheetContent()
            .navigationTitle("Vehicle detected")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Not now") {
                        env.obd.dismissVINPrompt()
                        dismiss()
                    }
                }
            }
        }
        .task { await decode() }
    }

    @ViewBuilder
    private func actions(for decoded: DecodedVehicle) -> some View {
        VStack(spacing: 10) {
            if let current = env.garage.selectedVehicle, !current.isDirectConnection {
                GlassActionButton(title: "Update \(current.displayName)", systemImage: "arrow.triangle.2.circlepath") {
                    env.garage.applyDecodedVIN(decoded, to: current.id)
                    Haptics.success()
                    env.obd.dismissVINPrompt()
                    dismiss()
                }
            }

            GlassActionButton(
                title: env.garage.selectedVehicle?.isDirectConnection == true ? "Create this vehicle" : "Add as new vehicle",
                systemImage: "plus",
                tint: Palette.accent
            ) {
                create(from: decoded)
            }

            if createdVehicle != nil {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success)
                    Text("Added to your garage")
                        .font(.obCaption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
    }

    private func detailRow(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.obCaption)
                .foregroundStyle(Palette.textTertiary)
                .frame(width: 70, alignment: .leading)
            Text(value?.isEmpty == false ? value! : "—")
                .font(.obCallout)
                .foregroundStyle(Palette.textPrimary)
            Spacer()
        }
    }

    private func decode() async {
        isLoading = true
        errorMessage = nil
        do {
            decoded = try await env.catalog.decode(vin: vin)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func create(from decoded: DecodedVehicle) {
        var vehicle = Vehicle(
            nickname: "",
            year: decoded.year,
            make: decoded.make ?? "Unknown",
            model: decoded.model ?? "Vehicle",
            trim: decoded.trimName,
            vin: decoded.vin,
            engineDescription: decoded.engineDescription,
            fuelType: decoded.fuelType,
            bodyClass: decoded.bodyClass,
            driveType: decoded.driveType
        )
        vehicle.createdAt = Date()
        let added = env.garage.add(vehicle)
        env.garage.select(added.id)
        createdVehicle = added
        env.obd.dismissVINPrompt()
        Haptics.success()
        dismiss()
    }
}
