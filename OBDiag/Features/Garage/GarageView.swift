import SwiftUI

/// The user's collection of vehicles. Everything else is scoped to a selection
/// made here.
struct GarageView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showAddVehicle = false
    @State private var editingVehicle: Vehicle?
    @State private var vehiclePendingDeletion: Vehicle?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    garageHeader

                    if env.garage.vehicles.isEmpty {
                        emptyState
                    } else {
                        ForEach(env.garage.vehicles) { vehicle in
                            VehicleCard(
                                vehicle: vehicle,
                                isSelected: env.garage.selectedVehicleID == vehicle.id,
                                isLive: isLive(vehicle),
                                faultCount: vehicle.lastKnownCodes.count,
                                onSelect: { select(vehicle) },
                                onOpen: { open(vehicle) },
                                onEdit: { editingVehicle = vehicle },
                                onDelete: { vehiclePendingDeletion = vehicle }
                            )
                        }
                        directConnectionCard
                    }

                    if !env.garage.vehicles.isEmpty {
                        addVehicleButton
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .screenBackground()
            .navigationTitle("Garage")
            .navigationSubtitle(summary)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        showAddVehicle = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add vehicle")
                }
            }
            .sheet(isPresented: $showAddVehicle) {
                AddVehicleFlow()
            }
            .sheet(item: $editingVehicle) { vehicle in
                EditVehicleView(vehicle: vehicle)
            }
            .confirmationDialog(
                "Remove \(vehiclePendingDeletion?.displayName ?? "vehicle")?",
                isPresented: Binding(
                    get: { vehiclePendingDeletion != nil },
                    set: { if !$0 { vehiclePendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let vehicle = vehiclePendingDeletion {
                        env.garage.remove(vehicle.id)
                        Haptics.warning()
                    }
                    vehiclePendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { vehiclePendingDeletion = nil }
            } message: {
                Text("This removes the vehicle and its place in the garage. Conversations stay on this device.")
            }
        }
    }

    // MARK: Sections

    /// The title and summary live in the navigation bar; this row only
    /// surfaces the fault total when there is one to act on.
    @ViewBuilder
    private var garageHeader: some View {
        if env.garage.totalFaultCount > 0 {
            Label(
                "\(env.garage.totalFaultCount) fault code\(env.garage.totalFaultCount == 1 ? "" : "s") across your garage",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.obCaption)
            .foregroundStyle(Palette.textSecondary, Palette.amber)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    private var summary: String {
        let count = env.garage.vehicles.count
        if count == 0 { return "Add a vehicle to get vehicle-specific answers." }
        let name = env.obd.adapterInfo?.name
        if let name, env.obd.isConnected {
            return "\(count) saved · \(name) connected"
        }
        return "\(count) saved vehicle\(count == 1 ? "" : "s")"
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            EmptyStateView(
                systemImage: "car.badge.gearshape",
                title: "Your garage is empty",
                message: "Add a vehicle with year, make and model — or decode its VIN — so the assistant can give answers specific to your car.",
                actionTitle: "Add a vehicle",
                action: { showAddVehicle = true }
            )
            Button {
                Haptics.tap()
                useDirectConnection()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal.circle")
                    Text("Skip setup — Direct OBD Connection")
                }
                .font(.obCallout.weight(.semibold))
                .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 30)
    }

    private var directConnectionCard: some View {
        Group {
            if !env.garage.vehicles.contains(where: { $0.isDirectConnection }) {
                Button {
                    Haptics.tap()
                    useDirectConnection()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Direct OBD Connection")
                                .font(.obCallout.weight(.semibold))
                                .foregroundStyle(Palette.textPrimary)
                            Text("Use live data and codes without a saved vehicle")
                                .font(.obCaption)
                                .foregroundStyle(Palette.textTertiary)
                        }
                        Spacer()
                        Image(systemName: "plus.circle")
                            .foregroundStyle(Palette.accent)
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .panel()
            }
        }
    }

    private var addVehicleButton: some View {
        GlassSecondaryButton(title: "Add another vehicle", systemImage: "plus") {
            Haptics.tap()
            showAddVehicle = true
        }
        .padding(.top, 4)
    }

    // MARK: Actions

    private func isLive(_ vehicle: Vehicle) -> Bool {
        env.obd.isConnected && env.garage.selectedVehicleID == vehicle.id
    }

    private func select(_ vehicle: Vehicle) {
        env.garage.select(vehicle.id)
    }

    private func open(_ vehicle: Vehicle) {
        env.garage.select(vehicle.id)
        env.requestedSection = .dashboard
    }

    private func useDirectConnection() {
        if let existing = env.garage.vehicles.first(where: { $0.isDirectConnection }) {
            env.garage.select(existing.id)
        } else {
            env.garage.add(Vehicle.directConnection)
        }
        env.requestedSection = .dashboard
    }
}

// MARK: - Vehicle card

struct VehicleCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let vehicle: Vehicle
    let isSelected: Bool
    let isLive: Bool
    let faultCount: Int
    var onSelect: () -> Void
    var onOpen: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onOpen) {
                headerLayout {
                    HStack(spacing: 13) {
                        badge
                        VStack(alignment: .leading, spacing: 3) {
                            Text(vehicle.displayName)
                                .font(.obTitle2)
                                .foregroundStyle(Palette.textPrimary)
                                .lineLimit(2)
                            Text(vehicle.subtitle.isEmpty ? "No engine details yet" : vehicle.subtitle)
                                .font(.obCaption)
                                .foregroundStyle(Palette.textSecondary)
                                .lineLimit(2)
                        }
                        .layoutPriority(1)
                    }
                    Spacer(minLength: 6)
                    statusColumn
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Text(cardFooter)
                    .font(.obCaption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(2)
                Spacer()
                Menu {
                    Button { onEdit() } label: { Label("Edit vehicle", systemImage: "pencil") }
                    Button(role: .destructive) { onDelete() } label: { Label("Remove vehicle", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
            }
        }
        .padding(15)
        .panel(tint: isSelected ? Palette.accent.opacity(0.10) : nil)
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        .contextMenu {
            Button { onEdit() } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) { onDelete() } label: { Label("Remove", systemImage: "trash") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double tap to open the dashboard for this vehicle")
    }

    private var headerLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 0))
    }

    private var cardFooter: String {
        var parts: [String] = []
        if isSelected { parts.append("Selected") }
        if let vin = vehicle.vin, !vin.isBlank { parts.append("VIN …\(vin.suffix(6))") }
        if let date = vehicle.lastConnectedAt { parts.append("Connected \(Format.relative(date))") }
        return parts.joined(separator: " · ")
    }

    private var badge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.accent.opacity(0.15))
                .frame(width: 54, height: 54)
            Text(vehicle.initials)
                .font(.body.weight(.semibold))
                .foregroundStyle(Palette.accent)
        }
    }

    private var statusColumn: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if faultCount > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.bold))
                    Text("\(faultCount)")
                        .obMono(14, weight: .bold)
                }
                .foregroundStyle(Palette.amber)
            } else {
                Image(systemName: "checkmark.seal.fill")
                    .font(.subheadline)
                    .foregroundStyle(Palette.success.opacity(0.85))
            }
            HStack(spacing: 5) {
                StatusDot(color: isLive ? Palette.success : Palette.textTertiary, pulsing: isLive)
                Text(isLive ? "Live" : "Idle")
                    .font(.obMicro)
                    .foregroundStyle(isLive ? Palette.success : Palette.textTertiary)
            }
        }
    }
}
