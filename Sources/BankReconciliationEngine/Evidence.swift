import Foundation

public struct EvidenceSourceBlob: Hashable, Codable, Sendable {
    public let sourceID: String
    public let sha256: String
    public let data: Data

    public init(sourceID: String, sha256: String, data: Data) {
        self.sourceID = sourceID
        self.sha256 = sha256
        self.data = data
    }
}

public struct LockedEvidence: Hashable, Codable, Sendable {
    public let schemaVersion: Int
    public let evidenceID: String
    public let jobID: UUID
    public let jobSHA256: String
    public let lockedAt: String
    public let resultSHA256: String
    public let sourceBlobs: [EvidenceSourceBlob]
    public let canonicalManifest: Data
    public let manifestSHA256: String

    public init(
        schemaVersion: Int,
        evidenceID: String,
        jobID: UUID,
        jobSHA256: String,
        lockedAt: String,
        resultSHA256: String,
        sourceBlobs: [EvidenceSourceBlob],
        canonicalManifest: Data,
        manifestSHA256: String
    ) {
        self.schemaVersion = schemaVersion
        self.evidenceID = evidenceID
        self.jobID = jobID
        self.jobSHA256 = jobSHA256
        self.lockedAt = lockedAt
        self.resultSHA256 = resultSHA256
        self.sourceBlobs = sourceBlobs
        self.canonicalManifest = canonicalManifest
        self.manifestSHA256 = manifestSHA256
    }
}

public struct EvidenceLocker: Sendable {
    public static let schemaVersion = 2
    public static let engineVersion = "0.2.0-recovery"

    public init() {}

    public func lock(
        job: ReconciliationJob,
        result: ReconciliationResult,
        sourceBytesByID: [String: Data],
        lockedAt: String,
        router: FormatRouter = FormatRouter()
    ) throws -> LockedEvidence {
        try validateTimestamp(lockedAt)
        var sourceBlobs: [EvidenceSourceBlob] = []
        for source in job.sources.sorted(by: { $0.file.sourceID < $1.file.sourceID }) {
            guard let bytes = sourceBytesByID[source.file.sourceID] else {
                throw EngineError.integrityFailure("missing immutable bytes for \(source.file.sourceID)")
            }
            guard bytes.count == source.file.byteCount, Hashing.sha256(bytes) == source.file.sha256 else {
                throw EngineError.integrityFailure("source byte proof changed for \(source.file.sourceID)")
            }
            let replayed = try router.parse(
                data: bytes,
                filename: source.file.filename,
                role: source.role,
                period: source.period,
                replay: source.replay
            )
            guard replayed == source else {
                throw EngineError.integrityFailure("normalized source does not reproduce from bound bytes and replay descriptor: \(source.file.sourceID)")
            }
            if !sourceBlobs.contains(where: { $0.sourceID == source.file.sourceID }) {
                sourceBlobs.append(EvidenceSourceBlob(sourceID: source.file.sourceID, sha256: source.file.sha256, data: bytes))
            }
        }
        let rerun = try ReconciliationEngine().run(job)
        guard rerun == result else { throw EngineError.integrityFailure("result is not reproducible") }

        let manifest = try canonicalManifest(job: job, result: result, lockedAt: lockedAt)
        let digest = Hashing.sha256(manifest)
        return LockedEvidence(
            schemaVersion: Self.schemaVersion,
            evidenceID: "evidence-\(digest.prefix(24))",
            jobID: job.id,
            jobSHA256: try jobSHA256(job),
            lockedAt: lockedAt,
            resultSHA256: try resultSHA256(result),
            sourceBlobs: sourceBlobs,
            canonicalManifest: manifest,
            manifestSHA256: digest
        )
    }

