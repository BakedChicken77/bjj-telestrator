import SwiftUI

struct BJJTipSheet: View {
    @ObservedObject var store: BJJTipStore
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @FocusState private var amountFocused: Bool
    private var chosenAmount: Int? { BJJTipCatalog.parse(amount) }
    private var chosenProduct: BJJTipProduct? { chosenAmount.flatMap { store.product(amount: $0) } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Fresh Frame is free. Tips are optional and help support development. They don’t unlock features.")
                }
                Section {
                    if store.loading { ProgressView("Loading tip prices…") }
                    if let message = store.catalogMessage { Text(message).foregroundStyle(.secondary) }
                    Button {
                        Task { await store.purchase(amount: 5) }
                    } label: {
                        Label(store.product(amount: 5).map { "Tip \($0.displayPrice)" } ?? "Tip $5 (unavailable)", systemImage: "heart")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("tips.five")
                    .disabled(store.loading || store.purchasing || store.product(amount: 5) == nil)
                    NavigationLink {
                        customView
                    } label: {
                        Label("Custom tip", systemImage: "heart.text.clipboard").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("tips.custom")
                    .disabled(store.loading || store.purchasing || store.products.isEmpty)
                }
                status
                if store.catalogMessage != nil {
                    Section {
                        Button("Reload tip prices") { Task { await store.load() } }
                            .frame(minHeight: 44).disabled(store.loading || store.purchasing)
                    }
                }
            }
            .navigationTitle("Support Fresh Frame")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { closeButton }
        }
        .onAppear { store.openSheet() }
        .task { await store.load() }
        .onDisappear { store.closeSheet() }
    }
    private var customView: some View {
        Form {
            Section {
                Text("Enter a whole-dollar amount from $1 to $10 USD. Each tip is one purchase confirmed by Apple.")
                TextField("Amount in US dollars", text: $amount)
                    .keyboardType(.numberPad)
                    .focused($amountFocused)
                    .accessibilityIdentifier("tips.amount")
                if !amount.isEmpty && chosenAmount == nil {
                    Text("Enter a whole number from 1 to 10. Cents are not supported.").foregroundStyle(.secondary)
                } else if chosenAmount != nil && chosenProduct == nil {
                    Text("That exact amount is temporarily unavailable. No other amount will be charged.").foregroundStyle(.secondary)
                }
                Button {
                    guard let chosenAmount else { return }
                    Task { await store.purchase(amount: chosenAmount) }
                } label: {
                    Text(chosenProduct.map { "Tip \($0.displayPrice)" } ?? "Confirm tip").frame(minHeight: 44)
                }
                .accessibilityIdentifier("tips.confirm")
                .disabled(chosenProduct == nil || store.purchasing || store.loading)
            }
            status
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Custom tip")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            closeButton
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { amountFocused = false }.accessibilityIdentifier("tips.keyboard.done")
            }
        }
    }
    @ToolbarContentBuilder private var closeButton: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Close") { dismiss() }.accessibilityIdentifier("tips.close")
        }
    }
    @ViewBuilder private var status: some View {
        if store.purchasing {
            Section { ProgressView("Waiting for Apple…") }
        }
        if let notice = store.notice {
            Section { Text(notice.text).accessibilityIdentifier("tips.notice") }
        }
    }
}
