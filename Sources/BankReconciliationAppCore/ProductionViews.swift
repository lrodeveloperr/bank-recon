import BankReconciliationEngine
import SwiftUI
import UniformTypeIdentifiers

struct SourceProfileEditorView: View {
    @ObservedObject var model: BankReconciliationAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SourceProfileDraft

    init(model: BankReconciliationAppModel, initialDraft: SourceProfileDraft) {
        self.model = model
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Name", text: $draft.name)
                Picker("Format", selection: $draft.format) {
                    ForEach(InputFormat.allCases, id: \.self) { format in
                        Text(format.rawValue.uppercased()).tag(format)
                    }
                }
                if draft.format == .xlsx {
                    TextField("Worksheet name (optional)", text: $draft.selectedWorksheet)
                }
            }
            if draft.usesColumnMapping {
                Section("File layout") {
                    Toggle("First row contains headers", isOn: $draft.hasHeader)
                    if draft.format != .xlsx && draft.format != .tsv {
                        TextField("Delimiter", text: $draft.delimiter)
                    }
                    if draft.format == .tsv {
                        LabeledContent("Delimiter", value: "Tab")
                    }
                }
                Section("Columns (zero-based)") {
                    columnField("Date", text: $draft.dateColumn, required: true)
                    columnField("Amount", text: $draft.amountColumn, required: true)
                    columnField("Account", text: $draft.accountColumn)
                    columnField("Currency", text: $draft.currencyColumn)
                    columnField("Transaction ID", text: $draft.strongIDColumn)
                    columnField("Reference", text: $draft.referenceColumn)
                    columnField("Description", text: $draft.descriptionColumn)
                    columnField("Running balance", text: $draft.runningBalanceColumn)
                }
            }
            Section("Dates and numbers") {
                Picker("Date order", selection: $draft.dateOrder) {
                    Text("YYYY-MM-DD").tag(DateOrder.ymd)
                    Text("DD-MM-YYYY").tag(DateOrder.dmy)
                    Text("MM-DD-YYYY").tag(DateOrder.mdy)
                }
                TextField("Decimal separator", text: $draft.decimalSeparator)
                TextField("Grouping separator (optional)", text: $draft.groupingSeparator)
            }
            Section("Defaults") {
                TextField("Default account", text: $draft.defaultAccount)
                TextField("Default currency (ISO 4217)", text: $draft.defaultCurrency)
                    .textInputAutocapitalization(.characters)
            }
            Section {
                Text("Column numbers start at 0. Leave optional columns blank. Defaults are used only when the source file does not provide that field.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Source Profile")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
        }
    }

    @ViewBuilder
    private func columnField(_ title: String, text: Binding<String>, required: Bool = false) -> some View {
        TextField(required ? "\(title) (required)" : "\(title) (optional)", text: text)
#if os(iOS)
            .keyboardType(.numberPad)
#endif
    }

    private func save() {
        do {
            let profile = try draft.makeProfile()
            Task {
                await model.saveSourceProfile(profile)
                if model.message == nil { dismiss() }
            }
        } catch {
            model.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct BatchFoldersView: View {
    @ObservedObject var model: BankReconciliationAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingFolderImporter = false
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var endDate = Date()
    let didImport: () -> Void

    var body: some View {
        List {
            Section("Period") {
                DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                DatePicker("End date", selection: $endDate, displayedComponents: .date)
            }
            if model.applicationState.watchedBatchFolders.isEmpty {
                ContentUnavailableView(
                    "No Batch Folders",
                    systemImage: "folder.badge.plus",
                    description: Text("Add a folder whose files use _bank/_ledger, _old/_new, or _statement suffixes.")
                )
            }
            ForEach(model.applicationState.watchedBatchFolders) { folder in
                Section(folder.name) {
                    HStack {
                        Button("Rescan") { Task { await model.scanWatchedBatchFolder(folder.id) } }
                        Spacer()
                        Button("Remove", role: .destructive) {
                            Task { await model.removeWatchedBatchFolder(folder.id) }
                        }
                    }
                    if let scan = model.batchFolderScans[folder.id] {
                        if scan.candidates.isEmpty {
                            Text("No complete file sets found").foregroundStyle(.secondary)
                        }
                        ForEach(scan.candidates) { candidate in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(candidate.name).font(.headline)
                                        Text(candidate.mode.displayName).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Import & Preview") { importCandidate(candidate, from: folder.id) }
                                        .buttonStyle(.borderedProminent)
                                }
                                Text(candidate.filenamesByRole
                                    .sorted { $0.key.rawValue < $1.key.rawValue }
                                    .map { "\($0.key.displayName): \($0.value)" }
                                    .joined(separator: "  ·  "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        if !scan.unassignedFilenames.isEmpty {
                            DisclosureGroup("Unassigned files (\(scan.unassignedFilenames.count))") {
                                ForEach(scan.unassignedFilenames, id: \.self) { Text($0).font(.caption) }
                            }
                        }
                    } else {
                        ProgressView("Scanning…")
                    }
                }
            }
        }
        .navigationTitle("Batch Folders")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button { showingFolderImporter = true } label: { Label("Add Folder", systemImage: "folder.badge.plus") }
            }
        }
        .fileImporter(isPresented: $showingFolderImporter, allowedContentTypes: [.folder]) { result in
            do {
                let url = try result.get()
                Task { await model.addWatchedBatchFolder(url) }
            } catch { model.message = error.localizedDescription }
        }
        .task {
            for folder in model.applicationState.watchedBatchFolders {
                await model.scanWatchedBatchFolder(folder.id)
            }
        }
    }

    private func importCandidate(_ candidate: BatchCandidate, from folderID: UUID) {
        do {
            let period = try selectedPeriod()
            Task {
                await model.importBatchCandidate(
                    folderID: folderID,
                    candidate: candidate,
                    start: period.start,
                    end: period.end
                )
                if model.workflow?.id != nil, model.message == nil { didImport() }
            }
        } catch { model.message = error.localizedDescription }
    }

    private func selectedPeriod() throws -> ReconciliationPeriod {
        let calendar = Calendar(identifier: .gregorian)
        func localDate(_ date: Date) -> LocalDate {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return LocalDate(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
        }
        return try ReconciliationPeriod(start: localDate(startDate), end: localDate(endDate))
    }
}

struct ReviewWorkspaceView: View {
    @ObservedObject var model: BankReconciliationAppModel
    let workflow: ReconciliationWorkflow
    let result: ReconciliationResult
    @State private var selectedException: ReconciliationException?

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 760 {
                HStack(alignment: .top, spacing: 16) {
                    comparison.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    inspector.frame(width: min(360, proxy.size.width * 0.34), maxHeight: .infinity)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    comparison.frame(maxWidth: .infinity, minHeight: 320)
                    Divider()
                    inspector.frame(maxWidth: .infinity, minHeight: 260)
                }
            }
        }
        .frame(minHeight: 560)
        .onAppear { selectedException = selectedException ?? result.exceptions.first }
    }

    private var comparison: some View {
        GroupBox("Two-column comparison") {
            VStack(spacing: 0) {
                HStack {
                    Text(leftSource?.statement.file.filename ?? "Source A").font(.headline)
                    Spacer()
                    Text(rightSource?.statement.file.filename ?? (workflow.mode == .singleStatement ? "Check" : "Source B")).font(.headline)
                }
                .padding(.bottom, 8)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(comparisonRows) { row in
                            HStack(alignment: .top, spacing: 12) {
                                transactionCell(row.left).frame(maxWidth: .infinity, alignment: .leading)
                                Divider()
                                transactionCell(row.right).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var inspector: some View {
        GroupBox("Exception inspector") {
            VStack(alignment: .leading, spacing: 10) {
                if result.exceptions.isEmpty {
                    ContentUnavailableView("No Exceptions", systemImage: "checkmark.seal", description: Text("All comparable items matched."))
                } else {
                    Picker("Exception", selection: $selectedException) {
                        ForEach(result.exceptions, id: \.self) { exception in
                            Text(exception.kind.displayName).tag(Optional(exception))
                        }
                    }
                    if let selectedException {
                        ScrollView {
                            ExceptionDecisionView(
                                model: model,
                                exception: selectedException,
                                disabled: workflow.isBuiltInSample
                            )
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var leftSource: ImportedWorkflowSource? { workflow.sources.first }
    private var rightSource: ImportedWorkflowSource? { workflow.sources.dropFirst().first }

    private var comparisonRows: [ComparisonRow] {
        let leftTransactions = Dictionary(uniqueKeysWithValues: (leftSource?.statement.transactions ?? []).map { ($0.locator, $0) })
        let rightTransactions = Dictionary(uniqueKeysWithValues: (rightSource?.statement.transactions ?? []).map { ($0.locator, $0) })
        var rows = result.matches.enumerated().map { offset, match in
            ComparisonRow(id: "match-\(offset)-\(match.leftLocator)-\(match.rightLocator)", left: leftTransactions[match.leftLocator], right: rightTransactions[match.rightLocator])
        }
        for (offset, exception) in result.exceptions.enumerated() {
            let maximum = max(max(exception.leftLocators.count, exception.rightLocators.count), 1)
            for index in 0..<maximum {
                let left = index < exception.leftLocators.count ? leftTransactions[exception.leftLocators[index]] : nil
                let right = index < exception.rightLocators.count ? rightTransactions[exception.rightLocators[index]] : nil
                if left != nil || right != nil {
                    rows.append(ComparisonRow(id: "exception-\(offset)-\(index)", left: left, right: right))
                }
            }
        }
        if workflow.mode == .singleStatement, rows.isEmpty {
            return (leftSource?.statement.transactions ?? []).enumerated().map {
                ComparisonRow(id: "statement-\($0.offset)", left: $0.element, right: nil)
            }
        }
        return rows
    }

    @ViewBuilder
    private func transactionCell(_ transaction: CanonicalTransaction?) -> some View {
        if let transaction {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(transaction.bookingDate.description).font(.caption.monospaced())
                    Spacer()
                    Text(transaction.amount.description).monospacedDigit()
                }
                Text(transaction.description ?? transaction.payee ?? transaction.memo ?? transaction.reference ?? transaction.locator)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                Text(transaction.locator).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

private struct ComparisonRow: Identifiable {
    let id: String
    let left: CanonicalTransaction?
    let right: CanonicalTransaction?
}
