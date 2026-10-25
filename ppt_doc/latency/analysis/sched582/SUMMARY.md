# TrackEvent latency analysis

{
  "observed_requests": 1400,
  "success_samples": 1371,
  "complete_requests": 1371,
  "integrity_counts": {
    "CENSORED": 1,
    "COMPLETE": 1371,
    "INCOMPLETE": 28
  },
  "outcome_counts": {
    "SUCCESS": 1372,
    "UNKNOWN": 28
  },
  "p50_ns": 15988959,
  "p95_ns": 1896292626,
  "p99_ns": 2433440501,
  "tail_sample_warning": false,
  "quality_loss": false,
  "quantile_method": "nearest rank ceil(q*n); empirical only; <1000 is a warning policy, not a confidence test"
}

Only COMPLETE + SUCCESS + no global loss enter strict latency metrics. DROP/TIMEOUT remain separate.
Critical path is NOT computed. Stage wall sum, wall union and queue sum are separate dimensions.
UI SQL is a derived interval table, not new measurements or a screenshot.
