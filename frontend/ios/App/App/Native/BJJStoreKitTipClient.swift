import StoreKit

@MainActor final class BJJStoreKitTipClient: BJJTipClient {
    private var loaded: [String: Product] = [:]
    var canMakePayments: Bool { AppStore.canMakePayments }
    func storefront() async -> String? { await Storefront.current?.countryCode }
    func products(for ids: Set<String>) async throws -> [BJJTipProduct] {
        let products = try await Product.products(for: ids.intersection(BJJTipCatalog.ids))
        for id in ids { loaded.removeValue(forKey: id) }
        for product in products { loaded[product.id] = product }
        return products.map {
            BJJTipProduct(id: $0.id, price: $0.price, currency: $0.priceFormatStyle.currencyCode,
                          displayPrice: $0.displayPrice, consumable: $0.type == .consumable)
        }
    }
    func purchase(_ requested: BJJTipProduct) async throws -> BJJTipPurchaseResult {
        guard let product = loaded[requested.id], requested.supported,
              product.price == requested.price, product.priceFormatStyle.currencyCode == requested.currency,
              product.type == .consumable else { throw TipError.unavailable }
        switch try await product.purchase() {
        case .success(let verification): return .success(Self.transaction(verification))
        case .userCancelled: return .cancelled
        case .pending: return .pending
        @unknown default: throw TipError.unavailable
        }
    }
    func updates() -> AsyncStream<BJJTipTransaction> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                for await result in Transaction.updates {
                    guard !Task.isCancelled else { break }
                    continuation.yield(Self.transaction(result))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func unfinished() -> AsyncStream<BJJTipTransaction> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                for await result in Transaction.unfinished {
                    guard !Task.isCancelled else { break }
                    continuation.yield(Self.transaction(result))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private static func transaction(_ result: VerificationResult<Transaction>) -> BJJTipTransaction {
        switch result {
        case .verified(let transaction):
            return BJJTipTransaction(id: transaction.id, productID: transaction.productID,
                                     purchaseDate: transaction.purchaseDate, verified: true,
                                     revoked: transaction.revocationDate != nil,
                                     consumable: transaction.productType == .consumable,
                                     finish: { await transaction.finish() })
        case .unverified(let transaction, _):
            return BJJTipTransaction(id: transaction.id, productID: transaction.productID,
                                     purchaseDate: transaction.purchaseDate, verified: false,
                                     revoked: false, consumable: transaction.productType == .consumable,
                                     finish: {})
        }
    }
    private enum TipError: Error { case unavailable }
}
