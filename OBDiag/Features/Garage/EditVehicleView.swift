import SwiftUI

/// Edit an existing vehicle: identity, VIN decode, mechanical details, notes,
/// and removal.
struct EditVehicleView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let vehicle: Vehicle

    @State private var draft: VehicleDraft
    @State private var isDecoding = false
    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false

    init(vehicle: Vehicle) {
        self.vehicle = vehicle
        var draft = VehicleDraft()
        draft.year = vehicle.year
        draft.make = vehicle.make
        draft.model = vehicle.model
        draft.trim = vehicle.trim ?? ""
        draft.vin = vehicle.vin ?? ""
        draft.engine = vehicle.engineDescription ?? ""
        draft.fuelType = vehicle.fuelType ?? ""
        draft.nickname = vehicle.nickname
        draft.notes = vehicle.notes
        _draft = State(initialValue: draft)
    }

    var body: some View {
        SheetNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    identitySection
                    vinSection
                    if let date = vehicle.lastConnectedAt {
                        HStack(spacing: 8) {
                            Image(systemName: "clock")
                            Text("Last connected \(Format.relative(date))")
                            Spacer()
                        }
                        .font(.obCaption)
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.horizontal, 4)
                    }
                    dangerZone
                }
                .padding(18)
                .padding(.bottom, 30)
            }
            .transparentSheetContent()
            .navigationTitle("Edit vehicle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(draft.make.isBlank)
                }
            }
            .confirmationDialog("Remove this vehicle?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    env.garage.remove(vehicle.id)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The vehicle and its fault-code history are removed from this device.")
            }
        }
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Identity")
                .font(.obCaption.weight(.semibold))
                .foregroundStyle(Palette.textTertiary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 13) {
                LabeledField(label: "Nickname", placeholder: "e.g. Family hauler", text: $draft.nickname)
                LabeledField(label: "Year", placeholder: "2018", text: Binding(
                    get: { draft.year.map(String.init) ?? "" },
                    set: { draft.year = Format.normalizeYear($0) }
                ), keyboard: .numberPad)
                LabeledField(label: "Make", placeholder: "Honda", text: $draft.make)
                LabeledField(label: "Model", placeholder: "Civic", text: $draft.model)
                LabeledField(label: "Trim", placeholder: "EX-L", text: $draft.trim)
                LabeledField(label: "Engine", placeholder: "1.5L 4-cyl turbo", text: $draft.engine)
                LabeledField(label: "Fuel", placeholder: "Gasoline", text: $draft.fuelType)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Notes")
                        .font(.obMicro)
                        .foregroundStyle(Palette.textTertiary)
                    TextField("Modifications, known issues, recent work…", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...6)
                        .font(.obCallout)
                }
            }
            .padding(14)
            .panel(cornerRadius: 14)
        }
    }

    private var vinSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VIN")
                .font(.obCaption.weight(.semibold))
                .foregroundStyle(Palette.textTertiary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 12) {
                TextField("17-character VIN", text: $draft.vin)
                    .font(.obMono(16, weight: .medium))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onChange(of: draft.vin) { _, newValue in
                        draft.vin = String(newValue.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(17))
                    }

                HStack(spacing: 10) {
                    Button {
                        decodeVIN()
                    } label: {
                        Label("Decode & fill", systemImage: "wand.and.stars")
                            .font(.obCaption.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .disabled(!Vehicle.isPlausibleVIN(draft.vin) || isDecoding)

                    if isDecoding {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.obCaption)
                        .foregroundStyle(Palette.amber)
                }

                if env.obd.isConnected {
                    Button {
                        readFromVehicle()
                    } label: {
                        Label("Read VIN from connected vehicle", systemImage: "bolt.horizontal")
                            .font(.obCaption.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(14)
            .panel(cornerRadius: 14)
        }
    }

    private var dangerZone: some View {
        Button(role: .destructive) {
            showDeleteConfirmation = true
        } label: {
            Label("Remove vehicle", systemImage: "trash")
                .font(.obCallout.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
        }
        .buttonStyle(.glass)
        .tint(Palette.danger)
    }

    // MARK: Actions

    private func save() {
        var updated = vehicle
        updated.nickname = draft.nickname.trimmed
        updated.year = draft.year
        updated.make = draft.make.trimmed
        updated.model = draft.model.trimmed
        updated.trim = draft.trim.trimmed.isEmpty ? nil : draft.trim.trimmed
        updated.vin = draft.vin.trimmed.isEmpty ? nil : draft.vin.trimmed.uppercased()
        updated.engineDescription = draft.engine.trimmed.isEmpty ? nil : draft.engine.trimmed
        updated.fuelType = draft.fuelType.trimmed.isEmpty ? nil : draft.fuelType.trimmed
        updated.notes = draft.notes
        env.garage.update(updated)
        Haptics.success()
        dismiss()
    }

    private func decodeVIN() {
        isDecoding = true
        errorMessage = nil
        Task {
            do {
                let decoded = try await env.catalog.decode(vin: draft.vin)
                draft.apply(decoded)
            } catch {
                errorMessage = error.localizedDescription
            }
            isDecoding = false
        }
    }

    private func readFromVehicle() {
        isDecoding = true
        errorMessage = nil
        Task {
            if let vin = await env.obd.readVIN(force: true) {
                draft.vin = vin
                do {
                    draft.apply(try await env.catalog.decode(vin: vin))
                } catch {
                    errorMessage = "Read \(vin), but decoding failed: \(error.localizedDescription)"
                }
            } else {
                errorMessage = env.obd.vinStatus.message ?? "No VIN was reported."
            }
            isDecoding = false
        }
    }
}
