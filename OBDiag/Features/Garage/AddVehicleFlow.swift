import SwiftUI
import UIKit

/// Guided multi-step vehicle setup: year/make/model lookup, VIN entry or VIN
/// read over OBD, then confirmation and details.
struct AddVehicleFlow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable {
        case method
        case lookup
        case vinEntry
        case readingVIN
        case review
        case details

        var title: String {
            switch self {
            case .method: return "Add a vehicle"
            case .lookup: return "Year, make & model"
            case .vinEntry: return "Enter VIN"
            case .readingVIN: return "Reading VIN"
            case .review: return "Confirm details"
            case .details: return "Finish up"
            }
        }
    }

    @State private var step: Step = .method
    @State private var draft = VehicleDraft()
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var readVINTask: Task<Void, Never>?

    var body: some View {
        SheetNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if step != .method {
                        progressBar
                    }
                    content
                }
                .padding(18)
                .padding(.bottom, 40)
            }
            .dismissKeyboardOnScroll()
            .navigationTitle(step.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step != .method {
                        Button {
                            goBack()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel("Back")
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
        }
        .interactiveDismissDisabled(step != .method)
    }

    // MARK: Chrome

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(index <= step.rawValue - 1 ? Palette.accent : Palette.stroke)
                    .frame(height: 4)
            }
        }
        .padding(.bottom, 2)
        .animation(.smooth, value: step)
    }

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.amber)
                    Text(errorMessage)
                        .font(.obCaption)
                        .foregroundStyle(Palette.textSecondary)
                    Spacer(minLength: 0)
                }
            }

            switch step {
            case .method:
                EmptyView()
            case .lookup:
                GlassActionButton(title: "Continue", systemImage: "arrow.right", isEnabled: draft.isLookupComplete) {
                    step = .details
                }
            case .vinEntry:
                GlassActionButton(title: "Decode VIN", systemImage: "wand.and.stars", isEnabled: Vehicle.isPlausibleVIN(draft.vin), isLoading: isWorking) {
                    decodeVIN()
                }
            case .readingVIN:
                GlassSecondaryButton(title: "Enter it manually instead", systemImage: "keyboard") {
                    readVINTask?.cancel()
                    step = .vinEntry
                }
            case .review:
                GlassActionButton(title: "Looks right", systemImage: "checkmark", isEnabled: draft.decoded?.isValid ?? false) {
                    step = .details
                }
            case .details:
                GlassActionButton(title: "Add to garage", systemImage: "plus", isEnabled: !draft.make.isBlank || draft.decoded != nil) {
                    save()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .bottomFade()
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .method: methodStep
        case .lookup: VehicleLookupForm(draft: $draft)
        case .vinEntry: vinEntryStep
        case .readingVIN: readingVINStep
        case .review: reviewStep
        case .details: detailsStep
        }
    }

    // MARK: Step 1 — method

    private var methodStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How would you like to add it?")
                .font(.obTitle)
                .foregroundStyle(Palette.textPrimary)
            Text("A saved vehicle lets the assistant tailor answers to your exact year, engine and trim.")
                .font(.obCallout)
                .foregroundStyle(Palette.textSecondary)

            methodCard(
                icon: "list.bullet.rectangle",
                title: "Pick year, make & model",
                subtitle: "Look up your vehicle from a public database.",
                badge: nil
            ) { step = .lookup }

            methodCard(
                icon: "number.square",
                title: "Enter a VIN",
                subtitle: "17 characters — usually on the driver's door jamb or windshield base.",
                badge: nil
            ) { step = .vinEntry }

            methodCard(
                icon: "bolt.horizontal.circle",
                title: "Read VIN from the car",
                subtitle: env.obd.isConnected
                    ? "Ask the connected adapter to report the VIN over OBD."
                    : "Connect an adapter or start demo mode to use this.",
                badge: env.obd.isConnected ? "Ready" : "Needs adapter"
            ) {
                guard env.obd.isConnected else { return }
                startVINRead()
            }

            Button {
                Haptics.tap()
                let vehicle = env.garage.add(Vehicle.directConnection)
                env.garage.select(vehicle.id)
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "forward.fill")
                    Text("Skip — use Direct OBD Connection")
                }
                .font(.obCallout.weight(.semibold))
                .foregroundStyle(Palette.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
    }

    private func methodCard(
        icon: String,
        title: String,
        subtitle: String,
        badge: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Palette.accent.opacity(0.14))
                        .frame(width: 46, height: 46)
                    Image(systemName: icon)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.obHeadline)
                        .foregroundStyle(Palette.textPrimary)
                    Text(subtitle)
                        .font(.obCaption)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.obMicro)
                        .foregroundStyle(badge == "Ready" ? Palette.success : Palette.textTertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panel()
        .opacity(badge == "Needs adapter" ? 0.6 : 1)
    }

    // MARK: Step 3 — VIN entry

    private var vinEntryStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Type or paste the VIN")
                .font(.obTitle2)
                .foregroundStyle(Palette.textPrimary)
            Text("The VIN encodes the year, make, model, engine and trim. It's the fastest way to get an exact match.")
                .font(.obCallout)
                .foregroundStyle(Palette.textSecondary)

            TextField("e.g. 1HGCM82633A004352", text: $draft.vin)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.obMono(17, weight: .medium))
                .padding(14)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .onChange(of: draft.vin) { _, newValue in
                    draft.vin = String(newValue.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(17))
                    errorMessage = nil
                }

            HStack(spacing: 8) {
                Image(systemName: Vehicle.isPlausibleVIN(draft.vin) ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(Vehicle.isPlausibleVIN(draft.vin) ? Palette.success : Palette.textTertiary)
                Text(Vehicle.isPlausibleVIN(draft.vin)
                     ? "That's a valid VIN format."
                     : "\(draft.vin.count)/17 characters · I, O and Q are never used.")
                    .font(.obCaption)
                    .foregroundStyle(Palette.textSecondary)
            }

            HStack {
                Button {
                    if let clip = UIPasteboard.general.string {
                        draft.vin = clip.uppercased().filter { $0.isLetter || $0.isNumber }
                    }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .font(.obCaption)
                }
                .buttonStyle(.glass)
                Spacer()
                if env.obd.isConnected {
                    Button {
                        startVINRead()
                    } label: {
                        Label("Read from car", systemImage: "bolt.horizontal")
                            .font(.obCaption)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    // MARK: Step 4 — reading VIN

    private var readingVINStep: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 30)
            ProgressView()
                .controlSize(.large)
                .tint(Palette.accent)
            Text("Asking the vehicle for its VIN…")
                .font(.obTitle2)
                .foregroundStyle(Palette.textPrimary)
            Text("Mode 09 PID 02 is optional and some vehicles take a few seconds to answer.")
                .font(.obCallout)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            if let status = env.obd.vinStatus.message {
                GlassChip(text: status, systemImage: "info.circle", tint: Palette.textSecondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Step 5 — review

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let decoded = draft.decoded {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Palette.success)
                    Text("VIN decoded")
                        .font(.obHeadline)
                        .foregroundStyle(Palette.textPrimary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    detailRow("VIN", draft.vin, mono: true)
                    detailRow("Year", decoded.year.map(String.init))
                    detailRow("Make", decoded.make)
                    detailRow("Model", decoded.model)
                    detailRow("Trim", decoded.trimName)
                    detailRow("Series", decoded.series)
                    detailRow("Engine", decoded.engineDescription)
                    detailRow("Fuel", decoded.fuelType)
                    detailRow("Body", decoded.bodyClass)
                    detailRow("Drive", decoded.driveType)
                    detailRow("Built in", decoded.plantCountry)
                }
                .padding(14)
                .panel()

                if !decoded.errors.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Notes from the decoder", systemImage: "info.circle")
                            .font(.obCaption.weight(.semibold))
                            .foregroundStyle(Palette.amber)
                        ForEach(decoded.errors.prefix(3), id: \.self) { error in
                            Text("• \(error)")
                                .font(.obCaption)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .padding(12)
                    .panel(cornerRadius: 16, tint: Palette.amber.opacity(0.10))
                }

                Text("You can correct anything on the next step.")
                    .font(.obCaption)
                    .foregroundStyle(Palette.textTertiary)
            } else {
                Text("No decoded data.")
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private func detailRow(_ label: String, _ value: String?, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.obCaption)
                .foregroundStyle(Palette.textTertiary)
                .frame(width: 74, alignment: .leading)
            Text(value?.isEmpty == false ? value! : "—")
                .font(mono ? .obMono(14, weight: .medium) : .obCallout)
                .foregroundStyle(Palette.textPrimary)
            Spacer()
        }
    }

    // MARK: Step 6 — details

    private var detailsStep: some View {
        VehicleDetailsForm(draft: $draft)
    }

    // MARK: Actions

    private func goBack() {
        readVINTask?.cancel()
        switch step {
        case .method: break
        case .lookup: step = .method
        case .vinEntry: step = .method
        case .readingVIN: step = .method
        case .review: step = draft.vin.isBlank ? .lookup : .vinEntry
        case .details: step = draft.decoded != nil ? .review : .lookup
        }
        errorMessage = nil
    }

    private func decodeVIN() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                let decoded = try await env.catalog.decode(vin: draft.vin)
                draft.apply(decoded)
                step = .review
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func startVINRead() {
        step = .readingVIN
        readVINTask = Task {
            guard let vin = await env.obd.readVIN(force: true) else {
                errorMessage = env.obd.vinStatus.message ?? "The vehicle did not report a VIN."
                step = .vinEntry
                return
            }
            draft.vin = vin
            do {
                let decoded = try await env.catalog.decode(vin: vin)
                draft.apply(decoded)
                step = .review
            } catch {
                errorMessage = "VIN \(vin) was read, but decoding failed: \(error.localizedDescription)"
                step = .vinEntry
            }
        }
    }

    private func save() {
        let vehicle = draft.makeVehicle()
        let added = env.garage.add(vehicle)
        env.garage.select(added.id)
        Haptics.success()
        dismiss()
    }
}

// MARK: - Draft

struct VehicleDraft {
    var year: Int?
    var make: String = ""
    var model: String = ""
    var trim: String = ""
    var vin: String = ""
    var engine: String = ""
    var fuelType: String = ""
    var nickname: String = ""
    var notes: String = ""
    var decoded: DecodedVehicle?

    var isLookupComplete: Bool {
        year != nil && !make.isBlank && !model.isBlank
    }

    mutating func apply(_ decoded: DecodedVehicle) {
        self.decoded = decoded
        if let year = decoded.year { self.year = year }
        if let make = decoded.make, !make.isBlank { self.make = make }
        if let model = decoded.model, !model.isBlank { self.model = model }
        if let trim = decoded.trimName, !trim.isBlank { self.trim = trim }
        if let engine = decoded.engineDescription, !engine.isBlank { self.engine = engine }
        if let fuel = decoded.fuelType, !fuel.isBlank { self.fuelType = fuel }
    }

    func makeVehicle() -> Vehicle {
        Vehicle(
            nickname: nickname.trimmed,
            year: year,
            make: make.trimmed.isEmpty ? "Unknown" : make.trimmed,
            model: model.trimmed.isEmpty ? "Vehicle" : model.trimmed,
            trim: trim.trimmed.isEmpty ? nil : trim.trimmed,
            vin: vin.trimmed.isEmpty ? nil : vin.trimmed.uppercased(),
            engineDescription: engine.trimmed.isEmpty ? nil : engine.trimmed,
            fuelType: fuelType.trimmed.isEmpty ? nil : fuelType.trimmed,
            bodyClass: decoded?.bodyClass,
            driveType: decoded?.driveType,
            notes: notes.trimmed
        )
    }
}

// MARK: - Year / make / model form

struct VehicleLookupForm: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var draft: VehicleDraft

    @State private var makes: [VehicleMake] = []
    @State private var models: [String] = []
    @State private var isLoadingMakes = false
    @State private var isLoadingModels = false
    @State private var showMakePicker = false
    @State private var showModelPicker = false
    @State private var makeSearch = ""
    @State private var modelSearch = ""

    private var years: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array((1980...(current + 1)).reversed())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            fieldContainer(title: "Year") {
                Menu {
                    ForEach(years, id: \.self) { year in
                        Button(String(year)) {
                            draft.year = year
                            draft.model = ""
                            loadModels()
                        }
                    }
                } label: {
                    pickerLabel(draft.year.map(String.init) ?? "Select year")
                }
            }

            fieldContainer(title: "Make") {
                Button {
                    showMakePicker = true
                } label: {
                    pickerLabel(draft.make.isEmpty ? "Select make" : draft.make)
                }
                .buttonStyle(.plain)
            }

            fieldContainer(title: "Model") {
                Button {
                    showModelPicker = true
                } label: {
                    pickerLabel(draft.model.isEmpty ? (draft.make.isEmpty ? "Choose a make first" : "Select model") : draft.model)
                }
                .buttonStyle(.plain)
                .disabled(draft.make.isEmpty)
                .opacity(draft.make.isEmpty ? 0.5 : 1)
            }

            fieldContainer(title: "Trim (optional)") {
                TextField("e.g. EX-L, Sport, Limited", text: $draft.trim)
                    .font(.obCallout)
                    .textInputAutocapitalization(.words)
            }

            if isLoadingModels || isLoadingMakes {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading vehicle data…")
                        .font(.obCaption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }

            Text("Vehicle data comes from the NHTSA vPIC database. If a model is missing, type it below.")
                .font(.obCaption)
                .foregroundStyle(Palette.textTertiary)

            fieldContainer(title: "Model override") {
                TextField("Type the model manually", text: $draft.model)
                    .font(.obCallout)
            }
        }
        .task {
            guard makes.isEmpty else { return }
            isLoadingMakes = true
            makes = await env.catalog.makes()
            isLoadingMakes = false
        }
        .sheet(isPresented: $showMakePicker) {
            SearchableListSheet(
                title: "Select make",
                items: makes.map(\.name),
                searchText: $makeSearch,
                isSearchable: makes.count > 12
            ) { name in
                draft.make = name
                draft.model = ""
                showMakePicker = false
                loadModels()
            }
        }
        .sheet(isPresented: $showModelPicker) {
            SearchableListSheet(
                title: "\(draft.year.map(String.init) ?? "") \(draft.make) models",
                items: models,
                searchText: $modelSearch,
                isSearchable: models.count > 12,
                emptyMessage: "No models found. Type it manually on the previous screen."
            ) { name in
                draft.model = name
                showModelPicker = false
            }
        }
    }

    private func fieldContainer<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.obCaption.weight(.semibold))
                .foregroundStyle(Palette.textTertiary)
            content()
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }

    private func pickerLabel(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.obCallout)
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private func loadModels() {
        guard let year = draft.year, !draft.make.isEmpty else { return }
        isLoadingModels = true
        Task {
            models = await env.catalog.models(make: draft.make, year: year)
            isLoadingModels = false
        }
    }
}

