# Format Profiles and Completion Definition

| Family | Production parser obligations | Checkpoint state |
|---|---|---|
| CSV / TSV | Strict quoting, exact width, bounded records/fields/scalars, replayable mapping, exact locale date/amount interpretation | Implemented; Apple-tested |
| XLSX | Bounded ZIP enumeration before materialization, no links/duplicate paths, worksheet selection in replay hash, rich shared strings, strict cell typing | Implemented; Apple-tested with deterministic fixture |
| OFX / QFX / QBO | Separate complete SGML and namespace-aware XML paths, decoded entities, complete statement envelopes, account/currency/FITID preservation | Implemented; XML and SGML Apple-tested |
| QIF / QMTF | `^` termination, section boundaries, conflicting critical-field rejection, locale profile binding | Implemented; Apple-tested |
| CAMT.053 | Versions 001.02–001.08, namespace-aware entries, balance currency from each `Amt@Ccy`, full references/remittance | Implemented; Apple-tested on 001.08 fixture |
| CAMT.054 | Same structural rigor plus forced `notificationOnly` completeness warning | Implemented; Apple-tested on 001.02 fixture |
| MT940 | Complete `:20/:25/:28C/:60/:62` segments, partition-scoped balances, RC/RD reversal signs | Implemented; Apple-tested |
| BAI2 | 01/02/03/16/49/98/99 structure, 88 continuation rules, currency scales, literal control totals/counts, opening/closing codes | Implemented; Apple-tested, including corrupt-control rejection |

These are implementation and deterministic fixture claims, not production corpus certification. Production completion still requires hostile truncation/duplication/oversize matrices, locale ambiguity cases, source-locator and replay checks across retained real-bank fixtures, and parser fuzzing.
