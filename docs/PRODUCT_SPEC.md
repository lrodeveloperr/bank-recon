# Bank Reconciliation: CSV — Final Product Structure

**Owner:** WorksBien Studios Inc.  
**Decision date:** 21 September 2026  
**Status:** Final storefront verification complete; product scope locked for engine specification  
**Platforms:** Mac, iPad and iPhone as one Universal Purchase  
**Locked English App Store name:** `Bank Reconciliation: CSV`

## 1. Final decision

Build an **independent, offline reconciliation and integrity-control app for exported bank and ledger transaction files**.

The product is not a bank, accounting ledger, budgeting app, bank-feed connector or PDF converter. It receives already-structured exports from banks, finance apps and accounting systems, then proves whether the records are complete, unchanged and arithmetically reconcilable.

The primary promise is:

> **Compare two financial exports. Find missing, changed, duplicated and unreconciled transactions. Keep an evidence pack.**

The narrow job is important. Existing finance managers reconcile transactions inside their own database, while the growing converter category turns PDF statements into CSV/Excel/accounting formats. Neither is an independent control over two arbitrary exports.

## 2. Who it is for

### Primary users

1. **Accountants and bookkeepers** checking bank-versus-ledger completeness without importing client files into another cloud system.
2. **Small-business owners and controllers** verifying an accounting or finance-app export after a sync, migration, restore or month-end close.
3. **Power users** who maintain records in a personal-finance app and want to confirm that its exported history still agrees with the bank.

### Not the target

- People looking for a new budget, expense tracker or daily transaction-entry app.
- Enterprises requiring live bank feeds, team permissions, approvals or ERP integrations.
- Users whose only available source is a PDF or photo and who need OCR/conversion.

## 3. Competitive boundary

| Competitor class | What it already does | What this app must own |
|---|---|---|
| Finance managers such as Debit & Credit, Money Pro, iFinance and Banking4 | Maintain their own ledger, import bank files and reconcile within their own database | Independently check the finance manager's export against a bank export, or compare two historical exports from the manager |
| Statement converters such as StatementSnap and Bank Statement Conversion | Convert PDF/image statements to CSV, Excel, OFX, QBO, CAMT or other structured outputs; may perform conversion-readiness and balance checks | Accept structured output from any converter, compare it with another source, classify cross-source exceptions and lock the proof |
| Generic diff tools | Show textual or row-level file differences | Understand accounts, currencies, debit/credit signs, statement balances, transaction identity, duplicates and reconciliation periods |
| Cloud accounting systems | Reconcile within the system of record using bank feeds or imported files | Remain an independent local control that does not require bank credentials, an account or migration to another ledger |

### Moat

The moat is not “CSV import.” It is the combination of:

1. **Source-independent reconciliation** — any supported bank export versus any supported ledger/finance-app export.
2. **Deterministic transaction identity** — strong identifiers first, conservative fuzzy matching second, ambiguity never silently resolved.
3. **History integrity** — compare exports over time and expose deleted, inserted or mutated records.
4. **Locked evidence** — mapping definition, file hashes, totals, exceptions, user decisions and report are preserved together.
5. **Broad local format coverage** — North American, UK/Commonwealth and European structured bank formats without bank APIs.
6. **Professional localization** — local terminology, number/date conventions and evidence reports, not translated marketing alone.

## 4. The three product modes

### Mode A — Bank vs Ledger Reconciliation (default)

**Question:** Does the bank's exported activity agree with the finance-app or accounting-ledger export for this period?

Inputs:

- File A: bank export.
- File B: ledger, accounting-system or finance-app export.
- Optional opening and closing balances when the source file does not contain them.

Output:

- Matched transactions.
- In bank but missing from ledger.
- In ledger but missing from bank.
- Amount/date/reference/cleared-status changes.
- Duplicates within either source.
- Ambiguous matches requiring review.
- Balance or period-continuity differences.

### Mode B — Export vs Export Integrity Comparison

**Question:** What changed between an older and newer export from the same system?

Use cases:

- Before and after a sync.
- Before and after migrating or restoring an app.
- Month-end locked export versus a later export.
- Two devices that should contain the same history.

Output:

- Added, deleted and mutated transactions.
- Duplicate or split/merged candidates.
- Cleared-status, category or reference changes.
- Opening/closing balance movement.
- A quantified before/after integrity summary.

### Mode C — Single Statement Proof

**Question:** Is one structured statement internally complete and arithmetically coherent?

Tests:

