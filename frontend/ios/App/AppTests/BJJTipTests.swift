import XCTest
import StoreKit
import StoreKitTest
@testable import App

@MainActor final class BJJTipTests: XCTestCase {
    private let launch = Date(timeIntervalSince1970: 1_000)
    private var client: TipTestClient!
    private var store: BJJTipStore!
    override func setUp() {
        client = TipTestClient()
        store = BJJTipStore(client: client, launchedAt: launch)
        store.openSheet()
    }
    private func transaction(_ id: UInt64 = 1, amount: Int = 5, verified: Bool = true,
                             revoked: Bool = false, date: Date? = nil, productID: String? = nil) -> BJJTipTransaction {
        let client = client!
        return BJJTipTransaction(id: id, productID: productID ?? BJJTipCatalog.id(for: amount),
                                 purchaseDate: date ?? launch.addingTimeInterval(1), verified: verified,
                                 revoked: revoked, consumable: true, finish: { client.finished.append(id) })
    }
    func testExactCatalogAndStrictCustomInput() {
        XCTAssertEqual(BJJTipCatalog.ids.count, 10)
        XCTAssertEqual(BJJTipCatalog.id(for: 5), "com.bakedchicken77.bjjtelestrator.tip.five")
        for value in ["0", "11", "1.50", "5.0", "-1", "+5", "NaN", "$5", "1e1", "", "٥"] {
            XCTAssertNil(BJJTipCatalog.parse(value), value)
        }
        XCTAssertEqual(BJJTipCatalog.parse(" 1 "), 1)
        XCTAssertEqual(BJJTipCatalog.parse("10"), 10)
    }
    func testOnlyKnownExactUSConsumablesLoad() async {
        client.catalog = [TipTestClient.product(5), TipTestClient.product(1, price: Decimal(string: "0.99")!),
                          TipTestClient.product(2, currency: "EUR"), TipTestClient.product(3, consumable: false),
                          BJJTipProduct(id: "unknown", price: 5, currency: "USD", displayPrice: "$5.00", consumable: true)]
        await store.load()
        XCTAssertEqual(Array(store.products.keys), [BJJTipCatalog.id(for: 5)])
        XCTAssertNotNil(store.catalogMessage)
        XCTAssertEqual(client.requests.first, BJJTipCatalog.ids)
    }
    func testRestrictedAndNonUSDoNotRequestProducts() async {
        client.canMakePayments = false
        await store.load()
        XCTAssertTrue(store.catalogMessage?.contains("restricted") == true)
        XCTAssertTrue(client.requests.isEmpty)
        client.canMakePayments = true; client.country = "CAN"
        await store.load()
        XCTAssertTrue(store.products.isEmpty)
        XCTAssertTrue(client.requests.isEmpty)
    }
    func testMissingStorefrontExplainsTemporaryUnavailability() async {
        client.country = nil
        await store.load()
        XCTAssertTrue(store.catalogMessage?.contains("temporarily unavailable") == true)
        XCTAssertTrue(client.requests.isEmpty)
    }
    func testOfflineMissingProductsAndRetry() async {
        client.fail = true
        await store.load()
        XCTAssertNotNil(store.catalogMessage); XCTAssertFalse(store.loading)
        client.fail = false; client.catalog = []
        await store.load()
        XCTAssertTrue(store.products.isEmpty); XCTAssertNotNil(store.catalogMessage)
        client.catalog = [TipTestClient.product(5)]
        await store.load()
        XCTAssertNotNil(store.product(amount: 5))
    }
    func testCancelIsQuietAndFailureAllowsDeliberateRetry() async {
        await store.load()
        await store.purchase(amount: 5)
        XCTAssertNil(store.notice); XCTAssertFalse(store.purchasing)
        client.purchaseFails = true
        await store.purchase(amount: 5)
        guard case .error = store.notice else { return XCTFail("Expected failure") }
        XCTAssertFalse(store.purchasing)
        client.purchaseFails = false
        await store.purchase(amount: 5)
        XCTAssertNil(store.notice)
    }
    func testVerifiedSuccessAndRepeatTip() async {
        await store.load()
        client.result = .success(transaction(1))
        await store.purchase(amount: 5)
        XCTAssertEqual(store.notice, .thankYou)
        client.result = .success(transaction(2))
        await store.purchase(amount: 5)
        XCTAssertEqual(client.finished, [1, 2])
        XCTAssertEqual(client.purchases, [5, 5])
        XCTAssertEqual(store.notice, .thankYou)
    }
    func testBoundaryAmountsAreSingleExactPurchases() async {
        await store.load()
        await store.purchase(amount: 1)
        await store.purchase(amount: 10)
        await store.purchase(amount: 0)
        await store.purchase(amount: 11)
        XCTAssertEqual(client.purchases, [1, 10])
    }
    func testChangedPriceAndRestrictionBeforePurchaseFailClosed() async {
        await store.load()
        client.catalog = [TipTestClient.product(5, price: Decimal(string: "4.99")!)]
        await store.purchase(amount: 5)
        XCTAssertTrue(client.purchases.isEmpty)
        XCTAssertNil(store.product(amount: 5))
        XCTAssertNotNil(store.catalogMessage, "Price mismatch must offer reload")
        client.catalog = [TipTestClient.product(5)]; await store.load()
        client.canMakePayments = false
        await store.purchase(amount: 5)
        XCTAssertTrue(client.purchases.isEmpty)
    }
    func testStorefrontChangeBeforePurchaseFailsClosed() async {
        await store.load(); client.country = "GBR"
        await store.purchase(amount: 5)
        XCTAssertTrue(client.purchases.isEmpty); XCTAssertTrue(store.products.isEmpty)
    }
    func testUnverifiedAndUnknownTransactionsAreNeverFinished() async {
        await store.handle(transaction(1, verified: false))
        await store.handle(transaction(2, productID: "some.other.purchase"))
        XCTAssertTrue(client.finished.isEmpty)
        guard case .error = store.notice else { return XCTFail("Expected verification error") }
        // Verification can succeed later; the failed callback must not claim the ID.
        await store.handle(transaction(1))
        XCTAssertEqual(client.finished, [1]); XCTAssertEqual(store.notice, .thankYou)
    }
    func testRevokedTransactionFinishesWithoutThankYou() async {
        await store.handle(transaction(revoked: true))
        XCTAssertEqual(client.finished, [1]); XCTAssertNil(store.notice)
    }
    func testConcurrentDuplicateCallbacksAreClaimedBeforeFinishSuspends() async {
        var release: CheckedContinuation<Void, Never>?
        let tx = BJJTipTransaction(id: 20, productID: BJJTipCatalog.id(for: 5), purchaseDate: launch.addingTimeInterval(1),
                                  verified: true, revoked: false, consumable: true) {
            self.client.finished.append(20)
            await withCheckedContinuation { release = $0 }
        }
        let first = Task { await store.handle(tx) }
        for _ in 0..<100 where release == nil { await Task.yield() }
        XCTAssertNotNil(release)
        await store.handle(tx)
        XCTAssertEqual(client.finished, [20])
        release?.resume(); await first.value
        XCTAssertEqual(store.notice, .thankYou)
        store.closeSheet(); store.openSheet()
        await store.handle(tx)
        XCTAssertNil(store.notice); XCTAssertEqual(client.finished, [20])
    }
    func testDoubleTapCannotOverlapPurchaseAndClosingDoesNotCancelIt() async {
        await store.load(); client.holdPurchase = true
        let first = Task { await store.purchase(amount: 5) }
        for _ in 0..<100 where client.pendingPurchase == nil { await Task.yield() }
        XCTAssertTrue(store.purchasing)
        await store.purchase(amount: 10)
        XCTAssertEqual(client.purchases, [5])
        store.closeSheet(); store.openSheet()
        client.pendingPurchase?.resume(returning: .success(transaction()))
        client.pendingPurchase = nil
        await first.value
        XCTAssertEqual(client.finished, [1]); XCTAssertNil(store.notice)
        XCTAssertFalse(store.purchasing)
    }
    func testPendingThenApprovalViaAppLifetimeListener() async {
        store.start(); store.start()
        XCTAssertEqual(client.listenerCount, 1)
        await store.load(); client.result = .pending
        await store.purchase(amount: 5)
        XCTAssertEqual(store.notice, .pending)
        client.updateContinuation?.yield(transaction())
        for _ in 0..<100 where client.finished.isEmpty { await Task.yield() }
        XCTAssertEqual(client.finished, [1]); XCTAssertEqual(store.notice, .thankYou)
    }
    func testApprovalAfterSheetClosesStillFinishesWithoutLaterBanner() async {
        store.start(); store.closeSheet()
        client.updateContinuation?.yield(transaction())
        for _ in 0..<100 where client.finished.isEmpty { await Task.yield() }
        XCTAssertEqual(client.finished, [1]); XCTAssertNil(store.notice)
        store.openSheet()
        await store.handle(transaction())
        XCTAssertNil(store.notice)
    }
    func testInterruptedRelaunchFinishesSilentlyFromBothStreams() async {
        let previous = transaction(date: launch.addingTimeInterval(-1))
        client.recovered = [previous]
        store.start()
        client.updateContinuation?.yield(previous)
        for _ in 0..<100 where client.finished.isEmpty { await Task.yield() }
        XCTAssertEqual(client.finished, [1]); XCTAssertNil(store.notice)
        // A fresh coordinator has no persisted IDs. Purchase date still prevents a replay banner.
        let relaunched = BJJTipStore(client: client, launchedAt: launch.addingTimeInterval(10))
        relaunched.openSheet()
        await relaunched.handle(previous)
        XCTAssertNil(relaunched.notice); XCTAssertTrue(client.purchases.isEmpty)
    }
    func testRealStoreKitCatalogAndRepeatableConsumables() async throws {
        let url = try XCTUnwrap(Bundle(for: BJJTipTests.self).url(forResource: "FreshFrameTips", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }
        let live = BJJStoreKitTipClient()
        let products = try await live.products(for: BJJTipCatalog.ids)
        XCTAssertEqual(products.count, 10)
        XCTAssertTrue(products.allSatisfy(\.supported))
        var transactionIDs = Set<UInt64>()
        for amount in [5, 5, 1, 10] {
            let product = try XCTUnwrap(products.first { $0.id == BJJTipCatalog.id(for: amount) })
            guard case .success(let transaction) = try await live.purchase(product) else {
                return XCTFail("Expected local StoreKit success")
            }
            XCTAssertTrue(transaction.verified)
            XCTAssertTrue(transactionIDs.insert(transaction.id).inserted)
            await transaction.finish()
        }
    }
}

@MainActor private final class TipTestClient: BJJTipClient {
    var canMakePayments = true
    var country: String? = "USA"
    var catalog = BJJTipCatalog.amounts.map { product($0) }
    var fail = false
    var purchaseFails = false
    var result: BJJTipPurchaseResult = .cancelled
    var requests: [Set<String>] = []
    var purchases: [Int] = []
    var finished: [UInt64] = []
    var listenerCount = 0
    var recovered: [BJJTipTransaction] = []
    var updateContinuation: AsyncStream<BJJTipTransaction>.Continuation?
    var holdPurchase = false
    var pendingPurchase: CheckedContinuation<BJJTipPurchaseResult, Never>?
    static func product(_ amount: Int, price: Decimal? = nil, currency: String = "USD", consumable: Bool = true) -> BJJTipProduct {
        BJJTipProduct(id: BJJTipCatalog.id(for: amount), price: price ?? Decimal(amount), currency: currency,
                      displayPrice: "$\(amount).00", consumable: consumable)
    }
    func storefront() async -> String? { country }
    func products(for ids: Set<String>) async throws -> [BJJTipProduct] {
        requests.append(ids)
        if fail { throw Failure.offline }
        return catalog.filter { ids.contains($0.id) }
    }
    func purchase(_ product: BJJTipProduct) async throws -> BJJTipPurchaseResult {
        purchases.append(BJJTipCatalog.amount(for: product.id)!)
        if purchaseFails { throw Failure.offline }
        if holdPurchase { return await withCheckedContinuation { pendingPurchase = $0 } }
        return result
    }
    func updates() -> AsyncStream<BJJTipTransaction> {
        listenerCount += 1
        return AsyncStream { updateContinuation = $0 }
    }
    func unfinished() -> AsyncStream<BJJTipTransaction> {
        AsyncStream { continuation in
            for transaction in recovered { continuation.yield(transaction) }
            continuation.finish()
        }
    }
    private enum Failure: Error { case offline }
}