/// Searchable single-select list used for make/model selection.
struct SearchableListSheet: View {
    let title: String
    let items: [String]
    @Binding var searchText: String
    var isSearchable: Bool = true
    var emptyMessage: String = "Nothing found."
    var onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private var filtered: [String] {
        guard !searchText.isBlank else { return items }
        return items.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        SheetNavigationStack {
            List(filtered, id: \.self) { item in
                Button {
                    Haptics.selection()
                    onSelect(item)
                } label: {
                    Text(item)
                        .foregroundStyle(Palette.textPrimary)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if filtered.isEmpty {
                    ContentUnavailableView("No results", systemImage: "magnifyingglass", description: Text(emptyMessage))
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Details form

struct VehicleDetailsForm: View {
    @Binding var draft: VehicleDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let decoded = draft.decoded, decoded.isValid {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.success)
                    Text(decoded.summary)
                        .font(.obHeadline)
                        .foregroundStyle(Palette.textPrimary)
                }
            }

            group("Identity") {
                LabeledField(label: "Nickname", placeholder: "e.g. Daily driver", text: $draft.nickname)
                LabeledField(label: "Year", placeholder: "2018", text: Binding(
                    get: { draft.year.map(String.init) ?? "" },
                    set: { draft.year = Format.normalizeYear($0) }
                ), keyboard: .numberPad)
                LabeledField(label: "Make", placeholder: "Honda", text: $draft.make)
                LabeledField(label: "Model", placeholder: "Civic", text: $draft.model)
                LabeledField(label: "Trim", placeholder: "EX-L", text: $draft.trim)
            }

            group("Mechanical") {
                LabeledField(label: "Engine", placeholder: "1.5L 4-cyl turbo", text: $draft.engine)
                LabeledField(label: "Fuel", placeholder: "Gasoline", text: $draft.fuelType)
            }

            group("Notes") {
                TextField("Anything the assistant should know — modifications, known issues, recent work…", text: $draft.notes, axis: .vertical)
                    .lineLimit(3...6)
                    .font(.obCallout)
            }
        }
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.obCaption.weight(.semibold))
                .foregroundStyle(Palette.textTertiary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(14)
            .panel(cornerRadius: 14)
        }
    }
}

struct LabeledField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.obMicro)
                .foregroundStyle(Palette.textTertiary)
            TextField(placeholder, text: $text)
                .font(.obCallout)
                .keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .numberPad ? .never : .words)
        }
    }
}
