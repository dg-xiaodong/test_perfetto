-- kmem/rss_stat 原始事件（旁证：tmpfs 页属于页缓存，不进入进程 RSS）
SELECT ts, name, cpu, utid, arg_set_id FROM ftrace_event WHERE name = 'rss_stat' ORDER BY ts LIMIT 20;

-- 单条事件的字段（把 123 换成上面的 arg_set_id）
-- SELECT key, int_value, string_value FROM args WHERE arg_set_id = 123;