    public func verify(_ evidence: LockedEvidence) throws {
        guard evidence.schemaVersion == Self.schemaVersion else { throw EngineError.integrityFailure("unsupported evidence schema") }
        let digest = Hashing.sha256(evidence.canonicalManifest)
        guard digest == evidence.manifestSHA256,
              evidence.evidenceID == "evidence-\(digest.prefix(24))" else {
            throw EngineError.integrityFailure("evidence digest mismatch")
        }
        let object = try JSONSerialization.jsonObject(with: evidence.canonicalManifest)
        guard let manifest = object as? [String: Any],
              manifest["schemaVersion"] as? Int == Self.schemaVersion,
              manifest["lockedAt"] as? String == evidence.lockedAt,
              let job = manifest["job"] as? [String: Any],
              job["id"] as? String == evidence.jobID.uuidString.lowercased(),
              let result = manifest["result"] else {
            throw EngineError.integrityFailure("evidence bindings are missing")
        }
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard canonical == evidence.canonicalManifest else { throw EngineError.integrityFailure("manifest is not canonical JSON") }
        let resultData = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
        let jobData = try JSONSerialization.data(withJSONObject: job, options: [.sortedKeys, .withoutEscapingSlashes])
        guard Hashing.sha256(resultData) == evidence.resultSHA256,
              Hashing.sha256(jobData) == evidence.jobSHA256 else {
            throw EngineError.integrityFailure("result binding mismatch")
        }
        guard Set(evidence.sourceBlobs.map(\.sourceID)).count == evidence.sourceBlobs.count else {
            throw EngineError.integrityFailure("duplicate retained source blob")
        }
        for blob in evidence.sourceBlobs where Hashing.sha256(blob.data) != blob.sha256 {
            throw EngineError.integrityFailure("retained source blob hash mismatch")
        }
        guard let sources = job["sources"] as? [[String: Any]] else {
            throw EngineError.integrityFailure("manifest sources are missing")
        }
        var expectedProofs: [String: (String, Int)] = [:]
        for source in sources {
            guard let file = source["file"] as? [String: Any],
                  let sourceID = file["sourceID"] as? String,
                  let sha256 = file["sha256"] as? String,
                  let byteCount = file["byteCount"] as? Int else {
                throw EngineError.integrityFailure("manifest source proof is malformed")
            }
            if let prior = expectedProofs[sourceID], prior != (sha256, byteCount) {
                throw EngineError.integrityFailure("conflicting source proofs")
            }
            expectedProofs[sourceID] = (sha256, byteCount)
        }
        let retained = Dictionary(uniqueKeysWithValues: evidence.sourceBlobs.map { ($0.sourceID, $0) })
        guard Set(expectedProofs.keys) == Set(retained.keys) else {
            throw EngineError.integrityFailure("retained source set does not match manifest")
        }
        for (sourceID, proof) in expectedProofs {
            guard let blob = retained[sourceID], blob.sha256 == proof.0, blob.data.count == proof.1 else {
                throw EngineError.integrityFailure("retained source proof mismatch")
            }
        }
    }

    public func verify(
        _ evidence: LockedEvidence,
        job: ReconciliationJob,
        result: ReconciliationResult,
        router: FormatRouter = FormatRouter()
    ) throws {
        try verify(evidence)
        guard evidence.jobID == job.id,
              evidence.jobSHA256 == (try jobSHA256(job)),
              evidence.resultSHA256 == (try resultSHA256(result)) else {
            throw EngineError.integrityFailure("evidence is bound to another job or result")
        }
        let retained = Dictionary(uniqueKeysWithValues: evidence.sourceBlobs.map { ($0.sourceID, $0.data) })
        for source in job.sources {
            guard let data = retained[source.file.sourceID] else { throw EngineError.integrityFailure("retained source is missing") }
            let replayed = try router.parse(
                data: data,
                filename: source.file.filename,
                role: source.role,
                period: source.period,
                replay: source.replay
            )
            guard replayed == source else { throw EngineError.integrityFailure("retained source replay mismatch") }
        }
        guard try ReconciliationEngine().run(job) == result else {
            throw EngineError.integrityFailure("retained result no longer reproduces")
        }
    }