- Opening balance + signed activity = closing balance.
- Statement sequence and period continuity.
- Duplicate strong IDs or duplicate transaction signatures.
- Missing dates, amounts, currencies or required identifiers.
- Debit/credit-sign consistency.
- Running-balance breaks where balances are supplied.

This mode verifies the structured file. It does not claim that the bank itself is correct.

## 5. Supported input scope

### Version 1 formats

| Family | Formats | Required behaviour |
|---|---|---|
| Delimited | CSV, TSV | Automatic delimiter, encoding, header and decimal/date-locale detection; reusable manual mapping when uncertain |
| Spreadsheet | XLSX | Read-only import; detect candidate sheets and header rows; never write back to the source workbook |
| Consumer finance | OFX, QFX, QBO, QIF, QMTF | Preserve account, currency, FITID/reference, memo, payee, cleared status and transaction type when present |
| European bank XML | CAMT.053 versions 001.02–001.08 | Namespace-aware parsing; preserve IBAN, booking/value date, debit-credit indicator, bank transaction codes, end-to-end/mandate/creditor references and remittance text |
| European notifications | CAMT.054 versions 001.02–001.08 | Import with an explicit warning that a notification is not necessarily a complete account statement |
| Legacy European | MT940 | Preserve statement/account references, opening/closing balances, value dates, transaction codes and narrative fields |
| North American corporate | BAI2 | Account/statement grouping, transaction codes, funds availability where present, control totals and currency-aware reconciliation |

### Deliberately excluded from version 1

- PDF, image or screenshot import.
- OCR or AI statement extraction.
- Direct bank feeds, Plaid, FinTS, EBICS, PSD2/Open Banking or screen scraping.
- Proprietary ERP APIs.
- Tax/VAT determination or filing.
- Receipt matching, expense claims and invoice capture.

Users with PDFs can use an existing converter and feed its CSV/XLSX/OFX output into this app. That makes converters complements rather than the product's main competitors.

## 6. Canonical transaction model

Every imported row is normalized without destroying the source representation.

Required internal fields:

- Source file, sheet/statement and source-row locator.
- Source account and masked account identifier.
- Currency.
- Booking date and value date.
- Signed amount plus original debit/credit fields.
- Running balance where supplied.
- Strong transaction ID: FITID, end-to-end reference, statement reference or equivalent.
- Payee/counterparty, description, memo and raw remittance text.
- Bank transaction code/type.
- Cleared/reconciled status and category where supplied by a ledger export.
- Original raw values and normalized values.
- Source-file SHA-256 hash and normalized-row hash.

No field may be silently invented. Derived fields must be marked as derived.

## 7. Matching and exception rules

### Match order

1. **Exact strong-ID match** within the same account/currency context.
2. **Exact composite match** using amount, currency, date and stable reference.
3. **Controlled fuzzy match** using amount/currency as hard gates plus configurable date tolerance and description/reference similarity.
4. **Manual match** only after the user selects both items.

The engine must fail closed:

- One item cannot be silently matched to multiple items.
- Ambiguous equal candidates remain unresolved.
- Cross-currency items never net automatically.
- A user's prior match becomes stale if either source row changes.

### Exception classes

1. Missing from ledger.
2. Missing from bank / unexpected ledger item.
3. Duplicate in bank source.
4. Duplicate in ledger source.
5. Amount changed.
6. Date changed.
7. Description/reference changed.
8. Cleared/category/status changed.
9. Possible split or merge.
10. Currency/account mismatch.
11. Opening/closing balance difference.
12. Running-balance break.
13. Statement-period gap or overlap.
14. Unparsed or structurally invalid row.
15. Ambiguous candidate match.

## 8. Result states

The app must never force every run into a green/red binary.

| State | Meaning |
|---|---|
| **Reconciled** | All required rows and balances agree; no unresolved exception remains |
| **Reconciled with explanations** | Differences exist but every item has an explicit user-approved explanation and the arithmetic closes |
| **Difference found** | One or more unresolved exceptions or balance differences remain |
| **Cannot conclude** | Parsing, missing periods, missing balances or ambiguity prevents a reliable conclusion |

## 9. End-to-end user flow

1. Tap **New Reconciliation**.
2. Choose `Bank vs Ledger`, `Compare Two Exports`, or `Verify One Statement`.
3. Select files through Files, Share Sheet, drag-and-drop or a watched folder in the Accountant tier.
4. App detects format, account, currency, period and saved mapping.
5. User resolves only fields the app cannot determine safely.
6. Engine validates each source independently before cross-source matching.
7. Summary shows result state, total difference and exception counts.
8. User reviews grouped exceptions; confirms matches or adds explanations without editing source data.
9. User locks the reconciliation point.
10. App creates an immutable local snapshot and optional PDF/CSV evidence pack.

