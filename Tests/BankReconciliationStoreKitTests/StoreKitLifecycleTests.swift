import StoreKit
import StoreKitTest
import XCTest
@testable import BankReconciliationEngine

@MainActor
final class StoreKitLifecycleTests: XCTestCase {
    private var session: SKTestSession!
    private let catalog = StoreKitProductCatalog()

    override func setUpWithError() throws {
        session = try SKTestSession(configurationFileNamed: "BankReconciliation")
        session.disableDialogs = true
        session.resetToDefaultState()
        session.clearTransactions()
    }

    override func tearDownWithError() throws {
        session.clearTransactions()
        session = nil
    }

    func testCatalogLoadsBothLocalizedNonConsumablesAtConfiguredUSPrices() async throws {
        let products = try await Product.products(for: catalog.productIDs)
        XCTAssertEqual(Set(products.map(\.id)), catalog.productIDs)
        XCTAssertTrue(products.allSatisfy { $0.type == .nonConsumable })
        XCTAssertEqual(products.first(where: { $0.id == catalog.proProductID })?.price, Decimal(string: "39.99"))
        XCTAssertEqual(products.first(where: { $0.id == catalog.accountantProductID })?.price, Decimal(string: "99.99"))
    }

    func testPurchaseAndRestoreSelectHighestVerifiedTier() async throws {
        _ = try await session.buyProduct(identifier: catalog.proProductID, options: [])
        let service = StoreKitEntitlementService(catalog: catalog)
        let pro = await service.refresh()
        XCTAssertEqual(pro.tier, .pro)
        XCTAssertEqual(pro.verifiedProductIDs, [catalog.proProductID])

        _ = try await session.buyProduct(identifier: catalog.accountantProductID, options: [])
        let accountant = try await service.restore()
        XCTAssertEqual(accountant.tier, .accountant)
        XCTAssertEqual(accountant.verifiedProductIDs, catalog.productIDs)
    }

    func testRefundRemovesNonConsumableEntitlement() async throws {
        let purchased = try await session.buyProduct(identifier: catalog.proProductID, options: [])
        let service = StoreKitEntitlementService(catalog: catalog)
        let purchasedSnapshot = await service.refresh()
        XCTAssertEqual(purchasedSnapshot.tier, .pro)

        try session.refundTransaction(identifier: Int(purchased.id))
        try await waitForEntitlement(service, tier: .free)
        let refundedSnapshot = await service.refresh()
        XCTAssertTrue(refundedSnapshot.verifiedProductIDs.isEmpty)
    }

    func testAskToBuyReturnsPendingWithoutUnlocking() async throws {
        session.askToBuyEnabled = true
        let service = StoreKitEntitlementService(catalog: catalog)
        let outcome = try await service.purchase(.pro)
        XCTAssertEqual(outcome, .pending)
        let snapshot = await service.refresh()
        XCTAssertEqual(snapshot.tier, .free)
    }

    func testInterruptedPurchaseFailsClosed() async throws {
        session.interruptedPurchasesEnabled = true
        let service = StoreKitEntitlementService(catalog: catalog)
        do {
            _ = try await service.purchase(.accountant)
            XCTFail("interrupted purchase must not unlock Accountant")
        } catch {
            let snapshot = await service.refresh()
            XCTAssertEqual(snapshot.tier, .free)
        }
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
