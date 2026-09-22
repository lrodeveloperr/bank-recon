import StoreKit
import StoreKitTest
import XCTest
@testable import BankReconciliationEngine

@MainActor
final class StoreKitLifecycleTests: XCTestCase {
    private let catalog = StoreKitProductCatalog()

    private func makeSession() throws -> SKTestSession {
        let session = try SKTestSession(configurationFileNamed: "BankReconciliation")
        session.disableDialogs = true
        session.resetToDefaultState()
        session.clearTransactions()
        return session
    }

    func testCatalogLoadsBothLocalizedNonConsumablesAtConfiguredUSPrices() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let products = try await Product.products(for: catalog.productIDs)
        XCTAssertEqual(Set(products.map(\.id)), catalog.productIDs)
        XCTAssertTrue(products.allSatisfy { $0.type == .nonConsumable })
        XCTAssertEqual(products.first(where: { $0.id == catalog.proProductID })?.price, Decimal(string: "39.99"))
        XCTAssertEqual(products.first(where: { $0.id == catalog.accountantProductID })?.price, Decimal(string: "99.99"))
    }

    func testExternalPurchaseAndRelaunchSelectHighestVerifiedTier() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        _ = try await session.buyProduct(identifier: catalog.proProductID, options: [])
        let service = StoreKitEntitlementService(catalog: catalog)
        let pro = await service.refresh()
        XCTAssertEqual(pro.tier, .pro)
        XCTAssertEqual(pro.verifiedProductIDs, [catalog.proProductID])

        _ = try await session.buyProduct(identifier: catalog.accountantProductID, options: [])
        let relaunchedService = StoreKitEntitlementService(catalog: catalog)
        let accountant = await relaunchedService.refresh()
        XCTAssertEqual(accountant.tier, .accountant)
        XCTAssertEqual(accountant.verifiedProductIDs, catalog.productIDs)
    }

    func testRefundRemovesNonConsumableEntitlement() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let purchased = try await session.buyProduct(identifier: catalog.proProductID, options: [])
        let service = StoreKitEntitlementService(catalog: catalog)
        let purchasedSnapshot = await service.refresh()
        XCTAssertEqual(purchasedSnapshot.tier, .pro)

        try session.refundTransaction(identifier: UInt(purchased.id))
        try await waitForEntitlement(service, tier: .free)
        let refundedSnapshot = await service.refresh()
        XCTAssertTrue(refundedSnapshot.verifiedProductIDs.isEmpty)
    }

    func testAskToBuyStaysLockedUntilApproved() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        session.askToBuyEnabled = true
        try session.buyProduct(productIdentifier: catalog.proProductID)
        let pendingTransaction = try XCTUnwrap(session.allTransactions().last)
        let service = StoreKitEntitlementService(catalog: catalog)
        let pendingSnapshot = await service.refresh()
        XCTAssertEqual(pendingSnapshot.tier, .free)

        try session.approveAskToBuyTransaction(identifier: pendingTransaction.identifier)
        try await waitForEntitlement(service, tier: .pro)
    }

    func testInterruptedPurchaseFailsClosedUntilIssueIsResolved() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        session.interruptedPurchasesEnabled = true
        try session.buyProduct(productIdentifier: catalog.accountantProductID)
        let interruptedTransaction = try XCTUnwrap(session.allTransactions().last)
        let service = StoreKitEntitlementService(catalog: catalog)
        let interruptedSnapshot = await service.refresh()
        XCTAssertEqual(interruptedSnapshot.tier, .free)

        session.interruptedPurchasesEnabled = false
        try session.resolveIssueForTransaction(identifier: interruptedTransaction.identifier)
        try await waitForEntitlement(service, tier: .accountant)
    }

    private func waitForEntitlement(
        _ service: StoreKitEntitlementService,
        tier: EntitlementTier,
        attempts: Int = 20
    ) async throws {
        for _ in 0..<attempts {
            if (await service.refresh()).tier == tier { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("entitlement did not become \(tier)")
    }
}