Failed parses and previews do not consume the free allowance. A reconciliation counts only when the user locks it.

## 10. Screens and navigation

### Mac and iPad

Use a sidebar with four destinations:

1. **Reconciliations** — new and recent jobs.
2. **Source Profiles** — mappings and format/account defaults.
3. **Evidence Packs** — locked reports and exports.
4. **Settings** — language, date/number display, backup/export and purchase state.

The review screen uses two synchronized columns plus a persistent exception inspector.

### iPhone

Use four bottom tabs with the same information architecture. iPhone supports the complete engine for small files, but its primary role is selecting files, reviewing exceptions, approving explanations and viewing reports. Complex mapping and large-batch review are optimized for Mac/iPad.

## 11. Evidence pack

The PDF and companion CSV/JSON manifest must include:

- Entity/workspace, account and period.
- Input filenames, hashes, sizes and import times.
- Parser version and mapping definition.
- Opening balance, movement totals and closing balance by currency.
- Match and exception counts and values.
- Every unresolved or explained exception.
- User explanations and lock time.
- App/engine version.
- A neutral limitation statement: the report proves the files and decisions shown; it does not certify the bank, ledger, tax return or legal correctness.

## 12. Data, privacy and backup

- Entirely local processing.
- No WorksBien account, server, analytics, advertising or bank credentials.
- Files are imported through Apple's document access mechanisms; originals remain unchanged.
- Native user-controlled backup/export may include workspaces, mappings, snapshots and evidence packs.
- Backup never changes App Store entitlement.
- Optional device encryption/passcode lock can be added after the core engine; it must not delay version 1.

## 13. Platforms and device order

1. **Mac first** — best environment for folders, large files, mapping and professional evidence review.
2. **iPad fully capable** — two-column review, Files/Share Sheet and keyboard support.
3. **iPhone included** — complete small-file workflow and strong review/approval companion.

Ship as one SwiftUI codebase and Universal Purchase. Do not split the same engine into separate country apps.

## 14. Countries and languages

Five different numbers must not be confused:

| Measure | Locked number | Meaning |
|---|---:|---|
| Store availability | **175 countries/regions** | Every App Store territory WorksBien can legally serve |
| Actively verified launch storefronts | **9 countries** | Storefronts used for launch ASO, terminology, examples, pricing review and release QA |
| UI languages | **5** | Translation systems shipped in the app binary |
| App Store metadata localizations | **10** | Store-specific product-page records; several reuse the same neutral-language source |
| Screenshot language sets | **5** | One visual/copy set per UI language, reused across same-language metadata variants |

### Store availability — 175 countries/regions

Make the app available in every App Store country/region WorksBien can legally serve. The product has no bank-feed or country-regulatory dependency that justifies artificial territorial exclusion. Availability is not a claim that every storefront was independently validated.

### Actively verified launch storefronts — 9 countries

These are the representative storefronts to receive deliberate launch ASO, terminology, examples, local price review and release QA:

1. United States
2. Canada
3. United Kingdom
4. Australia
5. France
6. Germany
7. Spain
8. Mexico
9. Brazil

They cover the five launch languages, the highest-value English storefront variants and the principal format/convention clusters. Ireland, New Zealand, Singapore and South Africa use the English fallback; Austria, Switzerland, Belgium and Luxembourg use the relevant German/French/English fallback; the rest of Spanish-speaking Latin America uses the Mexico-Spanish fallback. Do not create separate launch translations merely because a country has its own storefront.

### Launch UI languages — 5

1. **Neutral English** (`en`)
2. **Neutral French** (`fr`)
3. **Standard German** (`de`)
4. **Neutral Spanish** (`es`)
5. **Brazilian Portuguese** (`pt-BR`)

Use one neutral in-app translation for English, French and Spanish. Locale-aware dates, decimals, currencies and delimiters remain driven by the user's device and the imported source. Brazilian Portuguese is a separate localization because terminology and usage differ materially from European Portuguese.

### App Store metadata localizations — 10

