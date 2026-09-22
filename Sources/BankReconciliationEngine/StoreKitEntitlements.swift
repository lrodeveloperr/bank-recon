import Foundation
import StoreKit

public struct StoreKitProductCatalog: Sendable, Hashable {
    public let proProductID: String
    public let accountantProductID: String

    public init(
        proProductID: String = "com.worksbienstudios.bankreconciliation.pro",
        accountantProductID: String = "com.worksbienstudios.bankreconciliation.accountant"
    ) {
        self.proProductID = proProductID
        self.accountantProductID = accountantProductID
    }

    public var productIDs: Set<String> { [proProductID, accountantProductID] }

    public func tier(for productID: String) -> EntitlementTier? {
        if productID == accountantProductID { return .accountant }
        if productID == proProductID { return .pro }
        return nil
    }
}

public actor StoreKitEntitlementService: EntitlementProviding {
    public let catalog: StoreKitProductCatalog

    public init(catalog: StoreKitProductCatalog = StoreKitProductCatalog()) { self.catalog = catalog }

    public func refresh() async -> EntitlementSnapshot {
        var verified: Set<String> = []
        var tier: EntitlementTier = .free
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil,
                  transaction.productType == .nonConsumable,
                  let transactionTier = catalog.tier(for: transaction.productID) else { continue }
            verified.insert(transaction.productID)
            tier = max(tier, transactionTier)
        }
        return EntitlementSnapshot(tier: tier, verifiedProductIDs: verified, verifiedAt: Self.timestamp())
    }

    public func availableProducts() async throws -> [StoreProductDescriptor] {
        let products = try await Product.products(for: catalog.productIDs)
        return products.compactMap { product in
            guard let tier = catalog.tier(for: product.id) else { return nil }
            return StoreProductDescriptor(
                id: product.id,
                tier: tier,
                displayName: product.displayName,
                displayPrice: product.displayPrice
            )
        }.sorted { $0.tier < $1.tier }
    }

    public func purchase(_ tier: EntitlementTier) async throws -> PurchaseOutcome {
        guard tier != .free else { return .purchased(await refresh()) }
        let productID = tier == .accountant ? catalog.accountantProductID : catalog.proProductID
        guard let product = try await Product.products(for: [productID]).first else {
            throw EngineError.notFound("StoreKit product \(productID)")
        }
        switch try await product.purchase() {
        case .success(let verification):
            guard case .verified(let transaction) = verification,
                  transaction.productID == productID,
                  transaction.revocationDate == nil else {
                throw EngineError.purchaseVerificationFailed
            }
            await transaction.finish()
            return .purchased(await refresh())
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            throw EngineError.purchaseVerificationFailed
        }
    }

    public func restore() async throws -> EntitlementSnapshot {
        try await AppStore.sync()
        return await refresh()
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
