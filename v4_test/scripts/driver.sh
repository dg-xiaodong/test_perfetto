#!/bin/sh
# Sequential board runs; each trace pulled back immediately.
B() { sshpass -p root ssh -o StrictHostKeyChecking=no root@192.168.1.10 "$@"; }
TR=/userdata/perfetto-debug
run() {
  name=$1; cfg=$2; mode=$3
  B "sh $TR/run_case.sh $name $TR/$cfg $mode" > $name.ssh.log 2>&1
  echo "== $name done rc=$? $(date +%H:%M:%S)"
  sshpass -p root scp -o StrictHostKeyChecking=no "root@192.168.1.10:$TR/$name.pftrace" "root@192.168.1.10:$TR/$name.run.log" . >/dev/null 2>&1
  echo "   pulled $(ls -l $name.pftrace 2>/dev/null | awk '{print $5}') bytes"
}
run run0 mem1.pbtxt none
run run1 mem1.pbtxt tmpfs
# independent check that the script's file really is 24MiB on tmpfs (outside the trace)
B 'sh /data/rdk_mem_case.sh >/dev/null 2>&1 & sleep 20; echo "--- df /data:"; df -h /data | tail -1; echo "--- file:"; ls -l /data/.memcase.*; echo "--- meminfo:"; grep -E "^(MemFree|MemAvailable|Cached|Shmem):" /proc/meminfo; wait' > filestep_during_manual_run.txt 2>&1
echo "== manual file-step check done"
run run2 mem2.pbtxt ext4
run run3 mem3.pbtxt cycles
run run4 mem1.pbtxt kill
echo "ALL_RUNS_DONE $(date +%H:%M:%S)"
