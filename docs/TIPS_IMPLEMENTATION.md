# Fresh Frame optional tips

Implementation branch: `feature/fresh-frame-tips`, based on main `a181f66`
(2.0.7), September 28, 2026. Steve reports banking and tax setup completed.
This branch implements the feature; it does not change the 2.0.7 release,
accept agreements, create live products, or submit a new version.

## Product and UI decisions

Library → Support Fresh Frame, next to Help & support. The sheet has exactly
two tip choices: **Tip $5** and **Custom tip**, plus Close. Reload is a recovery
action when catalog loading fails. Custom amounts initially use **$1–$10 USD in
$1 increments**. This is the implementation default for the previously open
range decision. Each amount maps to one consumable and one Apple confirmation;
no quantity multiplication, rounding, $4.99 replacement, external checkout,
subscriptions, accounts, feature gates, export prompts, or video changes.

The initial US-only policy checks `Storefront.current.countryCode == "USA"`.
Only known consumables with currency USD and exact Decimal price are offered.
Buttons use `Product.displayPrice`. The chosen product is fetched and validated
again before purchase. A missing or mismatched amount stays unavailable. This
also protects against an accidentally configured $4.99 price on the $5 ID.

| USD | Permanent product ID to configure | Type |
| --- | --- | --- |
| 1 | `com.bakedchicken77.bjjtelestrator.tip.usd1` | Consumable |
| 2 | `com.bakedchicken77.bjjtelestrator.tip.usd2` | Consumable |
| 3 | `com.bakedchicken77.bjjtelestrator.tip.usd3` | Consumable |
| 4 | `com.bakedchicken77.bjjtelestrator.tip.usd4` | Consumable |
| 5 | `com.bakedchicken77.bjjtelestrator.tip.five` | Consumable |
| 6 | `com.bakedchicken77.bjjtelestrator.tip.usd6` | Consumable |
| 7 | `com.bakedchicken77.bjjtelestrator.tip.usd7` | Consumable |
| 8 | `com.bakedchicken77.bjjtelestrator.tip.usd8` | Consumable |
| 9 | `com.bakedchicken77.bjjtelestrator.tip.usd9` | Consumable |
| 10 | `com.bakedchicken77.bjjtelestrator.tip.usd10` | Consumable |

Suggested reference name: `Fresh Frame Tip USD N`. English display name:
`Fresh Frame $N Tip`. Description: `Optional support for development. No features
are unlocked.` Select the appropriate tax category and US availability in App
Store Connect; verify exact customer prices there and through real StoreKit.
Apple's whole-dollar pricing convention supports this design; this is not
evidence that these particular products already exist in Steve's account.

## Transaction lifecycle and privacy

AppDelegate starts one app-lifetime coordinator, shared by scenes and sheets.
`BJJTipClient` isolates StoreKit from deterministic tests. Immediate results,
`Transaction.updates`, and `Transaction.unfinished` share a main-actor handler.
It claims a verified known consumable ID before suspending for `finish()`, so
concurrent callbacks cannot process or thank twice. Unverified/unknown purchases
are not finished. Revocations finish without a new thank-you.

The sheet can close during loading, purchasing, or pending approval. Purchase
work and the update listener outlive it. A new sheet session cannot inherit a
success from the old purchase request. Completion never opens an alert over an
editor. The thank-you is inline inside an already-open support sheet only.

No persistent transaction ledger is necessary: a set of IDs is retained only
in RAM for this app process. Recovery transactions and transactions purchased
before process launch are finished silently. Thus an interruption/relaunch
cannot replay a success banner or initiate another purchase, even if a prior
process stopped between finishing and presenting. An interrupted successful
tip may intentionally receive no thank-you. No entitlement or receipt history
is promised. Support/privacy pages describe this exact behavior.

No SDK, backend, account, card handling, purchase analytics or additional
required-reason API is introduced. The existing privacy manifest is unchanged.
Recheck App Store privacy answers for the final shipped build and any later
changes in developer-side collection; do not declare Apple-only payment data
as data collected by this app without reviewing Apple's definitions.

## Development and checks

`frontend/ios/App/AppTests/FreshFrameTips.storekit` is a local ten-product
catalog. It is copied only into AppTests, not the App bundle. The shared App
scheme has no StoreKit override, so normal launches, archives and TestFlight
use Apple's actual catalog. To explore locally in Xcode, duplicate the App
scheme and select this file in Run → Options → StoreKit Configuration. Do not
commit or select a local override for a release/sandbox acceptance build.

`BJJTipTests` exercises exact prices and input, catalog failures/retry,
restrictions and storefront changes, success, cancellation, pending approval,
unknown/unverified/revoked transactions, repeat tips, bounds, overlapping taps,
concurrent duplicate callbacks, dismissal and interrupted relaunch. One test
uses `SKTestSession` and the real adapter for catalog lookup plus repeat $5,
$1 and $10 purchases. A debug-only UI fixture supplies deterministic prices
and cancellation for UI layout tests; it is not a billing acceptance test.

Run:

```sh
python scripts/configure_ios.py
python -m unittest discover -s tests/repository -v
# macOS with Xcode, after npm ci && npm run ios:sync in frontend:
python scripts/test_ios.py
```

The first native run compiled successfully and passed the 51 existing native
unit tests, all deterministic tip tests, and all five UI workflows. The real
StoreKit catalog test failed with `SKInternalErrorDomain Code=3` on iOS 26.4.1.
This matches Apple's documented simulator test-service regression
([Apple developer discussion](https://developer.apple.com/forums/thread/826971)).
The runner now selects the newest installed runtime outside iOS 26.3–26.5
(for example 26.2 or 26.6+). The integration assertion is retained; no purchase
test is skipped. The catalog is explicitly loaded from the test bundle by URL.

The required CI also exercises existing imports, drawing/cue timing, rotation,
saving/reopening, real export and the unsigned iPhone archive. CI evidence is
recorded in the PR. Physical VoiceOver, largest accessibility text, light/dark
mode and phone purchase-sheet acceptance remain explicit device checks.

## Release gates

1. Verify the business setup is Active in App Store Connect (owner reports
   banking/tax complete; this implementation has not independently rechecked it).
2. Create all ten consumables above with metadata, intended US territory,
   exact prices, tax category, and review screenshot from the actual app.
3. Choose a new app version. Attach first IAPs to that version for review;
   leave the existing App Store submission and 2.0.7 release independent.
4. On a real iPhone/TestFlight, load real catalog prices, buy $5 twice, buy
   custom $1 and $10, cancel, test pending then approval with sheet closed,
   relaunch after interruption, test unavailable/offline/restricted behavior,
   and inspect Apple's purchase sheet for exactly one matching charge.
5. Verify all normal regressions and physical accessibility; review final
   support/privacy declarations. Local StoreKit success does not satisfy the
   live catalog or TestFlight acceptance gate.

Reviewer directions: Library → Support Fresh Frame → Tip $5 or Custom tip.
Every function is free; tips are optional, repeatable one-time consumables.

## Apple references

- [Pricing conventions](https://developer.apple.com/in-app-purchase/)
- [Set an IAP price](https://developer.apple.com/help/app-store-connect/manage-in-app-purchases/set-a-price-for-an-in-app-purchase)
- [Transaction updates](https://developer.apple.com/documentation/storekit/transaction/updates)
- [Unfinished transactions](https://developer.apple.com/documentation/storekit/transaction/unfinished)
- [Finish](https://developer.apple.com/documentation/storekit/transaction/finish())
- [StoreKit testing](https://developer.apple.com/documentation/storekittest)
