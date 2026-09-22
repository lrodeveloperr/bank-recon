import Foundation

public struct ReconciliationEngine: Sendable {
    public init() {}

    public func run(_ job: ReconciliationJob) throws -> ReconciliationResult {
        try validateMatchingPolicy(job.matchingPolicy ?? .default)
        let ordered = try validateAndOrderSources(job)
        if job.mode == .singleStatement {
            return try proveSingleStatement(ordered[0], job: job)
        }
        return try compare(ordered[0], ordered[1], job: job)
    }

    private func validateAndOrderSources(_ job: ReconciliationJob) throws -> [SourceStatement] {
        let expected: [SourceRole]
        switch job.mode {
        case .bankVsLedger: expected = [.bank, .ledger]
        case .exportVsExport: expected = [.olderExport, .newerExport]
        case .singleStatement: expected = [.statement]
        }
        guard job.sources.count == expected.count else { throw EngineError.roleMismatch("expected \(expected.count) source(s)") }
        var ordered: [SourceStatement] = []
        for role in expected {
            let candidates = job.sources.filter { $0.role == role }
            guard candidates.count == 1 else { throw EngineError.roleMismatch("expected exactly one \(role.rawValue)") }
            let source = candidates[0]
            guard source.period == job.period else { throw EngineError.periodViolation("source \(source.file.filename) does not use the selected period") }
            if source.replay.format == .csv || source.replay.format == .tsv {
                guard source.balances == source.replay.balanceOverrides else {
                    throw EngineError.integrityFailure("delimited balance overrides do not match the replay descriptor")
                }
            }
            guard Set(source.transactions.map(\.locator)).count == source.transactions.count else {
                throw EngineError.integrityFailure("duplicate transaction locator in \(source.file.filename)")
            }
            guard Set(source.transactions.map(\.sourceOrdinal)).count == source.transactions.count else {
                throw EngineError.integrityFailure("duplicate transaction ordinal in \(source.file.filename)")
            }
            for transaction in source.transactions where !job.period.contains(transaction.bookingDate) {
                throw EngineError.periodViolation("\(transaction.locator) lies outside the selected period")
            }
            guard source.transactions.allSatisfy({ $0.sourceID == source.file.sourceID && !$0.locator.isEmpty && !$0.account.isEmpty && $0.sourceOrdinal >= 0 }) else {
                throw EngineError.integrityFailure("transaction provenance is invalid in \(source.file.filename)")
            }
            for balance in source.balances where !job.period.contains(balance.date) {
                throw EngineError.periodViolation("balance \(balance.locator) lies outside the selected period")
            }
            guard source.balances.allSatisfy({ !$0.account.isEmpty && !$0.locator.isEmpty }) else {
                throw EngineError.integrityFailure("balance provenance is invalid in \(source.file.filename)")
            }
            guard Set(source.balances.map(\.locator)).count == source.balances.count else {
                throw EngineError.integrityFailure("duplicate balance locator in \(source.file.filename)")
            }
            ordered.append(source)
        }
        guard Set(job.decisions.map(\.exceptionKey)).count == job.decisions.count else {
            throw EngineError.integrityFailure("duplicate user decision keys")
        }
        if job.mode == .singleStatement, !job.manualMatches.isEmpty {
            throw EngineError.integrityFailure("single-statement mode cannot contain manual cross-source matches")
        }
        return ordered
    }

    private func proveSingleStatement(_ source: SourceStatement, job: ReconciliationJob) throws -> ReconciliationResult {
        var exceptions = structuralExceptions(source, side: .left)
        exceptions += duplicateExceptions(source.transactions, side: .left)
        exceptions += try runningBalanceExceptions(source, side: .left)
        exceptions += try statementArithmeticExceptions(source, side: .left)
        let totals = try singleStatementTotals(source)
        exceptions = bindExceptionFingerprints(exceptions, left: source.transactions, right: [])
        let inconclusive = source.completeness != .complete || !source.invalidLocators.isEmpty || source.balances.isEmpty
        let arithmeticCloses = !exceptions.contains { $0.kind == .balanceDifference || $0.kind == .runningBalanceBreak }
        let state = resultState(exceptions: exceptions, decisions: job.decisions, inconclusive: inconclusive, arithmeticCloses: arithmeticCloses)
        return ReconciliationResult(state: state, matches: [], exceptions: sorted(exceptions), totals: totals)
    }

    private enum Side { case left, right }

