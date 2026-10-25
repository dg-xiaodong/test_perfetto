# TrackEvent latency analysis

{
  "observed_requests": 1800,
  "success_samples": 1800,
  "complete_requests": 1800,
  "integrity_counts": {
    "COMPLETE": 1800
  },
  "outcome_counts": {
    "SUCCESS": 1800
  },
  "p50_ns": 15924666,
  "p95_ns": 1966189543,
  "p99_ns": 2431369126,
  "tail_sample_warning": false,
  "quality_loss": false,
  "quantile_method": "nearest rank ceil(q*n); empirical only; <1000 is a warning policy, not a confidence test"
}

Only COMPLETE + SUCCESS + no global loss enter strict latency metrics. DROP/TIMEOUT remain separate.
Critical path is NOT computed. Stage wall sum, wall union and queue sum are separate dimensions.
UI SQL is a derived interval table, not new measurements or a screenshot.