| Language source | App Store Connect records | Work rule |
|---|---|---|
| Neutral English | en-US, en-CA, en-GB, en-AU | Reuse one English source; change only search terms, examples and terminology that materially differ |
| Neutral French | fr-FR, fr-CA | Reuse one French source; adapt only Canadian search vocabulary and examples |
| Standard German | de-DE | One record |
| Neutral Spanish | es-ES, es-MX | Reuse one Spanish source; adapt search vocabulary and examples |
| Brazilian Portuguese | pt-BR | One record; do not reuse for Portugal |

This means ten App Store records, not ten translations. Apple treats the app binary's languages separately from App Store metadata localizations, so five UI localizations and ten storefront records are compatible.

### Screenshot sets — 5

Produce English, French, German, Spanish and Brazilian Portuguese screenshot sets. Reuse the same language artwork across its metadata variants, while changing locale-sensitive sample amounts, dates or terminology only when the difference is visible and meaningful.

### Explicit non-launch languages

- **Dutch:** no launch localization. English is a supported App Store fallback in the Netherlands, and the incremental professional demand did not justify a separate binary, metadata and QA path.
- **Italian:** no launch localization; serve through English until storefront evidence clears an expansion gate.
- **Portuguese (Portugal):** no launch localization; Brazilian Portuguese must not be presented as European Portuguese.
- **Japanese:** no launch localization. The complete Japanese storefront audit did not independently validate the opportunity under the locked demand/pain rules.

Add any non-launch language only after one of these gates is met: at least 10% of qualified organic demand from that language, at least 20 credible customer requests, or a localized conversion test that clearly beats the English fallback.

### Format profiles by market cluster

| Cluster | Required launch formats/conventions |
|---|---|
| US/Canada | CSV/TSV/XLSX, OFX/QFX/QBO/QIF, BAI2, MM/DD and DD/MM safeguards, decimal point |
| UK/Australia and English fallback markets | CSV/TSV/XLSX, OFX/QFX/QIF, BAI2 where supplied, DD/MM defaults |
| France/Germany/Spain and continental-European fallback markets | CSV/TSV/XLSX, CAMT.053, CAMT.054 warning path, MT940, OFX/QIF, IBAN/reference preservation, decimal comma/point and localized delimiters |
| Mexico/Brazil and Latin-American fallback markets | CSV/TSV/XLSX, OFX/QIF, localized encodings, DD/MM, decimal comma/point and currency/account separation |

## 15. App Store positioning

**Naming status:** `LOCKED`  
**Primary category:** Finance  
**Secondary category:** Business

### ASO-maximized localized names and subtitles

| UI language / metadata records | Locked App Store name | Characters | Complementary subtitle | Characters |
|---|---|---:|---|---:|
| Neutral English — en-US, en-CA, en-GB, en-AU | `Bank Reconciliation: CSV` | 24 | `Compare OFX, CAMT & exports` | 27 |
| Neutral French — fr-FR, fr-CA | `Rapprochement bancaire : CSV` | 28 | `Comparez OFX, CAMT et exports` | 29 |
| Standard German — de-DE | `Bankabstimmung: CSV & CAMT` | 26 | `Exporte prüfen, Fehler finden` | 29 |
| Neutral Spanish — es-ES, es-MX | `Conciliación bancaria: CSV` | 26 | `Compara OFX, CAMT y exportes` | 28 |
| Brazilian Portuguese — pt-BR | `Conciliação bancária: CSV` | 25 | `Compare OFX, CAMT e arquivos` | 28 |

The accounting job appears first in every title. `CSV` adds the most universally recognized supported file intent without turning the name into a keyword list. The subtitle adds complementary format and comparison intent without repeating the complete title. Use the same neutral-language name and subtitle across same-language metadata records; country-specific variation belongs in the keyword field, description examples and pricing, not in the product identity.

The titles are within Apple's 30-character limit. No exact title collision was found in the nine checked storefronts on 21 September 2026. This is an App Store availability screen, not a legal trademark clearance; repeat the exact-name and trademark check immediately before reserving the app record.

### Three-screenshot campaign — exact captions

Use the same three-frame story for iPhone, iPad and Mac. The authentic screens listed below must prove the captions.

| Language | Screenshot 1 — immediate value | Screenshot 2 — shortest workflow | Screenshot 3 — differentiator/proof |
|---|---|---|---|
| English | **Find missing, changed and duplicate transactions** | **Compare bank and ledger exports** | **Lock a review-ready evidence pack** |
| French | **Repérez les écarts et doublons** | **Comparez exports bancaires et comptables** | **Conservez un dossier justificatif** |
| German | **Fehlende, geänderte und doppelte Buchungen** | **Bank- und Buchhaltungsexporte vergleichen** | **Nachweise für die Prüfung sichern** |
| Spanish | **Detecta movimientos ausentes, modificados y duplicados** | **Compara exportaciones bancarias y contables** | **Guarda pruebas de conciliación verificables** |
| Brazilian Portuguese | **Encontre lançamentos ausentes, alterados e duplicados** | **Compare exportações bancárias e contábeis** | **Guarde evidências da conciliação** |