    private struct StrongMatchKey: Hashable, Comparable, CustomStringConvertible {
        let partition: PartitionKey
        let identifier: String

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.partition, lhs.identifier) < (rhs.partition, rhs.identifier)
        }

        var description: String { "\(partition) strong-id[\(identifier.utf8.count)]" }
    }

    private struct CompositeMatchKey: Hashable, Comparable, CustomStringConvertible {
        let partition: PartitionKey
        let date: LocalDate
        let amount: ExactAmount
        let reference: String

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.partition, lhs.date, lhs.amount, lhs.reference) < (rhs.partition, rhs.date, rhs.amount, rhs.reference)
        }

        var description: String { "\(partition) \(date) \(amount) reference[\(reference.utf8.count)]" }
    }

    private enum DuplicateIdentity: Hashable {
        case strong(PartitionKey, String)
        case signature(PartitionKey, LocalDate, ExactAmount, String?, String?)

        var description: String {
            switch self {
            case .strong(let partition, let identifier):
                return "\(partition) strong-id[\(identifier.utf8.count)]"
            case .signature(let partition, let date, let amount, let reference, let description):
                return "\(partition) \(date) \(amount) reference[\(reference?.utf8.count ?? 0)] description[\(description?.utf8.count ?? 0)]"
            }
        }
    }

    private struct BalanceComparisonKey: Hashable, Comparable, CustomStringConvertible {
        let partition: PartitionKey
        let kind: StatementBalanceKind

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.partition, lhs.kind.rawValue) < (rhs.partition, rhs.kind.rawValue)
        }

        var description: String { "\(partition) \(kind.rawValue)" }
    }

    private struct FuzzyCandidate: Hashable {
        let leftLocator: String
        let rightLocator: String
        let similarityPermille: Int
        let dateDistanceDays: Int
    }

    private struct SplitMergeCandidate: Hashable {
        let leftLocators: [String]
        let rightLocators: [String]
        let partition: PartitionKey
        let amount: ExactAmount

        var signature: String {
            "\(leftLocators.joined(separator: ","))|\(rightLocators.joined(separator: ","))"
        }
    }

    private func compare(_ left: SourceStatement, _ right: SourceStatement, job: ReconciliationJob) throws -> ReconciliationResult {
        var exceptions = structuralExceptions(left, side: .left) + structuralExceptions(right, side: .right)
        exceptions += duplicateExceptions(left.transactions, side: .left)
        exceptions += duplicateExceptions(right.transactions, side: .right)
        exceptions += try runningBalanceExceptions(left, side: .left)
        exceptions += try runningBalanceExceptions(right, side: .right)
        if !left.balances.isEmpty { exceptions += try statementArithmeticExceptions(left, side: .left) }
        if !right.balances.isEmpty { exceptions += try statementArithmeticExceptions(right, side: .right) }
        exceptions += try compareStatementBalances(left, right)

        let leftByLocator = Dictionary(uniqueKeysWithValues: left.transactions.map { ($0.locator, $0) })
        let rightByLocator = Dictionary(uniqueKeysWithValues: right.transactions.map { ($0.locator, $0) })
        var unmatchedLeft = Set(leftByLocator.keys)
        var unmatchedRight = Set(rightByLocator.keys)
        var matches: [TransactionMatch] = []

        for manual in job.manualMatches.sorted(by: { ($0.leftLocator, $0.rightLocator) < ($1.leftLocator, $1.rightLocator) }) {
            guard unmatchedLeft.contains(manual.leftLocator), unmatchedRight.contains(manual.rightLocator),
                  let lhs = leftByLocator[manual.leftLocator], let rhs = rightByLocator[manual.rightLocator] else {
                throw EngineError.integrityFailure("manual match reuses or references a missing transaction")
            }
            guard transactionFingerprint(lhs) == manual.leftFingerprint,
                  transactionFingerprint(rhs) == manual.rightFingerprint else {
                throw EngineError.integrityFailure("manual match is stale because a source row changed")
            }
            guard partition(lhs) == partition(rhs) else {
                throw EngineError.integrityFailure("manual match crosses account or currency")
            }
            matches.append(TransactionMatch(leftLocator: lhs.locator, rightLocator: rhs.locator, kind: .manual))
            unmatchedLeft.remove(lhs.locator)
            unmatchedRight.remove(rhs.locator)
            exceptions += mutationExceptions(lhs, rhs)
        }

        let leftStrong = groupedUnique(unmatchedLeft.compactMap { leftByLocator[$0] }, key: strongKey)
        let rightStrong = groupedUnique(unmatchedRight.compactMap { rightByLocator[$0] }, key: strongKey)
        for key in Set(leftStrong.keys).intersection(rightStrong.keys).sorted() {
            guard let leftItems = leftStrong[key], let rightItems = rightStrong[key] else { continue }
            if leftItems.count == 1, rightItems.count == 1 {
                let lhs = leftItems[0]
                let rhs = rightItems[0]
                guard partition(lhs) == partition(rhs) else {
                    throw EngineError.integrityFailure("structured strong-ID match crossed an account/currency partition")
                }
                matches.append(TransactionMatch(leftLocator: lhs.locator, rightLocator: rhs.locator, kind: .strongID))
                unmatchedLeft.remove(lhs.locator)
                unmatchedRight.remove(rhs.locator)
                exceptions += mutationExceptions(lhs, rhs)
            } else {
                exceptions.append(ReconciliationException(
                    kind: .ambiguousCandidate,
                    leftLocators: leftItems.map(\.locator),
                    rightLocators: rightItems.map(\.locator),
                    detail: "Strong identifier has multiple candidates: \(key)"
                ))
            }
        }

        let remainingLeft = unmatchedLeft.compactMap { leftByLocator[$0] }
        let remainingRight = unmatchedRight.compactMap { rightByLocator[$0] }
        let leftComposite = groupedUnique(remainingLeft, key: compositeKey)
        let rightComposite = groupedUnique(remainingRight, key: compositeKey)
        for key in Set(leftComposite.keys).intersection(rightComposite.keys).sorted() {
            guard let leftItems = leftComposite[key], let rightItems = rightComposite[key] else { continue }
            if leftItems.count == 1, rightItems.count == 1 {
                let lhs = leftItems[0]
                let rhs = rightItems[0]
                guard partition(lhs) == partition(rhs) else {
                    throw EngineError.integrityFailure("structured composite match crossed an account/currency partition")
                }
                matches.append(TransactionMatch(leftLocator: lhs.locator, rightLocator: rhs.locator, kind: .exactComposite))
                unmatchedLeft.remove(lhs.locator)
                unmatchedRight.remove(rhs.locator)
                exceptions += mutationExceptions(lhs, rhs)
            } else {
                exceptions.append(ReconciliationException(
                    kind: .ambiguousCandidate,
                    leftLocators: leftItems.map(\.locator),
                    rightLocators: rightItems.map(\.locator),
                    detail: "Composite identity has multiple candidates: \(key)"
                ))
            }
        }

        let policy = job.matchingPolicy ?? .default
        let fuzzy = try fuzzyMatches(
            left: unmatchedLeft.compactMap { leftByLocator[$0] },
            right: unmatchedRight.compactMap { rightByLocator[$0] },
            policy: policy
        )
        exceptions += fuzzy.ambiguous
        for candidate in fuzzy.accepted {
            guard unmatchedLeft.contains(candidate.leftLocator), unmatchedRight.contains(candidate.rightLocator),
                  let lhs = leftByLocator[candidate.leftLocator], let rhs = rightByLocator[candidate.rightLocator] else {
                throw EngineError.integrityFailure("fuzzy matching reused a transaction")
            }
            guard partition(lhs) == partition(rhs), lhs.amount == rhs.amount else {
                throw EngineError.integrityFailure("fuzzy match crossed a hard account, currency or amount gate")
            }
            matches.append(TransactionMatch(leftLocator: lhs.locator, rightLocator: rhs.locator, kind: .fuzzy))
            unmatchedLeft.remove(lhs.locator)
            unmatchedRight.remove(rhs.locator)
            exceptions += mutationExceptions(lhs, rhs)
        }

        let splitMerge = try splitMergeCandidates(
            left: unmatchedLeft.compactMap { leftByLocator[$0] },
            right: unmatchedRight.compactMap { rightByLocator[$0] },
            policy: policy
        )
        var splitMergeLeft: Set<String> = []
        var splitMergeRight: Set<String> = []
        for candidate in splitMerge {
            splitMergeLeft.formUnion(candidate.leftLocators)
            splitMergeRight.formUnion(candidate.rightLocators)
            exceptions.append(ReconciliationException(
                kind: .possibleSplitOrMerge,
                leftLocators: candidate.leftLocators,
                rightLocators: candidate.rightLocators,
                detail: "Possible split/merge in \(candidate.partition): exact combined amount \(candidate.amount)"
            ))
        }

        exceptions += crossPartitionStrongIDExceptions(
            unmatchedLeft.compactMap { leftByLocator[$0] },
            unmatchedRight.compactMap { rightByLocator[$0] }
        )

        for locator in unmatchedLeft.subtracting(splitMergeLeft).sorted() {
            let kind: ExceptionKind = job.mode == .bankVsLedger ? .missingFromLedger : .deletedFromNewerExport
            exceptions.append(ReconciliationException(kind: kind, leftLocators: [locator], detail: "No deterministic counterpart"))
        }
        for locator in unmatchedRight.subtracting(splitMergeRight).sorted() {
            let kind: ExceptionKind = job.mode == .bankVsLedger ? .unexpectedLedgerItem : .addedToNewerExport
            exceptions.append(ReconciliationException(kind: kind, rightLocators: [locator], detail: "No deterministic counterpart"))
        }

        exceptions = bindExceptionFingerprints(exceptions, left: left.transactions, right: right.transactions)
        let inconclusive = [left, right].contains { $0.completeness != .complete || !$0.invalidLocators.isEmpty }
        let totals = try partitionTotals(left: left.transactions, right: right.transactions)
        let arithmeticCloses = totals.allSatisfy { $0.difference == .zero } &&
            !exceptions.contains { $0.kind == .balanceDifference || $0.kind == .runningBalanceBreak }
        let state = resultState(exceptions: exceptions, decisions: job.decisions, inconclusive: inconclusive, arithmeticCloses: arithmeticCloses)
        return ReconciliationResult(
            state: state,
            matches: matches.sorted(by: matchOrder),
            exceptions: sorted(exceptions),
            totals: totals
        )
    }

    private func strongKey(_ transaction: CanonicalTransaction) -> StrongMatchKey? {
        guard let strongID = cleaned(transaction.strongID) else { return nil }
        return StrongMatchKey(partition: partition(transaction), identifier: strongID)
    }

    private func compositeKey(_ transaction: CanonicalTransaction) -> CompositeMatchKey? {
        guard let reference = cleaned(transaction.reference) else { return nil }
        return CompositeMatchKey(
            partition: partition(transaction),
            date: transaction.bookingDate,
            amount: transaction.amount,
            reference: reference
        )
    }

    private func validateMatchingPolicy(_ policy: MatchingPolicy) throws {
        guard (0...31).contains(policy.maximumDateDistanceDays),
              (0...1_000).contains(policy.minimumTextSimilarityPermille),
              (1...100_000).contains(policy.maximumFuzzyCandidatePairs),
              (1...512).contains(policy.maximumComparedTextScalars),
              (2...6).contains(policy.maximumSplitMergeGroupSize),
              (1...1_000_000).contains(policy.maximumSplitMergeEvaluations) else {
            throw EngineError.invalidConfiguration("matching policy is outside its bounded limits")
        }
    }

    private func fuzzyMatches(
        left: [CanonicalTransaction],
        right: [CanonicalTransaction],
        policy: MatchingPolicy
    ) throws -> (accepted: [FuzzyCandidate], ambiguous: [ReconciliationException]) {
        guard policy.fuzzyMatchingEnabled else { return ([], []) }
        var candidates: [FuzzyCandidate] = []
        for lhs in left.sorted(by: { $0.locator < $1.locator }) {
            for rhs in right.sorted(by: { $0.locator < $1.locator }) {
                guard partition(lhs) == partition(rhs), lhs.amount == rhs.amount else { continue }
                let distance = dateDistance(lhs.bookingDate, rhs.bookingDate)
                guard distance <= policy.maximumDateDistanceDays else { continue }
                if let leftID = cleaned(lhs.strongID), let rightID = cleaned(rhs.strongID), leftID != rightID { continue }
                guard let leftText = comparisonText(lhs, maximumScalars: policy.maximumComparedTextScalars),
                      let rightText = comparisonText(rhs, maximumScalars: policy.maximumComparedTextScalars) else { continue }
                let similarity = textSimilarityPermille(leftText, rightText)
                guard similarity >= policy.minimumTextSimilarityPermille else { continue }
                candidates.append(FuzzyCandidate(
                    leftLocator: lhs.locator,
                    rightLocator: rhs.locator,
                    similarityPermille: similarity,
                    dateDistanceDays: distance
                ))
                guard candidates.count <= policy.maximumFuzzyCandidatePairs else {
                    throw EngineError.resourceLimit("fuzzy candidate pairs")
                }
            }
        }

        let leftGroups = Dictionary(grouping: candidates, by: \.leftLocator)
        let rightGroups = Dictionary(grouping: candidates, by: \.rightLocator)
        var leftChoice: [String: FuzzyCandidate] = [:]
        var rightChoice: [String: FuzzyCandidate] = [:]
        var ambiguous: [ReconciliationException] = []
        var ambiguitySignatures: Set<String> = []

        for locator in leftGroups.keys.sorted() {
            guard let ranked = leftGroups[locator]?.sorted(by: fuzzyOrder), let first = ranked.first else { continue }
            let tied = ranked.filter { sameFuzzyRank($0, first) }
            if tied.count == 1 {
                leftChoice[locator] = first
            } else {
                let rights = tied.map(\.rightLocator).sorted()
                let signature = "L|\(locator)|\(rights.joined(separator: ","))"
                if ambiguitySignatures.insert(signature).inserted {
                    ambiguous.append(ReconciliationException(
                        kind: .ambiguousCandidate,
                        leftLocators: [locator], rightLocators: rights,
                        detail: "Fuzzy candidates tie at \(first.similarityPermille)/1000 similarity and \(first.dateDistanceDays) day distance"
                    ))
                }
            }
        }
        for locator in rightGroups.keys.sorted() {
            guard let ranked = rightGroups[locator]?.sorted(by: fuzzyOrder), let first = ranked.first else { continue }
            let tied = ranked.filter { sameFuzzyRank($0, first) }
            if tied.count == 1 {
                rightChoice[locator] = first
            } else {
                let lefts = tied.map(\.leftLocator).sorted()
                let signature = "R|\(lefts.joined(separator: ","))|\(locator)"
                if ambiguitySignatures.insert(signature).inserted {
                    ambiguous.append(ReconciliationException(
                        kind: .ambiguousCandidate,
                        leftLocators: lefts, rightLocators: [locator],
                        detail: "Fuzzy candidates tie at \(first.similarityPermille)/1000 similarity and \(first.dateDistanceDays) day distance"
                    ))
                }
            }
        }

        let accepted = leftChoice.values.filter { candidate in
            rightChoice[candidate.rightLocator] == candidate
        }.sorted(by: fuzzyOrder)
        return (accepted, ambiguous)
    }

    private func fuzzyOrder(_ lhs: FuzzyCandidate, _ rhs: FuzzyCandidate) -> Bool {
        if lhs.similarityPermille != rhs.similarityPermille { return lhs.similarityPermille > rhs.similarityPermille }
        if lhs.dateDistanceDays != rhs.dateDistanceDays { return lhs.dateDistanceDays < rhs.dateDistanceDays }
        return (lhs.leftLocator, lhs.rightLocator) < (rhs.leftLocator, rhs.rightLocator)
    }

    private func sameFuzzyRank(_ lhs: FuzzyCandidate, _ rhs: FuzzyCandidate) -> Bool {
        lhs.similarityPermille == rhs.similarityPermille && lhs.dateDistanceDays == rhs.dateDistanceDays
    }

    private func comparisonText(_ transaction: CanonicalTransaction, maximumScalars: Int) -> [UInt32]? {
        let source = [transaction.reference, transaction.description, transaction.payee, transaction.memo]
            .compactMap(cleaned)
            .joined(separator: " ")
        guard !source.isEmpty, source.unicodeScalars.count <= maximumScalars else { return nil }
        let folded = source.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var output: [UInt32] = []
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace, !output.isEmpty { output.append(32) }
                output.append(scalar.value)
                pendingSpace = false
            } else {
                pendingSpace = true
            }
        }
        return output.isEmpty ? nil : output
    }

    private func textSimilarityPermille(_ left: [UInt32], _ right: [UInt32]) -> Int {
        if left == right { return 1_000 }
        let longest = max(left.count, right.count)
        guard longest > 0 else { return 0 }
        var previous = Array(0...right.count)
        for leftIndex in left.indices {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1
            for rightIndex in right.indices {
                let substitution = previous[rightIndex] + (left[leftIndex] == right[rightIndex] ? 0 : 1)
                current[rightIndex + 1] = min(
                    min(previous[rightIndex + 1] + 1, current[rightIndex] + 1),
                    substitution
                )
            }
            previous = current
        }
        return ((longest - previous[right.count]) * 1_000) / longest
    }

    private func dateDistance(_ left: LocalDate, _ right: LocalDate) -> Int {
        abs(julianDay(left) - julianDay(right))
    }

    private func julianDay(_ date: LocalDate) -> Int {
        let a = (14 - date.month) / 12
        let y = date.year + 4_800 - a
        let m = date.month + (12 * a) - 3
        return date.day + ((153 * m + 2) / 5) + (365 * y) + (y / 4) - (y / 100) + (y / 400) - 32_045
    }

    private func splitMergeCandidates(
        left: [CanonicalTransaction],
        right: [CanonicalTransaction],
        policy: MatchingPolicy
    ) throws -> [SplitMergeCandidate] {
        guard policy.splitMergeCandidatesEnabled else { return [] }
        let leftGroups = Dictionary(grouping: left, by: partition)
        let rightGroups = Dictionary(grouping: right, by: partition)
        var evaluations = 0
        var unique: [String: SplitMergeCandidate] = [:]
        for key in Set(leftGroups.keys).intersection(rightGroups.keys).sorted() {
            let leftItems = (leftGroups[key] ?? []).sorted { $0.locator < $1.locator }
            let rightItems = (rightGroups[key] ?? []).sorted { $0.locator < $1.locator }
            let leftSingles = try oneToManyCandidates(
                singles: leftItems, components: rightItems, singleOnLeft: true,
                partition: key, policy: policy, evaluations: &evaluations
            )
            let rightSingles = try oneToManyCandidates(
                singles: rightItems, components: leftItems, singleOnLeft: false,
                partition: key, policy: policy, evaluations: &evaluations
            )
            for candidate in leftSingles + rightSingles { unique[candidate.signature] = candidate }
        }
        return unique.values.sorted {
            ($0.partition, $0.leftLocators.joined(), $0.rightLocators.joined()) <
            ($1.partition, $1.leftLocators.joined(), $1.rightLocators.joined())
        }
    }

    private func oneToManyCandidates(
        singles: [CanonicalTransaction],
        components: [CanonicalTransaction],
        singleOnLeft: Bool,
        partition: PartitionKey,
        policy: MatchingPolicy,
        evaluations: inout Int
    ) throws -> [SplitMergeCandidate] {
        guard components.count >= 2 else { return [] }
        var output: [SplitMergeCandidate] = []
        for single in singles where single.amount.mantissa != 0 {
            let eligible = components.filter {
                ($0.amount.mantissa > 0) == (single.amount.mantissa > 0) &&
                dateDistance($0.bookingDate, single.bookingDate) <= policy.maximumDateDistanceDays
            }
            guard eligible.count >= 2 else { continue }
            for size in 2...min(policy.maximumSplitMergeGroupSize, eligible.count) {
                try enumerateCombinations(
                    eligible, size: size, start: 0, selected: [],
                    evaluations: &evaluations, maximumEvaluations: policy.maximumSplitMergeEvaluations
                ) { values in
                    guard try sum(values) == single.amount else { return }
                    let componentLocators = values.map(\.locator).sorted()
                    output.append(SplitMergeCandidate(
                        leftLocators: singleOnLeft ? [single.locator] : componentLocators,
                        rightLocators: singleOnLeft ? componentLocators : [single.locator],
                        partition: partition,
                        amount: single.amount
                    ))
                }
            }
        }
        return output
    }

    private func enumerateCombinations(
        _ values: [CanonicalTransaction],
        size: Int,
        start: Int,
        selected: [CanonicalTransaction],
        evaluations: inout Int,
        maximumEvaluations: Int,
        body: ([CanonicalTransaction]) throws -> Void
    ) throws {
        if selected.count == size {
            evaluations += 1
            guard evaluations <= maximumEvaluations else { throw EngineError.resourceLimit("split/merge evaluations") }
            try body(selected)
            return
        }
        let remainingNeeded = size - selected.count
        guard values.count - start >= remainingNeeded else { return }
        for index in start...(values.count - remainingNeeded) {
            try enumerateCombinations(
                values, size: size, start: index + 1, selected: selected + [values[index]],
                evaluations: &evaluations, maximumEvaluations: maximumEvaluations, body: body
            )
        }
    }

    private func groupedUnique<Key: Hashable>(_ transactions: [CanonicalTransaction], key: (CanonicalTransaction) -> Key?) -> [Key: [CanonicalTransaction]] {
        Dictionary(grouping: transactions.compactMap { transaction -> (Key, CanonicalTransaction)? in
            key(transaction).map { ($0, transaction) }
        }, by: { $0.0 }).mapValues { pairs in pairs.map { $0.1 }.sorted { $0.locator < $1.locator } }
    }

    private func partition(_ transaction: CanonicalTransaction) -> PartitionKey {
        PartitionKey(account: transaction.account, currency: transaction.currency)
    }

    private func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func duplicateExceptions(_ transactions: [CanonicalTransaction], side: Side) -> [ReconciliationException] {
        var groups: [DuplicateIdentity: [CanonicalTransaction]] = [:]
        for transaction in transactions {
            let identity: DuplicateIdentity
            if let strongID = cleaned(transaction.strongID) {
                identity = .strong(partition(transaction), strongID)
            } else {
                identity = .signature(
                    partition(transaction), transaction.bookingDate, transaction.amount,
                    cleaned(transaction.reference), cleaned(transaction.description)
                )
            }
            groups[identity, default: []].append(transaction)
        }
        return groups.keys.sorted { $0.description < $1.description }.compactMap { identity in
            guard let values = groups[identity], values.count > 1 else { return nil }
            return ReconciliationException(
                kind: side == .left ? .duplicateInLeft : .duplicateInRight,
                leftLocators: side == .left ? values.map(\.locator) : [],
                rightLocators: side == .right ? values.map(\.locator) : [],
                detail: "Repeated identity: \(identity.description)"
            )
        }
    }

    private func mutationExceptions(_ left: CanonicalTransaction, _ right: CanonicalTransaction) -> [ReconciliationException] {
        var output: [ReconciliationException] = []
        let pair = (left: [left.locator], right: [right.locator])
        if left.amount != right.amount {
            output.append(ReconciliationException(kind: .amountChanged, leftLocators: pair.left, rightLocators: pair.right, detail: "\(left.amount) → \(right.amount)"))
        }
        if left.bookingDate != right.bookingDate || left.valueDate != right.valueDate {
            output.append(ReconciliationException(kind: .dateChanged, leftLocators: pair.left, rightLocators: pair.right, detail: "Booking or value date changed"))
        }
        if cleaned(left.strongID) != cleaned(right.strongID) || cleaned(left.reference) != cleaned(right.reference) || cleaned(left.description) != cleaned(right.description) || cleaned(left.memo) != cleaned(right.memo) || cleaned(left.payee) != cleaned(right.payee) || cleaned(left.transactionCode) != cleaned(right.transactionCode) {
            output.append(ReconciliationException(kind: .descriptionOrReferenceChanged, leftLocators: pair.left, rightLocators: pair.right, detail: "Strong ID, reference, description, memo, payee or transaction code changed"))
        }
        if cleaned(left.clearedStatus) != cleaned(right.clearedStatus) || cleaned(left.category) != cleaned(right.category) {
            output.append(ReconciliationException(kind: .statusOrCategoryChanged, leftLocators: pair.left, rightLocators: pair.right, detail: "Cleared status or category changed"))
        }
        return output
    }

    private func crossPartitionStrongIDExceptions(_ left: [CanonicalTransaction], _ right: [CanonicalTransaction]) -> [ReconciliationException] {
        let leftGroups = Dictionary(grouping: left.filter { cleaned($0.strongID) != nil }, by: { cleaned($0.strongID) ?? "" })
        let rightGroups = Dictionary(grouping: right.filter { cleaned($0.strongID) != nil }, by: { cleaned($0.strongID) ?? "" })
        return Set(leftGroups.keys).intersection(rightGroups.keys).sorted().compactMap { key in
            guard let lhs = leftGroups[key], let rhs = rightGroups[key],
                  Set(lhs.map(partition)).isDisjoint(with: Set(rhs.map(partition))) else { return nil }
            return ReconciliationException(
                kind: .currencyOrAccountMismatch,
                leftLocators: lhs.map(\.locator), rightLocators: rhs.map(\.locator),
                detail: "Strong identifier appears only in different account/currency partitions: \(key)"
            )
        }
    }

    private func structuralExceptions(_ source: SourceStatement, side: Side) -> [ReconciliationException] {
        source.invalidLocators.sorted().map {
            ReconciliationException(
                kind: .invalidRow,
                leftLocators: side == .left ? [$0] : [],
                rightLocators: side == .right ? [$0] : [],
                detail: "Source reported an invalid record"
            )
        }
    }

    private func runningBalanceExceptions(_ source: SourceStatement, side: Side) throws -> [ReconciliationException] {
        let groups = Dictionary(grouping: source.transactions, by: partition)
        let balanceGroups = Dictionary(grouping: source.balances.filter { $0.kind == .opening }, by: { PartitionKey(account: $0.account, currency: $0.currency) })
        var output: [ReconciliationException] = []
        for key in groups.keys.sorted() {
            guard let values = groups[key] else { continue }
            let ordered = values.sorted { ($0.bookingDate, $0.sourceOrdinal, $0.locator) < ($1.bookingDate, $1.sourceOrdinal, $1.locator) }
            var anchorBalance = balanceGroups[key]?.count == 1 ? balanceGroups[key]?[0].amount : nil
            var anchorLocator = balanceGroups[key]?.count == 1 ? balanceGroups[key]?[0].locator : nil
            var pendingActivity = ExactAmount.zero
            var pendingLocators: [String] = []
            for current in ordered {
                if anchorBalance != nil {
                    pendingActivity = try pendingActivity.adding(current.amount)
                    pendingLocators.append(current.locator)
                }
                if let currentBalance = current.runningBalance {
                    if let anchorBalance {
                        let expected = try anchorBalance.adding(pendingActivity)
                        if expected != currentBalance {
                            let locators = ([anchorLocator].compactMap { $0 } + pendingLocators)
                            output.append(ReconciliationException(
                                kind: .runningBalanceBreak,
                                leftLocators: side == .left ? locators : [],
                                rightLocators: side == .right ? locators : [],
                                detail: "\(key): expected \(expected), found \(currentBalance)"
                            ))
                        }
                    }
                    anchorBalance = currentBalance
                    anchorLocator = current.locator
                    pendingActivity = .zero
                    pendingLocators = []
                }
            }
        }
        return output
    }

    private func statementArithmeticExceptions(_ source: SourceStatement, side: Side) throws -> [ReconciliationException] {
        let transactionGroups = Dictionary(grouping: source.transactions, by: partition)
        let balanceGroups = Dictionary(grouping: source.balances, by: { PartitionKey(account: $0.account, currency: $0.currency) })
        var keys = Set(transactionGroups.keys)
        keys.formUnion(balanceGroups.keys)
        var output: [ReconciliationException] = []
        for key in keys.sorted() {
            let balances = balanceGroups[key] ?? []
            let openings = balances.filter { $0.kind == .opening }
            let closings = balances.filter { $0.kind == .closing }
            guard openings.count == 1, closings.count == 1 else {
                output.append(ReconciliationException(kind: .periodGapOrOverlap, detail: "\(key): expected exactly one opening and one closing balance"))
                continue
            }
            guard openings[0].date == source.period.start, closings[0].date == source.period.end else {
                output.append(ReconciliationException(
                    kind: .periodGapOrOverlap,
                    leftLocators: side == .left ? [openings[0].locator, closings[0].locator] : [],
                    rightLocators: side == .right ? [openings[0].locator, closings[0].locator] : [],
                    detail: "\(key): balance dates do not bound the selected period"
                ))
                continue
            }
            let activity = try sum(transactionGroups[key] ?? [])
            let expected = try openings[0].amount.adding(activity)
            if expected != closings[0].amount {
                output.append(ReconciliationException(
                    kind: .balanceDifference,
                    leftLocators: side == .left ? [openings[0].locator, closings[0].locator] : [],
                    rightLocators: side == .right ? [openings[0].locator, closings[0].locator] : [],
                    detail: "\(key): opening \(openings[0].amount) + activity \(activity) = \(expected), not \(closings[0].amount)"
                ))
            }
        }
        return output
    }

    private func compareStatementBalances(_ left: SourceStatement, _ right: SourceStatement) throws -> [ReconciliationException] {
        let leftGroups = Dictionary(grouping: left.balances, by: {
            BalanceComparisonKey(partition: PartitionKey(account: $0.account, currency: $0.currency), kind: $0.kind)
        })
        let rightGroups = Dictionary(grouping: right.balances, by: {
            BalanceComparisonKey(partition: PartitionKey(account: $0.account, currency: $0.currency), kind: $0.kind)
        })
        var output: [ReconciliationException] = []
        for key in Set(leftGroups.keys).union(rightGroups.keys).sorted() {
            let lhs = leftGroups[key] ?? []
            let rhs = rightGroups[key] ?? []
            guard lhs.count <= 1, rhs.count <= 1 else {
                output.append(ReconciliationException(kind: .periodGapOrOverlap, detail: "Multiple balance markers for \(key)"))
                continue
            }
            if lhs.first?.amount != rhs.first?.amount || lhs.first?.date != rhs.first?.date {
                output.append(ReconciliationException(
                    kind: .balanceDifference,
                    leftLocators: lhs.map(\.locator), rightLocators: rhs.map(\.locator),
                    detail: "Balance amount or date differs for \(key)"
                ))
            }
        }
        return output
    }

    private func partitionTotals(left: [CanonicalTransaction], right: [CanonicalTransaction]) throws -> [PartitionTotal] {
        let leftGroups = Dictionary(grouping: left, by: partition)
        let rightGroups = Dictionary(grouping: right, by: partition)
        return try Set(leftGroups.keys).union(rightGroups.keys).sorted().map { key in
            let leftTotal = try sum(leftGroups[key] ?? [])
            let rightTotal = try sum(rightGroups[key] ?? [])
            return PartitionTotal(
                partition: key,
                kind: .sourceActivityComparison,
                left: leftTotal,
                right: rightTotal,
                difference: try leftTotal.subtracting(rightTotal)
            )
        }
    }

    private func singleStatementTotals(_ source: SourceStatement) throws -> [PartitionTotal] {
        let transactionGroups = Dictionary(grouping: source.transactions, by: partition)
        let balanceGroups = Dictionary(grouping: source.balances, by: {
            PartitionKey(account: $0.account, currency: $0.currency)
        })
        return try Set(transactionGroups.keys).union(balanceGroups.keys).sorted().map { key in
            let activity = try sum(transactionGroups[key] ?? [])
            let balances = balanceGroups[key] ?? []
            let openings = balances.filter { $0.kind == .opening }
            let closings = balances.filter { $0.kind == .closing }
            let opening = openings.count == 1 ? openings[0].amount : .zero
            let closing = closings.count == 1 ? closings[0].amount : .zero
            let equationLeft = try opening.adding(activity)
            return PartitionTotal(
                partition: key,
                kind: .statementBalanceEquation,
                left: equationLeft,
                right: closing,
                difference: try equationLeft.subtracting(closing)
            )
        }
    }

    private func sum(_ transactions: [CanonicalTransaction]) throws -> ExactAmount {
        try transactions.reduce(.zero) { try $0.adding($1.amount) }
    }

    private func resultState(exceptions: [ReconciliationException], decisions: [UserDecision], inconclusive: Bool, arithmeticCloses: Bool) -> ResultState {
        if inconclusive || exceptions.contains(where: { $0.kind == .invalidRow || $0.kind == .periodGapOrOverlap || $0.kind == .ambiguousCandidate }) { return .cannotConclude }
        if exceptions.isEmpty { return .reconciled }
        let approvals = Set(decisions.filter { $0.approved && !$0.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.exceptionKey))
        let allExplained = exceptions.allSatisfy { approvals.contains(exceptionKey($0)) }
        return allExplained && arithmeticCloses ? .reconciledWithExplanations : .differenceFound
    }

    public func exceptionKey(_ value: ReconciliationException) -> String {
        Hashing.sha256("\(value.kind.rawValue)|\(value.leftLocators.joined(separator: ","))|\(value.rightLocators.joined(separator: ","))|\(value.sourceFingerprints.joined(separator: ","))|\(value.detail)")
    }

    private func bindExceptionFingerprints(
        _ exceptions: [ReconciliationException],
        left: [CanonicalTransaction],
        right: [CanonicalTransaction]
    ) -> [ReconciliationException] {
        let leftByLocator = Dictionary(uniqueKeysWithValues: left.map { ($0.locator, $0) })
        let rightByLocator = Dictionary(uniqueKeysWithValues: right.map { ($0.locator, $0) })
        return exceptions.map { value in
            var fingerprints = value.sourceFingerprints
            fingerprints += value.leftLocators.compactMap { locator in leftByLocator[locator].map { "L:\(locator):\(transactionFingerprint($0))" } }
            fingerprints += value.rightLocators.compactMap { locator in rightByLocator[locator].map { "R:\(locator):\(transactionFingerprint($0))" } }
            return ReconciliationException(
                kind: value.kind,
                leftLocators: value.leftLocators,
                rightLocators: value.rightLocators,
                sourceFingerprints: fingerprints,
                detail: value.detail
            )
        }
    }

    public func transactionFingerprint(_ value: CanonicalTransaction) -> String {
        func field(_ value: String?) -> String {
            let text = value ?? "<nil>"
            return "\(text.utf8.count):\(text)"
        }
        let original = value.originalValues.keys.sorted().map { field($0) + field(value.originalValues[$0]) }.joined()
        let content = [
            field(value.sourceID), field(value.locator), field(String(value.sourceOrdinal)), field(value.account), field(value.currency.value),
            field(value.bookingDate.description), field(value.valueDate?.description), field(value.amount.description),
            field(value.runningBalance?.description), field(value.strongID), field(value.reference), field(value.payee),
            field(value.description), field(value.memo), field(value.transactionCode), field(value.clearedStatus),
            field(value.category), field(original), field(value.derivedFields.sorted().joined(separator: "\u{1f}"))
        ].joined(separator: "|")
        return Hashing.sha256(content)
    }

    private func sorted(_ values: [ReconciliationException]) -> [ReconciliationException] {
        values.sorted {
            ($0.kind.rawValue, $0.leftLocators.joined(), $0.rightLocators.joined(), $0.sourceFingerprints.joined(), $0.detail) <
            ($1.kind.rawValue, $1.leftLocators.joined(), $1.rightLocators.joined(), $1.sourceFingerprints.joined(), $1.detail)
        }
    }

    private func matchOrder(_ lhs: TransactionMatch, _ rhs: TransactionMatch) -> Bool {
        (lhs.leftLocator, lhs.rightLocator, lhs.kind.rawValue) < (rhs.leftLocator, rhs.rightLocator, rhs.kind.rawValue)
    }
}