    public func jobSHA256(_ job: ReconciliationJob) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: jobObject(job), options: [.sortedKeys, .withoutEscapingSlashes])
        return Hashing.sha256(data)
    }

    public func resultSHA256(_ result: ReconciliationResult) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: resultObject(result), options: [.sortedKeys, .withoutEscapingSlashes])
        return Hashing.sha256(data)
    }

    private func validateTimestamp(_ value: String) throws {
        let bytes = Array(value.utf8)
        guard bytes.count == 20,
              bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
              bytes[13] == 58, bytes[16] == 58, bytes[19] == 90,
              bytes.enumerated().allSatisfy({ pair in
                  let (index, byte) = pair
                  return [4, 7, 10, 13, 16, 19].contains(index) || (48...57).contains(byte)
              }),
              let hour = Int(String(decoding: bytes[11..<13], as: UTF8.self)),
              let minute = Int(String(decoding: bytes[14..<16], as: UTF8.self)),
              let second = Int(String(decoding: bytes[17..<19], as: UTF8.self)),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else {
            throw EngineError.invalidConfiguration("lockedAt must be whole-second UTC RFC 3339")
        }
        _ = try LocalDate(iso8601: String(decoding: bytes[0..<10], as: UTF8.self))
    }

    private func canonicalManifest(job: ReconciliationJob, result: ReconciliationResult, lockedAt: String) throws -> Data {
        let object: [String: Any] = [
            "schemaVersion": Self.schemaVersion,
            "engineVersion": Self.engineVersion,
            "lockedAt": lockedAt,
            "limitation": "Proves only the supplied files and recorded decisions; not bank, accounting, tax, legal or audit assurance.",
            "job": jobObject(job),
            "result": resultObject(result)
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func jobObject(_ job: ReconciliationJob) -> [String: Any] {
        let policy = job.matchingPolicy ?? .default
        return [
            "id": job.id.uuidString.lowercased(),
            "mode": job.mode.rawValue,
            "period": periodObject(job.period),
            "matchingPolicy": [
                "fuzzyMatchingEnabled": policy.fuzzyMatchingEnabled,
                "maximumDateDistanceDays": policy.maximumDateDistanceDays,
                "minimumTextSimilarityPermille": policy.minimumTextSimilarityPermille,
                "maximumFuzzyCandidatePairs": policy.maximumFuzzyCandidatePairs,
                "maximumComparedTextScalars": policy.maximumComparedTextScalars,
                "splitMergeCandidatesEnabled": policy.splitMergeCandidatesEnabled,
                "maximumSplitMergeGroupSize": policy.maximumSplitMergeGroupSize,
                "maximumSplitMergeEvaluations": policy.maximumSplitMergeEvaluations
            ],
            "sources": job.sources.sorted { ($0.role.rawValue, $0.file.sourceID) < ($1.role.rawValue, $1.file.sourceID) }.map(sourceObject),
            "manualMatches": job.manualMatches.sorted { ($0.leftLocator, $0.rightLocator) < ($1.leftLocator, $1.rightLocator) }.map {
                [
                    "leftLocator": $0.leftLocator,
                    "rightLocator": $0.rightLocator,
                    "leftFingerprint": $0.leftFingerprint,
                    "rightFingerprint": $0.rightFingerprint
                ]
            },
            "decisions": job.decisions.sorted { ($0.exceptionKey, $0.explanation, $0.approved ? 1 : 0) < ($1.exceptionKey, $1.explanation, $1.approved ? 1 : 0) }.map {
                ["exceptionKey": $0.exceptionKey, "explanation": $0.explanation, "approved": $0.approved]
            }
        ]
    }

    private func sourceObject(_ source: SourceStatement) -> [String: Any] {
        [
            "role": source.role.rawValue,
            "file": [
                "sourceID": source.file.sourceID,
                "filename": source.file.filename,
                "byteCount": source.file.byteCount,
                "sha256": source.file.sha256
            ],
            "replay": replayObject(source.replay),
            "period": periodObject(source.period),
            "transactions": source.transactions.sorted { $0.locator < $1.locator }.map(transactionObject),
            "balances": source.balances.sorted { ($0.account, $0.currency, $0.kind.rawValue, $0.date, $0.locator) < ($1.account, $1.currency, $1.kind.rawValue, $1.date, $1.locator) }.map {
                [
                    "kind": $0.kind.rawValue,
                    "account": $0.account,
                    "currency": $0.currency.value,
                    "date": $0.date.description,
                    "amount": amountObject($0.amount),
                    "locator": $0.locator
                ]
            },
            "completeness": source.completeness.rawValue,
            "warnings": source.warnings.sorted(),
            "invalidLocators": source.invalidLocators.sorted()
        ]
    }

    private func replayObject(_ replay: ParseReplayDescriptor) -> [String: Any] {
        let structuredProfile: Any
        if let profile = replay.structuredProfile {
            structuredProfile = [
                "dateOrder": profile.dateOrder.rawValue,
                "decimalSeparator": profile.decimalSeparator,
                "groupingSeparator": jsonValue(profile.groupingSeparator),
                "defaultAccount": jsonValue(profile.defaultAccount),
                "defaultCurrency": jsonValue(profile.defaultCurrency)
            ] as [String: Any]
        } else {
            structuredProfile = NSNull()
        }
        var output: [String: Any] = [
            "format": replay.format.rawValue,
            "parserVersion": replay.parserVersion,
            "selectedWorksheet": jsonValue(replay.selectedWorksheet),
            "structuredProfile": structuredProfile,
            "balanceOverrides": replay.balanceOverrides.sorted {
                ($0.account, $0.currency, $0.kind.rawValue, $0.date, $0.locator) <
                ($1.account, $1.currency, $1.kind.rawValue, $1.date, $1.locator)
            }.map {
                [
                    "kind": $0.kind.rawValue,
                    "account": $0.account,
                    "currency": $0.currency.value,
                    "date": $0.date.description,
                    "amount": amountObject($0.amount),
                    "locator": $0.locator
                ]
            }
        ]
        if let mapping = replay.delimitedMapping {
            output["delimitedMapping"] = [
                "delimiter": String(mapping.delimiter),
                "hasHeader": mapping.hasHeader,
                "dateColumn": mapping.dateColumn,
                "amountColumn": mapping.amountColumn,
                "accountColumn": jsonValue(mapping.accountColumn),
                "currencyColumn": jsonValue(mapping.currencyColumn),
                "strongIDColumn": jsonValue(mapping.strongIDColumn),
                "referenceColumn": jsonValue(mapping.referenceColumn),
                "descriptionColumn": jsonValue(mapping.descriptionColumn),
                "runningBalanceColumn": jsonValue(mapping.runningBalanceColumn),
                "dateOrder": mapping.dateOrder.rawValue,
                "decimalSeparator": String(mapping.decimalSeparator),
                "groupingSeparator": jsonValue(mapping.groupingSeparator.map { String($0) }),
                "defaultAccount": jsonValue(mapping.defaultAccount),
                "defaultCurrency": jsonValue(mapping.defaultCurrency)
            ]
        } else {
            output["delimitedMapping"] = NSNull()
        }
        return output
    }

    private func transactionObject(_ transaction: CanonicalTransaction) -> [String: Any] {
        [
            "sourceID": transaction.sourceID,
            "locator": transaction.locator,
            "sourceOrdinal": transaction.sourceOrdinal,
            "account": transaction.account,
            "currency": transaction.currency.value,
            "bookingDate": transaction.bookingDate.description,
            "valueDate": jsonValue(transaction.valueDate?.description),
            "amount": amountObject(transaction.amount),
            "runningBalance": jsonValue(transaction.runningBalance.map(amountObject)),
            "strongID": jsonValue(transaction.strongID),
            "reference": jsonValue(transaction.reference),
            "payee": jsonValue(transaction.payee),
            "description": jsonValue(transaction.description),
            "memo": jsonValue(transaction.memo),
            "transactionCode": jsonValue(transaction.transactionCode),
            "clearedStatus": jsonValue(transaction.clearedStatus),
            "category": jsonValue(transaction.category),
            "originalValues": transaction.originalValues,
            "derivedFields": transaction.derivedFields.sorted()
        ]
    }

    private func resultObject(_ result: ReconciliationResult) -> [String: Any] {
        [
            "state": result.state.rawValue,
            "matches": result.matches.sorted { ($0.leftLocator, $0.rightLocator, $0.kind.rawValue) < ($1.leftLocator, $1.rightLocator, $1.kind.rawValue) }.map {
                ["leftLocator": $0.leftLocator, "rightLocator": $0.rightLocator, "kind": $0.kind.rawValue]
            },
            "exceptions": result.exceptions.sorted { ($0.kind.rawValue, $0.leftLocators.joined(), $0.rightLocators.joined(), $0.sourceFingerprints.joined(), $0.detail) < ($1.kind.rawValue, $1.leftLocators.joined(), $1.rightLocators.joined(), $1.sourceFingerprints.joined(), $1.detail) }.map {
                ["kind": $0.kind.rawValue, "leftLocators": $0.leftLocators, "rightLocators": $0.rightLocators, "sourceFingerprints": $0.sourceFingerprints, "detail": $0.detail]
            },
            "totals": result.totals.sorted { $0.partition < $1.partition }.map {
                [
                    "account": $0.partition.account,
                    "currency": $0.partition.currency.value,
                    "kind": $0.kind.rawValue,
                    "left": amountObject($0.left),
                    "right": amountObject($0.right),
                    "difference": amountObject($0.difference)
                ]
            }
        ]
    }

    private func periodObject(_ period: ReconciliationPeriod) -> [String: Any] {
        ["start": period.start.description, "end": period.end.description]
    }

    private func amountObject(_ amount: ExactAmount) -> [String: Any] {
        ["mantissa": amount.mantissa, "scale": Int(amount.scale), "canonical": amount.description]
    }

    private func jsonValue<T>(_ value: T?) -> Any {
        if let value { return value }
        return NSNull()
    }
}
