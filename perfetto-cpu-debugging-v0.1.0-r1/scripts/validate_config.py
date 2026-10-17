#!/usr/bin/env python3
"""Host-side CPU Skill package and TraceConfig preflight.

rc 0: requested static checks pass; rc 1: definite failure; rc 2: requested
schema cannot be validated. Never implies board producer/data source readiness.
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
REQUIRED = [
    'SKILL.md', 'README.md', 'references/00-routing.md',
    'references/01-scheduling.md', 'references/02-frequency.md',
    'references/03-profiling.md', 'references/04-platforms.md',
    'references/05-quality.md', 'references/06-ui.md', 'references/sources.md',
    'scripts/make_config.py', 'scripts/validate_config.py',
    'scripts/survey.sh', 'scripts/linux_session_lib.sh',
    'scripts/linux_trace_session.sh', 'scripts/host_pull.sh',
    *[f'sql/{name}' for name in (
        '00-inventory.sql', '01-cpu-usage.sql', '02-thread-states.sql',
        '03-runnable-latency.sql', '04-cpu-frequency.sql',
        '05-cpu-time-buckets.sql', '06-cpu-spike-episodes.sql',
        '07-perf-samples.sql', '08-core-busy.sql')],
]


def check_resources():
    bad = [f for f in REQUIRED if not (ROOT/f).is_file() or (ROOT/f).stat().st_size == 0]
    cfg = list((ROOT/'configs').glob('*.pbtxt'))
    if len(cfg) != 4 or any(p.stat().st_size == 0 for p in cfg):
        bad.append('configs/ must contain 4 nonempty pbtxt templates')
    return bad


def structure(txt):
    # Textproto scanner: ignore comments and brace-looking characters in strings.
    balance = 0
    quote = False
    escaped = False
    comment = False
    for c in txt:
        if comment:
            if c == '\n': comment = False
            continue
        if quote:
            if escaped: escaped = False
            elif c == '\\': escaped = True
            elif c == '"': quote = False
            continue
        if c == '#': comment = True
        elif c == '"': quote = True
        elif c == '{': balance += 1
        elif c == '}':
            balance -= 1
            if balance < 0: return False, 'unexpected closing brace'
    if quote or balance != 0:
        return False, 'unclosed quote or braces'
    if not re.search(r'\bduration_ms\s*:\s*[0-9]+', txt):
        return False, 'missing duration_ms'
    if not re.search(r'\bdata_sources\s*\{', txt):
        return False, 'missing data_sources'
    return True, 'structural checks passed (NOT official schema)'


def official_schema(path, descriptor):
    try:
        from google.protobuf import descriptor_pb2, descriptor_pool, message_factory, text_format
    except ImportError:
        return None, 'python protobuf unavailable on host'
    try:
        file_set = descriptor_pb2.FileDescriptorSet()
        file_set.ParseFromString(pathlib.Path(descriptor).read_bytes())
        pool = descriptor_pool.DescriptorPool()
        remaining = list(file_set.file)
        while remaining:
            next_remaining = []
            progressed = False
            for fd in remaining:
                try:
                    pool.Add(fd)
                    progressed = True
                except (TypeError, KeyError):
                    next_remaining.append(fd)
            if not progressed:
                return None, 'descriptor dependencies incomplete'
            remaining = next_remaining
        desc = pool.FindMessageTypeByName('perfetto.protos.TraceConfig')
        msg = message_factory.GetMessageClass(desc)()
        text_format.Parse(pathlib.Path(path).read_text(), msg, allow_unknown_field=False)
        return True, 'validated with supplied collector-matching descriptor'
    except Exception as exc:
        return False, f'{type(exc).__name__}: {exc}'


def main():
    a = argparse.ArgumentParser(description=__doc__)
    a.add_argument('config', nargs='?')
    a.add_argument('--check-resources', action='store_true')
    a.add_argument('--descriptor-set')
    args = a.parse_args()
    if not args.config and not args.check_resources:
        a.error('specify CONFIG and/or --check-resources')
    if args.check_resources:
        bad = check_resources()
        if bad:
            print('[FAIL] missing resources:', ', '.join(bad))
            return 1
        print(f'[PASS] resources: {len(REQUIRED)} essential files + 4 configs')
    if args.config:
        try: txt = pathlib.Path(args.config).read_text(encoding='utf-8')
        except OSError as exc:
            print(f'[FAIL] unreadable config: {exc}')
            return 1
        ok, reason = structure(txt)
        print(f'[{"PASS" if ok else "FAIL"}] config: {reason}')
        if not ok: return 1
        if args.descriptor_set:
            verified, reason = official_schema(args.config, args.descriptor_set)
            print(f'[{"PASS" if verified is True else "FAIL" if verified is False else "UNKNOWN"}] schema: {reason}')
            if verified is not True: return 1 if verified is False else 2
        else:
            print('[UNKNOWN] official schema: no --descriptor-set (not treated as failure of static check)')
    print('[NOTE] runtime event support, perf privileges, data, and flush NOT checked')
    return 0

if __name__ == '__main__': raise SystemExit(main())
