#!/usr/bin/env python3
"""Reproduce the cpu-task-service correlation numbers from exported Perfetto data.

Inputs (produced by export_data.sh with trace_processor_shell v57.1):
  out/q-slices.csv   sched_slice of UPID 3      (tid,tname,ts,dur,cpu,end_state)
  out/q-states.csv   thread_state of UPID 3      (tid,ts,dur,state)
  out/q-cpufreq.csv  cpu_counter_track 'cpufreq' (cpu,ts,raw_value[kHz])
  requests-after.jsonl  business log lines {"t":"req", ...} pulled after capture

Clock: trace timestamps are CLOCK_BOOTTIME ns; the service log uses
CLOCK_MONOTONIC ns. On this board there was no suspend, so both are the same
axis (verified by matching sched slices against request st/en windows).
"""
import csv, json, collections, sys

T0, T1 = 46290515351739, 46345505419807          # trace_bounds
REQ_WORKER = 10289

def load():
    sl = [dict(tid=int(r['tid']), tname=r['tname'], ts=int(r['ts']),
               dur=int(r['dur']), cpu=int(r['cpu'])) for r in csv.DictReader(open('out/q-slices.csv'))]
    stt = [dict(tid=int(r['tid']), ts=int(r['ts']), dur=int(r['dur']),
                state=r['state']) for r in csv.DictReader(open('out/q-states.csv'))]
    cf = [dict(cpu=int(r['cpu']), ts=int(r['ts']), khz=float(r['raw_value']))
          for r in csv.DictReader(open('out/q-cpufreq.csv'))]
    req = [json.loads(l) for l in open('requests-after.jsonl') if l.strip()]
    req = [r for r in req if r.get('t') == 'req']
    for v in (sl, stt, cf, req):
        v.sort(key=lambda x: x['ts'] if 'ts' in x else x['enq'])
    return sl, stt, cf, req

def ov(ts, dur, a, b):
    return max(0, min(ts + dur, b) - max(ts, a))

def main():
    sl, stt, cf, req = load()
    inw = [r for r in req if T0 <= r['enq'] <= T1]
    by_sl = collections.defaultdict(list)
    by_st = collections.defaultdict(list)
    for s in sl:
        by_sl[s['tid']].append(s)
    for s in stt:
        by_st[s['tid']].append(s)

    def states(tid, a, b):
        c = collections.Counter()
        for s in by_st[tid]:
            if s['ts'] >= b:
                break
            c[s['state']] += ov(s['ts'], s['dur'], a, b)
        return c

    def cls(d):
        return ('A fast(<0.1ms)' if d < 100 else 'B degraded(1-5ms)' if d < 5000
                else 'C bad(5-50ms)' if d < 50000 else 'D severe(>50ms)')

    print('=== 1. request classes (trace window %.2fs, %d requests) ===' %
          ((T1 - T0) / 1e9, len(inw)))
    agg = collections.defaultdict(lambda: collections.Counter())
    for r in inw:
        k = cls(r['dur_us'])
        c = states(REQ_WORKER, r['st'], r['en'])
        a = agg[k]
        a['n'] += 1
        a['dur'] += r['dur_us'] / 1000
        a['run'] += c['Running'] / 1e6
        a['R'] += (c['R'] + c['R+']) / 1e6
        a['S'] += c['S'] / 1e6
    print(f"{'class':20s} {'n':>4s} {'avg_dur_ms':>10s} {'avg_run_ms':>10s} {'avg_R_ms':>9s} {'avg_S_ms':>9s}")
    for k in sorted(agg):
        a = agg[k]
        print(f"{k:20s} {a['n']:4d} {a['dur']/a['n']:10.2f} {a['run']/a['n']:10.2f} {a['R']/a['n']:9.2f} {a['S']/a['n']:9.2f}")

    print('\n=== 2. slow requests (>50ms) and CPU6/7 occupation inside [st,en] ===')
    for r in inw:
        if r['dur_us'] <= 50000:
            continue
        a, b = r['st'], r['en']
        c = states(REQ_WORKER, a, b)
        occ = collections.Counter()
        for s in sl:
            if s['cpu'] not in (6, 7) or s['tid'] == 0:
                continue
            o = ov(s['ts'], s['dur'], a, b)
            if o > 0:
                occ[(s['cpu'], s['tname'])] += o
        busy6 = sum(v for (cpu, _), v in occ.items() if cpu == 6)
        busy7 = sum(v for (cpu, _), v in occ.items() if cpu == 7)
        top6 = ', '.join(f"{t}={v/1e6:.1f}ms" for (cpu, t), v in
                         sorted(occ.items(), key=lambda kv: -kv[1])[:4] if cpu == 6)
        print(f"id={r['id']} t_rel={(r['enq']-T0)/1e9:6.2f}s dur={r['dur_us']/1000:7.2f}ms "
              f"run={c['Running']/1e6:6.2f} R={(c['R']+c['R+'])/1e6:6.2f} S={c['S']/1e6:6.2f} | "
              f"CPU6 busy={100*busy6/(b-a):5.1f}% CPU7 busy={100*busy7/(b-a):4.1f}% | {top6}")

    print('\n=== 3. per-slot (8s) phase summary, driven by service.log slot events ===')
    slots = [(-2.24, 'idx4'), (5.77, 'idx5'), (13.78, 'idx0'), (21.77, 'idx1'),
             (29.76, 'idx2'), (37.77, 'idx3'), (45.76, 'idx4'), (53.77, 'idx5')]
    bounds = [s[0] for s in slots] + [60.0]
    names = ['req-worker', 'calc-worker', 'job-alpha', 'job-beta', 'sync-waiter']
    for i, (start, label) in enumerate(slots):
        a, b = T0 + int(start * 1e9), T0 + int(bounds[i + 1] * 1e9)
        rs = [r for r in inw if a <= r['enq'] < b]
        c = collections.Counter()
        for s in sl:
            if s['ts'] < a or s['ts'] >= b:
                continue
            c[s['tname']] += ov(s['ts'], s['dur'], a, b) / 1e6
        med = sorted(r['dur_us'] for r in rs)[len(rs) // 2] if rs else 0
        mx = max((r['dur_us'] for r in rs), default=0)
        print(f"{label} [{start:6.2f},{bounds[i+1]:6.2f})s n={len(rs):3d} median={med:9.1f}us max={mx:9.1f}us | " +
              ' '.join(f"{n}={c[n]:6.1f}ms" for n in names))

    print('\n=== 4. req-worker CPU split per core, migrations, long sleeps ===')
    per = collections.Counter()
    for s in by_sl[REQ_WORKER]:
        per[s['cpu']] += s['dur'] / 1e6
    print('req-worker CPU by core (ms):', {k: round(v, 1) for k, v in sorted(per.items())})
    print('req-worker S intervals >60ms:',
          [(round((s['ts']-T0)/1e9, 2), round(s['dur']/1e6, 2))
           for s in by_st[REQ_WORKER] if s['state'] == 'S' and s['dur'] > 60e6])

    print('\n=== 5. frequency at the two slow-window types ===')
    def freq_at(cpu, t):
        v = None
        for r in cf:
            if r['cpu'] == cpu and r['ts'] <= t:
                v = r['khz']
            elif r['cpu'] == cpu and r['ts'] > t:
                break
        return v
    for label, t in (('saturated 52ms window', T0 + int(30.00e9)),
                     ('blocking 92ms window', T0 + int(38.30e9))):
        print(f"{label}: cpu6={freq_at(6, t)} kHz cpu7={freq_at(7, t)} kHz")

if __name__ == '__main__':
    main()
