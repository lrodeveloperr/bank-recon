import Foundation

public enum EntitlementTier: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case free
    case pro
    case accountant

    private var rank: Int {
        switch self {
        case .free: 0
        case .pro: 1
        case .accountant: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public struct EntitlementSnapshot: Codable, Sendable, Hashable {
    public let tier: EntitlementTier
    public let verifiedProductIDs: Set<String>
    public let verifiedAt: String

    public init(tier: EntitlementTier, verifiedProductIDs: Set<String> = [], verifiedAt: String) {
        self.tier = tier
        self.verifiedProductIDs = verifiedProductIDs
        self.verifiedAt = verifiedAt
    }

    public static let unverifiedFree = EntitlementSnapshot(
        tier: .free,
        verifiedAt: "1970-01-01T00:00:00Z"
    )
}

public struct EntitlementPolicy: Sendable {
    public static let freeLockedReconciliationLimit = 2

    public init() {}

    public func permitsLock(existingRealLocks: Int, tier: EntitlementTier) -> Bool {
        tier >= .pro || existingRealLocks < Self.freeLockedReconciliationLimit
    }

    public func permitsWorkspace(existingWorkspaceCount: Int, tier: EntitlementTier) -> Bool {
        tier == .accountant || existingWorkspaceCount < 1
    }

    public func permitsSourceProfile(existingProfileCount: Int, tier: EntitlementTier) -> Bool {
        tier >= .pro || existingProfileCount < 1
    }

    public func permitsBrandedEvidence(tier: EntitlementTier) -> Bool { tier == .accountant }
}

public struct StoreProductDescriptor: Sendable, Hashable, Identifiable {
    public let id: String
    public let tier: EntitlementTier
    public let displayName: String
    public let displayPrice: String

    public init(id: String, tier: EntitlementTier, displayName: String, displayPrice: String) {
        self.id = id
        self.tier = tier
        self.displayName = displayName
        self.displayPrice = displayPrice
    }
}

public enum PurchaseOutcome: Sendable, Hashable {
    case purchased(EntitlementSnapshot)
    case pending
    case cancelled
}

public protocol EntitlementProviding: Sendable {
    func refresh() async -> EntitlementSnapshot
    func availableProducts() async throws -> [StoreProductDescriptor]
    func purchase(_ tier: EntitlementTier) async throws -> PurchaseOutcome
    func restore() async throws -> EntitlementSnapshot
}

public actor FixedEntitlementProvider: EntitlementProviding {
    private var snapshot: EntitlementSnapshot

    public init(snapshot: EntitlementSnapshot = .unverifiedFree) { self.snapshot = snapshot }

    public func set(_ snapshot: EntitlementSnapshot) { self.snapshot = snapshot }
    public func refresh() async -> EntitlementSnapshot { snapshot }
    public func availableProducts() async throws -> [StoreProductDescriptor] { [] }
    public func purchase(_ tier: EntitlementTier) async throws -> PurchaseOutcome {
        guard tier != .free else { return .purchased(snapshot) }
        throw EngineError.invalidConfiguration("purchases are unavailable from the fixed entitlement provider")
    }
    public func restore() async throws -> EntitlementSnapshot { snapshot }
}
