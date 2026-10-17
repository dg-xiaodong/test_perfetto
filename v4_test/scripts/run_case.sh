#!/bin/sh
# usage: run_case.sh <name> <config> <mode>
#   tmpfs  : run the user's /data/rdk_mem_case.sh unchanged (24MiB file on /data = tmpfs)
#   ext4   : same dd/sleep/rm timing, file redirected to /userdata (ext4) as control
#   cycles : 20 x (write 24MiB to /data tmpfs + rm) leak-accumulation test
#   kill   : start the user's script, SIGKILL it during the hold so the tmpfs file is orphaned,
#            then rm the orphan and observe recovery -- all inside one trace
# No shell sampler runs: /proc sampling would fork thousands of processes and pollute the
# memory picture. Ground truth = Perfetto meminfo/process_stats/rss_stat + host-side snapshots.
NAME=$1; CFG=$2; MODE=$3
TR=/userdata/perfetto-debug; LOG=$TR/$NAME.run.log
up() { cut -d' ' -f1 /proc/uptime; }
echo "=== run $NAME mode=$MODE cfg=$(basename $CFG) script_md5=$(md5sum /data/rdk_mem_case.sh | cut -d' ' -f1) bytes=$(wc -c < /data/rdk_mem_case.sh) kernel=$(uname -r) start=$(date) ===" > $LOG
sed -n '1,6p' /proc/meminfo >> $LOG
$TR/tracebox --txt -c "$CFG" -o $TR/$NAME.pftrace > $TR/$NAME.tracebox.log 2>&1 &
TPID=$!
sleep 8
echo "workload_start_uptime=$(up)" >> $LOG
case "$MODE" in
  tmpfs)
    sh /data/rdk_mem_case.sh >> $LOG 2>&1 ;;
  ext4)
    sed 's#/data/#/userdata/perfetto-debug/#' /data/rdk_mem_case.sh > /tmp/case_ext4.sh
    sh /tmp/case_ext4.sh >> $LOG 2>&1 ;;
  cycles)
    n=0
    while [ $n -lt 20 ]; do
      dd if=/dev/zero of=/data/.memcase.cycles bs=1048576 count=24 2>/dev/null
      echo "cycle $n written uptime=$(up) bytes=$(wc -c < /data/.memcase.cycles)" >> $LOG
      rm -f /data/.memcase.cycles
      echo "cycle $n removed uptime=$(up)" >> $LOG
      n=$((n+1)); sleep 1
    done ;;
  cycles_hold)
    n=0
    while [ $n -lt 10 ]; do
      dd if=/dev/zero of=/data/.memcase.cycles bs=1048576 count=24 2>/dev/null
      echo "cycle $n written uptime=$(up) bytes=$(wc -c < /data/.memcase.cycles)" >> $LOG
      sleep 3
      rm -f /data/.memcase.cycles
      echo "cycle $n removed uptime=$(up)" >> $LOG
      n=$((n+1)); sleep 1
    done ;;
  kill)
    sh /data/rdk_mem_case.sh >> $LOG 2>&1 &
    W=$!
    sleep 18
    echo "kill_at_uptime=$(up) stale_file=$(ls -l /data/.memcase.* 2>/dev/null | awk '{print $5}')" >> $LOG
    kill -9 $W 2>/dev/null
    sleep 10
    echo "stale_held_uptime=$(up) stale_file=$(ls -l /data/.memcase.* 2>/dev/null | awk '{print $5}')" >> $LOG
    sleep 8
    rm -f /data/.memcase.*
    echo "stale_removed_uptime=$(up)" >> $LOG
    sleep 10 ;;
esac
echo "workload_end_uptime=$(up)" >> $LOG
if grep -q "TEST END" $LOG; then echo "WORKLOAD_OK=1" >> $LOG; else echo "WORKLOAD_OK=0" >> $LOG; fi
sleep 25
echo "recovery_end_uptime=$(up)" >> $LOG
wait $TPID; echo "tracebox_exit=$?" >> $LOG
rm -f /data/.memcase.* /userdata/perfetto-debug/.memcase.*
sed -n '1,6p' /proc/meminfo >> $LOG
