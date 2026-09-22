# Format Profiles and Completion Definition

| Family | Production parser obligations | Checkpoint state |
|---|---|---|
| CSV / TSV | Strict quoting, exact width, bounded records/fields/scalars, replayable mapping, exact locale date/amount interpretation | Source present; Apple test blocked |
| XLSX | Bounded ZIP enumeration before materialization, no links/duplicate paths, worksheet selection in replay hash, rich shared strings, strict cell typing | Not implemented |
| OFX / QFX / QBO | Separate complete SGML and namespace-aware XML paths, decoded entities, complete statement envelopes, account/currency/FITID preservation | Not implemented |
| QIF / QMTF | `^` termination, section boundaries, conflicting critical-field rejection, locale profile binding | Not implemented |
| CAMT.053 | Versions 001.02–001.08, namespace-aware entries, balance currency from each `Amt@Ccy`, full references/remittance | Not implemented |
| CAMT.054 | Same structural rigor plus forced `notificationOnly` completeness warning | Not implemented |
| MT940 | Complete `:20/:25/:28C/:60/:62` segments, partition-scoped balances, RC/RD reversal signs | Not implemented |
| BAI2 | 01/02/03/16/49/98/99 structure, 88 continuation rules, currency scales, literal control totals/counts, opening/closing codes | Not implemented |

An adapter is not complete until hostile truncation, duplication, oversized input, locale ambiguity, source locator preservation, deterministic replay and retained real-world fixtures all pass.
