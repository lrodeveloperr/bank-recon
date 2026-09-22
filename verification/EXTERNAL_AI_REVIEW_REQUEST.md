# Independent Review Request

Audit this frozen candidate without assuming its README claims are true. Prioritize:

- Swift 6 compile errors and unsafe Foundation/Darwin assumptions;
- exact amount decoding, comparison and arithmetic boundaries;
- CSV state-machine completeness and allocation limits;
- role/period/partition correctness across all three modes;
- ambiguity, duplicate, mutation, manual-match staleness and explanation state rules;
- evidence byte replay, canonical JSON and job/result binding;
- concurrent store actors/processes, crash windows and lineage validation;
- entitlement/usage tampering and restore implications;
- discrepancies between manifest coverage and actual source.

Report critical/high findings with a concrete reproduction. Do not approve engine lock while any production adapter or Apple gate remains blocked.
