INCLUDE PERFETTO MODULE linux.perf.samples;
SELECT name, self_count, cumulative_count FROM linux_perf_samples_summary_tree ORDER BY cumulative_count DESC LIMIT 25;
