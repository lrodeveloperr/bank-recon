import BankReconciliationEngine
import SwiftUI
import UniformTypeIdentifiers

public struct BankReconciliationBootstrapView: View {
    @State private var model: BankReconciliationAppModel?
    @State private var startupError: String?

    public init() {}

    public var body: some View {
        Group {
            if let model {
                BankReconciliationRootView(model: model)
            } else if let startupError {
                ContentUnavailableView(
                    "Unable to open the local store",
                    systemImage: "exclamationmark.shield",
                    description: Text(startupError)
                )
            } else {
                ProgressView("Opening Bank Reconciliation…")
            }
        }
        .task {
            guard model == nil, startupError == nil else { return }
            do {
                let live = try BankReconciliationAppModel.live()
                model = live
                await live.start()
            } catch {
                startupError = error.localizedDescription
            }
        }
    }
}

public struct BankReconciliationRootView: View {
    @ObservedObject private var model: BankReconciliationAppModel
    @State private var selection: AppSection? = .reconciliations
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif

    public init(model: BankReconciliationAppModel) { self.model = model }

    public var body: some View {
        Group {
#if os(iOS)
            if horizontalSizeClass == .compact {
                compactTabs
            } else {
                splitNavigation
            }
#else
            splitNavigation
#endif
        }
        .overlay {
            if model.isBusy {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    ProgressView().controlSize(.large).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .alert("Bank Reconciliation", isPresented: messagePresented) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }

    private var messagePresented: Binding<Bool> {
        Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
    }

    private var splitNavigation: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .navigationTitle("Bank Reconciliation")
        } detail: {
            NavigationStack { screen(selection ?? .reconciliations) }
        }
    }

#if os(iOS)
    private var compactTabs: some View {
        TabView {
            NavigationStack { screen(.reconciliations) }
                .tabItem { Label(AppSection.reconciliations.title, systemImage: AppSection.reconciliations.symbol) }
            NavigationStack { screen(.sourceProfiles) }
                .tabItem { Label(AppSection.sourceProfiles.title, systemImage: AppSection.sourceProfiles.symbol) }
            NavigationStack { screen(.evidencePacks) }
                .tabItem { Label(AppSection.evidencePacks.title, systemImage: AppSection.evidencePacks.symbol) }
            NavigationStack { screen(.settings) }
                .tabItem { Label(AppSection.settings.title, systemImage: AppSection.settings.symbol) }
        }
    }
#endif

    @ViewBuilder
    private func screen(_ section: AppSection) -> some View {
        switch section {
        case .reconciliations: ReconciliationsView(model: model)
        case .sourceProfiles: SourceProfilesView(model: model)
        case .evidencePacks: EvidencePacksView(model: model)
        case .settings: SettingsView(model: model)
        }
    }
}

private enum AppSection: String, CaseIterable, Identifiable {
    case reconciliations, sourceProfiles, evidencePacks, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .reconciliations: "Reconciliations"
        case .sourceProfiles: "Source Profiles"
        case .evidencePacks: "Evidence Packs"
        case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .reconciliations: "arrow.left.arrow.right.square"
        case .sourceProfiles: "tablecells"
        case .evidencePacks: "lock.doc"
        case .settings: "gearshape"
        }
    }
}

private struct ReconciliationsView: View {
    @ObservedObject var model: BankReconciliationAppModel
    @State private var showingWorkflow = false

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Compare bank files without uploading them")
                            .font(.headline)
                        Text("Import, review exceptions, then lock a reproducible evidence pack.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("New Reconciliation") {
                        model.clearWorkflow()
                        showingWorkflow = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            Section("Saved") {
                if model.records.isEmpty {
                    Text("No reconciliations yet").foregroundStyle(.secondary)
                }
                ForEach(model.records, id: \.job.id) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label(record.state == .locked ? "Locked" : "Draft", systemImage: record.state == .locked ? "lock.fill" : "doc")
                            Spacer()
                            Text(record.result?.state.displayName ?? "Not previewed")
                        }
                        Text("\(record.job.mode.displayName) · \(record.job.period.start) – \(record.job.period.end)")
                            .foregroundStyle(.secondary)
                        Text(record.job.id.uuidString.lowercased())
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Reconciliations")
        .toolbar {
            Button {
                Task {
                    await model.loadBuiltInSample()
                    showingWorkflow = true
                }
            } label: { Label("Open Sample", systemImage: "sparkles") }
        }
        .sheet(isPresented: $showingWorkflow) {
            NavigationStack { WorkflowView(model: model) }
                .frame(minWidth: 620, minHeight: 620)
        }
    }
}

