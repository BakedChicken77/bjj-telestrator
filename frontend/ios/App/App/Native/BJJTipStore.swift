import Foundation
import Combine

/// Explicit US launch catalog. A price mismatch disables that amount; never round or split a tip.
enum BJJTipCatalog {
    static let amounts = 1...10
    static func id(for amount: Int) -> String {
        "com.bakedchicken77.bjjtelestrator.tip." + (amount == 5 ? "five" : "usd\(amount)")
    }
    static let ids = Set(amounts.map { id(for: $0) })
    static func amount(for id: String) -> Int? { amounts.first { self.id(for: $0) == id } }
    static func parse(_ text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.allSatisfy({ "0123456789".contains($0) }),
              let amount = Int(value), amounts.contains(amount) else { return nil }
        return amount
    }
}

struct BJJTipProduct: Equatable {
    let id: String
    let price: Decimal
    let currency: String
    let displayPrice: String
    let consumable: Bool
    var supported: Bool {
        guard let amount = BJJTipCatalog.amount(for: id) else { return false }
        return consumable && currency == "USD" && price == Decimal(amount)
    }
}

struct BJJTipTransaction {
    let id: UInt64
    let productID: String
    let purchaseDate: Date
    let verified: Bool
    let revoked: Bool
    let consumable: Bool
    let finish: @MainActor () async -> Void
}

enum BJJTipPurchaseResult {
    case success(BJJTipTransaction)
    case cancelled
    case pending
}

/// All StoreKit calls cross this injectable boundary; no video/session dependency.
@MainActor protocol BJJTipClient: AnyObject {
    var canMakePayments: Bool { get }
    func storefront() async -> String?
    func products(for ids: Set<String>) async throws -> [BJJTipProduct]
    func purchase(_ product: BJJTipProduct) async throws -> BJJTipPurchaseResult
    func updates() -> AsyncStream<BJJTipTransaction>
    func unfinished() -> AsyncStream<BJJTipTransaction>
}

@MainActor final class BJJTipStore: ObservableObject {
    static let shared: BJJTipStore = {
        #if DEBUG
        if let fixture = BJJUITestFixture.tipStore() { return fixture }
        #endif
        return BJJTipStore(client: BJJStoreKitTipClient())
    }()
    @Published private(set) var products: [String: BJJTipProduct] = [:]
    @Published private(set) var loading = false
    @Published private(set) var purchasing = false
    @Published private(set) var catalogMessage: String?
    @Published private(set) var notice: Notice?
    enum Notice: Equatable {
        case thankYou, pending, error(String)
        var text: String {
            switch self {
            case .thankYou: return "Thank you for supporting Fresh Frame!"
            case .pending: return "Apple is awaiting approval. Your tip has not completed yet."
            case .error(let message): return message
            }
        }
    }
    private let client: BJJTipClient
    private let launchedAt: Date
    private var processed = Set<UInt64>()
    private var listener: Task<Void, Never>?
    private var recovery: Task<Void, Never>?
    private var sheetSession: UUID?
    init(client: BJJTipClient, launchedAt: Date = Date()) {
        self.client = client
        self.launchedAt = launchedAt
    }
    deinit { listener?.cancel(); recovery?.cancel() }

    /// Called once at app launch, independent of any scene or sheet.
    func start() {
        guard listener == nil else { return }
        let updates = client.updates()
        let unfinished = client.unfinished()
        listener = Task { [weak self] in
            for await transaction in updates {
                guard !Task.isCancelled else { return }
                await self?.handle(transaction)
            }
        }
        recovery = Task { [weak self] in
            for await transaction in unfinished {
                guard !Task.isCancelled else { return }
                await self?.handle(transaction, recovering: true)
            }
        }
    }
    func openSheet() { sheetSession = UUID(); notice = nil }
    func closeSheet() { sheetSession = nil; notice = nil }
    func product(amount: Int) -> BJJTipProduct? { products[BJJTipCatalog.id(for: amount)] }

    func load() async {
        guard !loading, !purchasing else { return }
        loading = true
        products = [:]
        catalogMessage = nil
        defer { loading = false }
        guard client.canMakePayments else {
            catalogMessage = "In-app purchases are restricted on this device."
            return
        }
        guard let country = await client.storefront() else {
            catalogMessage = "Tips are temporarily unavailable. Check your App Store connection and try again."
            return
        }
        guard country == "USA" else {
            catalogMessage = "Tips are currently available only in the US App Store."
            return
        }
        do {
            let fetched = try await client.products(for: BJJTipCatalog.ids)
            guard !Task.isCancelled else { return }
            for product in fetched where product.supported { products[product.id] = product }
            if products.isEmpty { catalogMessage = "Tips are temporarily unavailable. Please try again later." }
            else if products.count < BJJTipCatalog.ids.count {
                catalogMessage = "Some tip amounts are temporarily unavailable. No other amount will be charged."
            }
        } catch {
            if !Task.isCancelled { catalogMessage = "Tips could not load. Check your connection and try again." }
        }
    }

    func purchase(amount: Int) async {
        guard !purchasing, !loading else { return }
        guard let product = product(amount: amount) else {
            notice = .error("That exact tip amount is unavailable. Please choose another amount or try again later.")
            return
        }
        guard client.canMakePayments else {
            notice = .error("In-app purchases are restricted on this device.")
            return
        }
        purchasing = true
        notice = nil
        let session = sheetSession
        defer { purchasing = false }
        do {
            let country = await client.storefront()
            guard country == "USA" else {
                products = [:]
                catalogMessage = country == nil
                    ? "Tips are temporarily unavailable. Check your App Store connection and try again."
                    : "Tips are currently available only in the US App Store."
                return
            }
            // Refresh immediately before purchase. Never buy a changed price or product type.
            let fresh = try await client.products(for: [product.id])
            guard fresh.contains(where: { $0.id == product.id && $0.supported }) else {
                products.removeValue(forKey: product.id)
                catalogMessage = "Some tip amounts are temporarily unavailable. Reload prices to check again."
                if session == sheetSession { notice = .error("That exact price is no longer available. Please reload tips.") }
                return
            }
            switch try await client.purchase(product) {
            case .success(let transaction): await handle(transaction, recovering: session != sheetSession)
            case .cancelled: break
            case .pending:
                if session == sheetSession { notice = .pending }
            }
        } catch {
            if session == sheetSession { notice = .error("Your tip could not be completed. Please try again when you’re ready.") }
        }
    }

    /// Main-actor serialization plus a claim *before* suspension prevents duplicate callbacks.
    /// Old transactions are finished silently on relaunch; no transaction history is persisted.
    func handle(_ transaction: BJJTipTransaction, recovering: Bool = false) async {
        guard BJJTipCatalog.ids.contains(transaction.productID), transaction.consumable else { return }
        guard transaction.verified else {
            if sheetSession != nil { notice = .error("Apple’s purchase could not be verified. Please try again later.") }
            return // Never finish an unverified transaction.
        }
        guard processed.insert(transaction.id).inserted else { return }
        let session = sheetSession
        await transaction.finish()
        guard !transaction.revoked, !recovering, transaction.purchaseDate >= launchedAt,
              session != nil, session == sheetSession else { return }
        notice = .thankYou
    }
}