Required authentic UI for the campaign:

1. **Screenshot 1:** result summary with missing, changed and duplicate exception groups visible.
2. **Screenshot 2:** the synchronized bank-versus-ledger comparison view with both source identities visible.
3. **Screenshot 3:** locked reconciliation detail or evidence-pack screen showing hashes, totals, exceptions and lock state.

Do not put the app name, logo, price, rating, ranking or a formal-audit claim in the captions. Use the locked borderless screenshot geometry and five screenshot language sets; reuse each set across its same-language metadata variants.

### Rejected title directions

| Rank | Rejected title | Reason |
|---:|---|---|
| 1 | `Bank Export Reconciliation` | Truthful but “bank export reconciliation” is not the primary natural-language search phrase; it weakens the exact `bank reconciliation` pull term |
| 2 | `CSV Reconciliation Tool` | Too broad; hides the bank-versus-ledger job and attracts unrelated data-diff intent |
| 3 | `Reconciliation Audit Tool` | “Audit” risks implying assurance that the app explicitly does not provide |

### Propagation checklist

- Use the locked localized names and subtitles in all ten App Store metadata records.
- Use the matching five caption sets in the iPhone, iPad and Mac screenshot campaigns.
- Use `Bank Reconciliation: CSV` as the English display name, onboarding name, support-page product name and reviewer-note product name.
- Keep the legal limitation language: the app proves the compared files and recorded decisions; it does not provide audit, legal, tax or accounting assurance.
- Run native professional-language QA and the exact-name/trademark recheck before App Store submission.

The listing must never imply bank affiliation, bank connectivity, formal audit assurance or legal/tax certification.

## 16. Monetization — locked

No subscription and no ads at launch.

| Tier | Price | Entitlement |
|---|---:|---|
| Free | Free | One entity, one saved mapping, two locked reconciliations; failed imports/previews do not count |
| Pro Universal Purchase | **US$39.99 one-time** | One entity, unlimited accounts, mappings, reconciliations and evidence packs |
| Accountant / Power User | **US$99.99 one-time** | Unlimited client entities, batch folders, review queue and branded evidence-pack header |

Use local-equivalent pricing, not simple foreign-exchange conversion. The higher tier is justified by multi-client workflow, not by hiding the core reconciliation result.

## 17. Features that must not enter version 1

- Budgeting, charts of spending or net-worth tracking.
- Manual daily transaction entry.
- Invoicing, bills, receipts, payroll or tax filing.
- Bank connectivity or automatic synchronization.
- PDF/OCR conversion.
- AI matching that cannot explain deterministic evidence.
- Editing, “fixing” or rewriting the original source files.
- Collaboration, cloud team accounts or live approval routing.
- An assurance badge claiming the ledger or financial statements are correct.

## 18. Engine acceptance gates

The engine is not complete until all of the following pass:

1. A corpus covering every format family and all launch locale conventions.
2. Round-trip source preservation: every result links back to the exact original value and row/record.
3. Duplicate, one-to-many, split/merge and ambiguous-match adversarial tests.
4. Cross-currency fail-closed tests.
5. Opening/closing and running-balance arithmetic tests.
6. CAMT namespace/version tests and MT940/BAI2 control-total tests.
7. Large-file tests on the oldest supported iPhone and iPad plus Mac.
8. Interrupted import, low-storage and corrupted-file recovery tests.
9. Snapshot/hash reproducibility tests.
10. Evidence-pack totals independently reproduce the on-screen totals.
11. All five launch UI languages and all ten App Store metadata records complete native QA, including date, decimal, delimiter and financial terminology.
12. A new user can import two valid files and reach the result summary without creating an account or configuring nonessential settings.

## 19. Final build instruction

Build **one common deterministic engine** with locale and format adapters. Lead with Mode A, because “bank export versus ledger export” is the clearest purchase job. Modes B and C reuse the same normalized transaction model, parser corpus, matching engine and evidence system; they are not separate apps.

The product wins only if it stays independent. The moment it becomes another ledger, bank connector or converter, it enters crowded categories and loses the reason to exist.