private struct WorkflowView: View {
    @ObservedObject var model: BankReconciliationAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode: ReconciliationMode = .bankVsLedger
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var endDate = Date()
    @State private var importingRole: SourceRole?
    @State private var showingImporter = false

    var body: some View {
        Group {
            if let workflow = model.workflow {
                workflowContent(workflow)
            } else {
                Form {
                    Picker("Workflow", selection: $mode) {
                        ForEach(ReconciliationMode.allUICases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                    DatePicker("End date", selection: $endDate, displayedComponents: .date)
                    Button("Start") { startWorkflow() }
                        .buttonStyle(.borderedProminent)
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle(model.workflow?.isBuiltInSample == true ? "Built-in Sample" : "New Reconciliation")
        .toolbar { Button("Done") { dismiss() } }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            importSelection(result)
        }
    }

    @ViewBuilder
    private func workflowContent(_ workflow: ReconciliationWorkflow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LabeledContent("Mode", value: workflow.mode.displayName)
                LabeledContent("Period", value: "\(workflow.period.start) – \(workflow.period.end)")

                GroupBox("Source files") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(workflow.requiredRoles, id: \.self) { role in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(role.displayName).font(.headline)
                                    Text(source(for: role, in: workflow)?.statement.file.filename ?? "No file selected")
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !workflow.isBuiltInSample {
                                    Button(source(for: role, in: workflow) == nil ? "Choose File" : "Replace") {
                                        importingRole = role
                                        showingImporter = true
                                    }
                                }
                            }
                        }
                    }.padding(.vertical, 6)
                }

                HStack {
                    Button("Preview Results") { Task { await model.preview() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(workflow.sources.count != workflow.requiredRoles.count)
                    if workflow.result != nil, !workflow.isBuiltInSample {
                        Button("Lock Evidence") { Task { await model.lockCurrent() } }
                            .buttonStyle(.bordered)
                    }
                }

                if let result = workflow.result {
                    ResultSummaryView(result: result)
                    if !result.exceptions.isEmpty {
                        GroupBox("Exceptions and explanations") {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(result.exceptions, id: \.self) { exception in
                                    ExceptionDecisionView(model: model, exception: exception, disabled: workflow.isBuiltInSample)
                                    if exception != result.exceptions.last { Divider() }
                                }
                            }.padding(.vertical, 6)
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func source(for role: SourceRole, in workflow: ReconciliationWorkflow) -> ImportedWorkflowSource? {
        workflow.sources.first { $0.statement.role == role }
    }

    private func startWorkflow() {
        do {
            let calendar = Calendar(identifier: .gregorian)
            let start = calendar.dateComponents([.year, .month, .day], from: startDate)
            let end = calendar.dateComponents([.year, .month, .day], from: endDate)
            try model.beginWorkflow(
                mode: mode,
                start: LocalDate(year: start.year ?? 0, month: start.month ?? 0, day: start.day ?? 0),
                end: LocalDate(year: end.year ?? 0, month: end.month ?? 0, day: end.day ?? 0)
            )
        } catch { model.message = error.localizedDescription }
    }

    private func importSelection(_ result: Result<[URL], Error>) {
        guard let role = importingRole else { return }
        do {
            guard let url = try result.get().first else { return }
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            Task { await model.importFile(data: data, filename: url.lastPathComponent, role: role) }
        } catch { model.message = error.localizedDescription }
    }
}

private struct ResultSummaryView: View {
    let result: ReconciliationResult
    var body: some View {
        GroupBox("Result") {
            VStack(alignment: .leading, spacing: 10) {
                Label(result.state.displayName, systemImage: result.state.symbol)
                    .font(.title3.bold())
                HStack(spacing: 24) {
                    metric("Matches", result.matches.count)
                    metric("Exceptions", result.exceptions.count)
                    metric("Partitions", result.totals.count)
                }
                ForEach(result.totals, id: \.self) { total in
                    HStack {
                        Text(total.partition.description)
                        Spacer()
                        Text("Difference \(total.difference.description)").monospacedDigit()
                    }
                }
            }.padding(.vertical, 6)
        }
    }
    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading) { Text("\(value)").font(.title2.bold()); Text(title).foregroundStyle(.secondary) }
    }
}

private struct ExceptionDecisionView: View {
    @ObservedObject var model: BankReconciliationAppModel
    let exception: ReconciliationException
    let disabled: Bool
    @State private var explanation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(exception.kind.displayName).font(.headline)
            Text(exception.detail).foregroundStyle(.secondary)
            if !disabled {
                TextField("Explanation required before approval", text: $explanation)
                HStack {
                    Button("Record as unresolved") { decide(approved: false) }
                    Button("Approve explanation") { decide(approved: true) }
                        .disabled(explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
    private func decide(approved: Bool) {
        Task { await model.decide(exception: exception, explanation: explanation, approved: approved) }
    }
}

private struct SourceProfilesView: View {
    @ObservedObject var model: BankReconciliationAppModel
    @State private var name = "CSV profile"

    var body: some View {
        List {
            Section("Saved mappings") {
                if model.applicationState.sourceProfiles.isEmpty {
                    Text("No saved source profiles").foregroundStyle(.secondary)
                }
                ForEach(model.applicationState.sourceProfiles) { profile in
                    VStack(alignment: .leading) {
                        Text(profile.name).font(.headline)
                        Text(profile.format.rawValue.uppercased()).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Add an inferred CSV profile") {
                TextField("Profile name", text: $name)
                Button("Save Profile") { saveProfile() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text(model.entitlement.tier == .free ? "Free includes one saved mapping." : "Your purchase includes unlimited saved mappings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Source Profiles")
    }

    private func saveProfile() {
        let mapping = DelimitedMapping(
            delimiter: ",", hasHeader: true, dateColumn: 0, amountColumn: 1,
            dateOrder: model.applicationState.preferredDateOrder,
            decimalSeparator: ".",
            defaultAccount: "Primary", defaultCurrency: model.applicationState.preferredCurrency
        )
        let profile = SourceProfile(name: name, format: .csv, delimitedMapping: mapping)
        Task { await model.saveSourceProfile(profile) }
    }
}

private struct EvidencePacksView: View {
    @ObservedObject var model: BankReconciliationAppModel

    var body: some View {
        List(model.records.filter { $0.state == .locked }, id: \.job.id) { record in
            NavigationLink {
                EvidenceDetailView(model: model, record: record)
            } label: {
                VStack(alignment: .leading) {
                    Text("\(record.job.period.start) – \(record.job.period.end)").font(.headline)
                    Text(record.job.mode.displayName).foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if !model.records.contains(where: { $0.state == .locked }) {
                ContentUnavailableView("No Evidence Packs", systemImage: "lock.doc", description: Text("Lock a reconciliation to create one."))
            }
        }
        .navigationTitle("Evidence Packs")
    }
}

private struct EvidenceDetailView: View {
    @ObservedObject var model: BankReconciliationAppModel
    let record: StoredJob
    @State private var exportedDocument: ReconciliationDocument?
    @State private var exportedName = "evidence"
    @State private var exportedType: UTType = .data
    @State private var exporting = false

    var body: some View {
        Form {
            Section("Verification") {
                LabeledContent("State", value: record.result?.state.displayName ?? "Unknown")
                LabeledContent("Evidence ID", value: record.evidence?.evidenceID ?? "Missing")
                LabeledContent("Manifest SHA-256", value: record.evidence?.manifestSHA256 ?? "Missing")
            }
            Section("Export") {
                Button("PDF report") { prepare(\.pdf, type: .pdf, suffix: "pdf") }
                Button("CSV detail") { prepare(\.csv, type: .commaSeparatedText, suffix: "csv") }
                Button("JSON manifest") { prepare(\.json, type: .json, suffix: "json") }
            }
            Section {
                Text("The report proves only the supplied files and recorded decisions. It is not audit, tax, accounting, legal or bank assurance.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Evidence Pack")
        .fileExporter(
            isPresented: $exporting,
            document: exportedDocument,
            contentType: exportedType,
            defaultFilename: exportedName
        ) { result in
            if case .failure(let error) = result { model.message = error.localizedDescription }
        }
    }

    private func prepare(_ keyPath: KeyPath<EvidenceReportPack, Data>, type: UTType, suffix: String) {
        do {
            let pack = try model.evidenceReport(for: record)
            exportedDocument = ReconciliationDocument(data: pack[keyPath: keyPath])
            exportedType = type
            exportedName = "\(pack.baseFilename).\(suffix)"
            exporting = true
        } catch { model.message = error.localizedDescription }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: BankReconciliationAppModel
    @State private var entityName = ""
    @State private var brandedHeader = ""
    @State private var newEntityName = ""
    @State private var backupDocument: ReconciliationDocument?
    @State private var exportingBackup = false
    @State private var importingBackup = false

    var body: some View {
        Form {
            Section("Plan") {
                LabeledContent("Current", value: model.entitlement.tier.displayName)
                Text(planSummary).foregroundStyle(.secondary)
                ForEach(model.products) { product in
                    Button("Buy \(product.displayName) — \(product.displayPrice)") {
                        Task { await model.purchase(product.tier) }
                    }
                }
                Button("Restore Purchases") { Task { await model.restorePurchases() } }
            }

            Section("Entity") {
                TextField("Entity name", text: $entityName)
                TextField("Branded report header (Accountant)", text: $brandedHeader)
                Button("Save Entity") {
                    Task { await model.updateSelectedWorkspace(name: entityName, brandedHeader: brandedHeader.nilWhenBlank) }
                }
                if model.entitlement.tier == .accountant {
                    TextField("New entity name", text: $newEntityName)
                    Button("Add Entity") {
                        Task { await model.addWorkspace(named: newEntityName) }
                    }.disabled(newEntityName.nilWhenBlank == nil)
                }
            }

            Section("Backup and restore") {
                Button("Export Local Backup") { exportBackup() }
                Button("Restore into Empty Store") { importingBackup = true }
                Text("Backups contain source files, reconciliation records and app settings. Store them securely. They never grant or restore App Store purchases.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Label("Files stay on this device", systemImage: "hand.raised.fill")
                Text("No account, analytics SDK, ads or bank-login connection is required.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .onAppear { populateEntityFields() }
        .onChange(of: model.applicationState.selectedWorkspaceID) { populateEntityFields() }
        .fileExporter(
            isPresented: $exportingBackup,
            document: backupDocument,
            contentType: .bankReconciliationBackup,
            defaultFilename: "bank-reconciliation-backup.bankreconbackup"
        ) { result in
            if case .failure(let error) = result { model.message = error.localizedDescription }
        }
        .fileImporter(isPresented: $importingBackup, allowedContentTypes: [.bankReconciliationBackup, .json]) { result in
            restoreBackup(result)
        }
    }

    private var planSummary: String {
        switch model.entitlement.tier {
        case .free: "One entity, one saved mapping and two locked reconciliations. Previews do not count."
        case .pro: "One entity with unlimited mappings, reconciliations and evidence packs."
        case .accountant: "Unlimited entities plus branded evidence headers and batch-ready capacity."
        }
    }

    private func populateEntityFields() {
        entityName = model.applicationState.selectedWorkspace?.name ?? "My entity"
        brandedHeader = model.applicationState.selectedWorkspace?.brandedEvidenceHeader ?? ""
    }

    private func exportBackup() {
        Task {
            do {
                backupDocument = ReconciliationDocument(data: try await model.makeBackup())
                exportingBackup = true
            } catch { model.message = error.localizedDescription }
        }
    }

    private func restoreBackup(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            Task { await model.restoreBackup(data) }
        } catch { model.message = error.localizedDescription }
    }
}

private extension String {
    var nilWhenBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private extension ReconciliationMode {
    static let allUICases: [Self] = [.bankVsLedger, .exportVsExport, .singleStatement]
    var displayName: String {
        switch self {
        case .bankVsLedger: "Bank vs ledger"
        case .exportVsExport: "Compare exports"
        case .singleStatement: "Check one statement"
        }
    }
}

private extension SourceRole {
    var displayName: String {
        switch self {
        case .bank: "Bank export"
        case .ledger: "Ledger export"
        case .olderExport: "Earlier export"
        case .newerExport: "Later export"
        case .statement: "Statement"
        }
    }
}

private extension ResultState {
    var displayName: String {
        switch self {
        case .reconciled: "Reconciled"
        case .reconciledWithExplanations: "Reconciled with explanations"
        case .differenceFound: "Difference found"
        case .cannotConclude: "Cannot conclude"
        }
    }
    var symbol: String {
        switch self {
        case .reconciled, .reconciledWithExplanations: "checkmark.seal.fill"
        case .differenceFound: "exclamationmark.triangle.fill"
        case .cannotConclude: "questionmark.diamond.fill"
        }
    }
}

private extension ExceptionKind {
    var displayName: String {
        rawValue.reduce(into: "") { output, character in
            if character.isUppercase { output.append(" ") }
            output.append(character)
        }.capitalized
    }
}

private extension EntitlementTier {
    var displayName: String {
        switch self {
        case .free: "Free"
        case .pro: "Pro"
        case .accountant: "Accountant"
        }
    }
}
