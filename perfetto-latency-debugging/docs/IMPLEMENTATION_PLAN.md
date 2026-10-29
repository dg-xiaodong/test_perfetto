# perfetto-latency-debugging v0.1.0 implementation record

Approved scope: TrackEvent-only entry; original C++17 integration example; Slice,
Flow and Counter; composite request and stage-instance identity; separate evidence
integrity and business outcome; optional ftrace; no general log converter, no
board access, no automatic changes to production or existing Skills.

1. Write failure cases for identities, incomplete lifecycles, retries, flow links,
   interval arithmetic and configuration policy before implementation.
2. Implement bounded configuration generation, read-only inventory, one-query
   execution and host-side analysis of actual TrackEvent exports.
3. Provide C++ SDK integration, cross-thread explicit tracks and bounded pipeline.
4. Run local tests; inspect source/SQL/resources; package with hash manifest.

Evidence ledger:
- Official docs reviewed: TrackEvent, SDK, prelude tables, clocks (2026-10-18).
- Network attempt for official v58.2 SDK and Linux tools failed DNS resolution in
  this runtime. Do not turn a mock or source inspection into SDK/TP/X5 PASS.
- Independent Agent behavior A/B not available here. Historical CPU/Scheduling
  failures motivate tests but are NOT a new RED/GREEN Agent regression.