## 20. Final live storefront verification — 21 September 2026

The final pass checked the United States, Canada, United Kingdom, Australia, France, Germany, Spain, Mexico and Brazil. It found credible adjacent supply, but no clearly positioned direct substitute for the locked product.

| Storefronts | Strongest visible adjacent supply | What is already served | Gap that remains |
|---|---|---|---|
| United States, Canada, United Kingdom, Australia | StatementSnap; Checkbook; Debit & Credit | PDF/image-to-structured conversion, transfer review, or reconciliation inside the app's own ledger | Independent comparison of two arbitrary structured exports, history-mutation detection and a locked evidence pack |
| France | Stmt; MaxiCompte; MoneyStats | Statement conversion or personal-finance ledger reconciliation | Source-independent bank-versus-ledger and export-versus-export proof |
| Germany | Kontoauszug Konverter / Bank Statement Conversion; FiQu | Broad conversion formats or import into a finance manager | Cross-source exception classification and immutable evidence without adopting a new ledger |
| Spain, Mexico | Conversor Extractos Banco / Bank Statement Conversion; finance and vertical apps | PDF/image/CSV conversion and system-specific reconciliation | A standalone structured-export control product |
| Brazil | Bank Statement Conversion; Money Pro | Conversion or reconciliation inside an ongoing finance system | Local, independent comparison of exported files and evidence retention |

Important market signal: several converter listings have broad output-format claims but still lack enough ratings for an App Store overview in the checked storefronts. Mature finance managers show that users understand reconciliation, but their reconciliation remains tied to their own ledger. Therefore the opportunity is validated, not because there are no competitors, but because the exact control job remains unowned.

### Final go/no-go

**GO — 9/10 confidence**, with one positioning condition: every product page and onboarding flow must lead with **compare two exports**, never with “convert a bank statement.” PDF/OCR remains excluded from version 1. The format scope, one-time pricing and three-mode engine remain unchanged.

## 21. Evidence base

Country audits used to reach the decision:

- `WorksBien-France-App-Store-Opportunity-Audit-2026-09-21.md`
- `WorksBien-US-App-Store-Opportunity-Audit-2026-09-21.md`
- `WorksBien-Germany-App-Store-Opportunity-Audit-2026-09-21.md`
- `WorksBien-Japan-App-Store-Opportunity-Audit-2026-09-21.md`

Live App Store competitor checks:

- [StatementSnap: Bank Converter — United States](https://apps.apple.com/us/app/statementsnap-bank-converter/id6773473924)
- [StatementSnap: Bank Converter — Canada](https://apps.apple.com/ca/app/statementsnap-bank-converter/id6773473924)
- [StatementSnap: Bank Converter — United Kingdom](https://apps.apple.com/gb/app/statementsnap-bank-converter/id6773473924)
- [StatementSnap: Bank Converter — Australia](https://apps.apple.com/au/app/statementsnap-bank-converter/id6773473924)
- [Stmt: Convertisseur Bancaire — France](https://apps.apple.com/fr/app/stmt-convertisseur-bancaire/id6749172186?platform=mac)
- [Kontoauszug Konverter — Germany](https://apps.apple.com/de/app/kontoauszug-konverter/id6744940033)
- [Conversor Extractos Banco — Spain](https://apps.apple.com/es/app/conversor-extractos-banco/id6744940033)
- [Conversor Extractos Banco — Mexico](https://apps.apple.com/mx/app/conversor-extractos-banco/id6744940033)
- [Bank Statement Conversion — Brazil](https://apps.apple.com/br/app/bank-statement-conversion/id6744940033)
- [Debit & Credit — United Kingdom](https://apps.apple.com/gb/app/debit-credit/id882637543)
- [Checkbook — United States](https://apps.apple.com/us/app/checkbook-budget-expenses/id442980285)
- [MaxiCompte — France](https://apps.apple.com/fr/app/maxicompte-budget-familial/id1570961356)
- [FiQu — Germany](https://apps.apple.com/de/app/fiqu-track-spending-savings/id1529794090)
- [Money Pro — Brazil](https://apps.apple.com/br/app/money-pro-finan%C3%A7as-pessoais/id918609651)

Apple localization references:

- [App Store localizations](https://developer.apple.com/help/app-store-connect/reference/app-information/app-store-localizations)
- [Localize app information](https://developer.apple.com/help/app-store-connect/manage-app-information/localize-app-information)
- [Creating Your Product Page](https://developer.apple.com/app-store/product-page/)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
