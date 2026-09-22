# Apple Distribution and StoreKit Handoff

Date: 2026-09-22

## Deliverable

`project.yml` is the source of truth for a universal Apple project. Running `tools/generate_apple_project.sh` creates `BankReconciliation.xcodeproj`, renders every required iPhone, iPad and Mac app-icon slot, and generates the shared test plan that activates the local StoreKit configuration for the app-hosted lifecycle suite.

| Destination | Minimum OS | Bundle identifier | CI output |
|---|---:|---|---|
| iPhone | iOS 18 | `com.worksbienstudios.bankreconciliation` | Simulator build + unsigned generic archive |
| iPad | iPadOS 18 | same universal app | Simulator build + unsigned generic archive |
| Mac | macOS 15 | same universal app | Native build + unsigned generic archive |

The project includes `PrivacyInfo.xcprivacy` declaring no tracking and no collected data, a Mac App Sandbox entitlement limited to user-selected read/write files, Finance category metadata, version/build settings, and the app icon catalog. The CI archives intentionally set `CODE_SIGNING_ALLOWED=NO`; they validate compilation and archive structure but cannot be submitted.

## Distribution signing

The repository does not store a development team ID, distribution certificate or App Store Connect API key. To make the archives distributable:

1. Open `BankReconciliation.xcodeproj` in Xcode while signed into the WorksBien Apple Developer team.
2. Select the `BankReconciliation` target, leave automatic signing enabled, and choose the team that owns bundle ID `com.worksbienstudios.bankreconciliation`.
3. Confirm iOS and macOS App Store distribution profiles resolve without changing the product bundle identifier.
4. Run Product > Archive for `Any iOS Device (arm64)` and `Any Mac (Apple Silicon, Intel)`.
5. Validate both archives in Organizer before uploading either build.

Do not treat an unsigned CI archive as a TestFlight or App Store build.

## In-app purchases

The executable and local StoreKit catalog use these immutable product IDs:

| Tier | Type | Product ID | US reference price |
|---|---|---|---:|
| Pro | Non-consumable | `com.worksbienstudios.bankreconciliation.pro` | US$39.99 |
| Accountant | Non-consumable | `com.worksbienstudios.bankreconciliation.accountant` | US$99.99 |

The US values are reference price points only. The app always displays `Product.displayPrice`, so Apple supplies the storefront currency, taxes and localized price. Product display names and descriptions are present in English, French, Spanish, German and Brazilian Portuguese in `App/StoreKit/BankReconciliation.storekit`.

The local catalog is test data and does not upload to App Store Connect. An Account Holder, Admin, App Manager, Developer or Marketing user must create both live non-consumables under Apps > Bank Reconciliation > Monetization > In-App Purchases. Each live record still needs its price point, the five localizations, availability, tax category if requested, and an in-app-purchase review screenshot. Product creation and pricing are not claimed complete until the live records are read back from App Store Connect.

## StoreKit verification matrix

The headless CI gate validates both product IDs, non-consumable types, US reference prices, the exact five-locale set and local-only catalogue settings. It also compiles the app-hosted Xcode lifecycle suite for:

- Pro purchase and highest-tier Accountant upgrade;
- entitlement recovery in a fresh service instance after an external purchase;
- refund removing a non-consumable entitlement;
- Ask to Buy returning pending without unlocking;
- interrupted purchase failing closed.

StoreKit transaction execution is deliberately not claimed by the headless GitHub runner: Apple's simulator transaction service does not complete reliably there. Run the five compiled scenarios from Xcode, then repeat purchase, cancel, pending approval, `AppStore.sync()` restore, refund/revocation and offline relaunch with Sandbox Apple Accounts against the live product records on physical iPhone, iPad and Mac. Record the product state and test timestamp.

## Operator workflows delivered

- Source Profiles now edit format, worksheet, header/delimiter, every supported column, date order, decimal/grouping separators, account and currency defaults.
- Accountant batch folders persist user-selected folder access and rescan on open. Pairing is deterministic and non-recursive; symlinks, ambiguous duplicate roles and bounded-resource violations fail closed.
- iPad and Mac use a synchronized two-column transaction comparison beside a persistent exception inspector. Compact layouts stack the same views without changing decisions or engine results.

## Remaining human-controlled release gates

- configure and read back both live products in App Store Connect;
- attach IAP review screenshots and verify agreements/tax/banking state;
- select the WorksBien development team and create signed archives;
- run live sandbox lifecycle tests on physical iPhone, iPad and Mac;
- upload to TestFlight and complete external/product-owner acceptance;
- complete the broader engine-lock blockers in `docs/RELEASE_GATE.md`.
