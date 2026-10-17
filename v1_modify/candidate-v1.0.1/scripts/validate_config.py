#!/usr/bin/env python3
"""Validate pbtxt using a descriptor set from YOUR collector's Perfetto source.

Also provides three preflight checks that do NOT need a descriptor:
  --check-resources   required references/sql/scripts/configs/tests exist and readable
  --deploy-name NAME  config process_cmdline basename == the name actually launched
  --binary PATH       ELF has PT_INTERP (a dynamic preload target needs dynamic linking)

Preflight is static only. It cannot prove runtime readiness, injection, stop or flush;
those still need runtime evidence (notify-fd byte, trace content, stats/logs).
"""
from __future__ import annotations
import argparse
import pathlib
import struct
import sys

REQUIRED = [
    'SKILL.md', 'README.md',
    'references/00-routing.md', 'references/01-counters.md', 'references/02-native.md',
    'references/03-managed.md', 'references/04-ui.md', 'references/05-platforms.md',
    'references/06-quality.md', 'references/07-internals-and-pprof.md',
    'references/08-worked-examples.md', 'references/09-advanced-configs.md',
    'references/sources.md',
    'sql/00-inventory.sql', 'sql/01-rss-timeline.sql', 'sql/02-counter-fallback.sql',
    'sql/03-native-live.sql', 'sql/04-native-callstacks.sql', 'sql/05-native-global-summary.sql',
    'sql/06-art-snapshots.sql', 'sql/07-kernel-events.sql', 'sql/08-pprof.sql',
    'sql/10-native-dump-capability.sql',
    'scripts/survey.sh', 'scripts/make_config.py', 'scripts/validate_config.py',
    'tests/scenarios.md',
]
MIN_CONFIGS = 10


def check_resources(root: pathlib.Path):
    """Return (status, detail): PASS if every required file is readable."""
    missing = []
    for rel in REQUIRED:
        p = root / rel
        if not p.is_file() or not p.stat().st_size:
            missing.append(rel)
    cfgs = list((root / 'configs').glob('*.pbtxt')) if (root / 'configs').is_dir() else []
    if len(cfgs) < MIN_CONFIGS:
        missing.append(f'configs/*.pbtxt (<{MIN_CONFIGS})')
    if missing:
        return 'FAIL', 'missing/unreadable: ' + ', '.join(missing)
    return 'PASS', f'{len(REQUIRED)} required files + {len(cfgs)} configs readable'


def _read_cmdline(config_text: str):
    for line in config_text.splitlines():
        s = line.split('#', 1)[0].strip()
        if s.startswith('process_cmdline'):
            _, _, rest = s.partition(':')
            return rest.strip().strip('"').strip("'")
    return None


def check_deploy_name(config_text: str, deploy_name: str):
    """Compare the launched basename with config.process_cmdline.

    heapprofd matches the target by argv[0] basename, so a mismatch means the
    process is never profiled; with PERFETTO_HEAPPROFD_BLOCKING_INIT=1 the target
    can block forever. This check only proves the static name consistency.
    """
    want = _read_cmdline(config_text)
    got = pathlib.PurePath(deploy_name).name
    if want is None:
        return 'UNKNOWN', 'config has no process_cmdline (not a heapprofd target config)'
    if want != got:
        return 'FAIL', (f"config process_cmdline={want!r} != launched basename={got!r}; "
                        'heapprofd will not match this process and BLOCKING_INIT may hang')
    return 'PASS', f'process_cmdline={want!r} == launched basename={got!r}'


def elf_has_interp(path: pathlib.Path):
    """Return True/False for ELF PT_INTERP presence, None if not a readable ELF."""
    try:
        with open(path, 'rb') as f:
            ident = f.read(16)
            if len(ident) < 16 or ident[:4] != b'\x7fELF':
                return None
            cls, data = ident[4], ident[5]
            if data not in (1, 2):
                return None
            endian = '<' if data == 1 else '>'
            if cls == 2:
                f.seek(0x20); phoff = struct.unpack(endian + 'Q', f.read(8))[0]
                f.seek(0x36); phentsize = struct.unpack(endian + 'H', f.read(2))[0]
                f.seek(0x38); phnum = struct.unpack(endian + 'H', f.read(2))[0]
                fmt, off = endian + 'I', 0
            elif cls == 1:
                f.seek(0x1C); phoff = struct.unpack(endian + 'I', f.read(4))[0]
                f.seek(0x2A); phentsize = struct.unpack(endian + 'H', f.read(2))[0]
                f.seek(0x2C); phnum = struct.unpack(endian + 'H', f.read(2))[0]
                fmt, off = endian + 'I', 0
            else:
                return None
            if phnum == 0 or phentsize < 8 or phoff <= 0:
                return False
            for i in range(phnum):
                f.seek(phoff + i * phentsize + off)
                p_type = struct.unpack(fmt, f.read(4))[0]
                if p_type == 3:  # PT_INTERP
                    return True
            return False
    except OSError:
        return None


def check_binary(path: pathlib.Path):
    has = elf_has_interp(path)
    if has is None:
        return 'UNKNOWN', f'{path} is not a readable ELF'
    if has:
        return 'PASS', f'{path} is a dynamic ELF (PT_INTERP present)'
    return 'FAIL', f'{path} has no PT_INTERP: statically linked targets ignore LD_PRELOAD'


def parse_config(descriptor_bytes: bytes, config_text: str):
    from google.protobuf import descriptor_pb2, descriptor_pool, message_factory, text_format
    desc = descriptor_pb2.FileDescriptorSet()
    desc.ParseFromString(descriptor_bytes)
    if not desc.file:
        raise ValueError('Empty descriptor set; use protoc --include_imports')
    pool = descriptor_pool.DescriptorPool()
    pending = {f.name: f for f in desc.file}
    added = set()
    while pending:
        ready = [name for name, f in pending.items() if set(f.dependency) <= added]
        if not ready:
            missing = sorted({d for f in pending.values() for d in f.dependency if d not in added})
            raise ValueError('Unresolved descriptor imports: ' + ', '.join(missing))
        for name in ready:
            pool.AddSerializedFile(pending.pop(name).SerializeToString())
            added.add(name)
    cls = message_factory.GetMessageClass(pool.FindMessageTypeByName('perfetto.protos.TraceConfig'))
    message = cls()
    text_format.Parse(config_text, message, allow_unknown_field=False)
    if not message.IsInitialized():
        raise ValueError('Missing required fields: ' + ', '.join(message.FindInitializationErrors()))
    return message


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('config', nargs='?', type=pathlib.Path)
    p.add_argument('--descriptor-set', type=pathlib.Path)
    p.add_argument('--binary-out', type=pathlib.Path)
    p.add_argument('--check-resources', action='store_true')
    p.add_argument('--deploy-name')
    p.add_argument('--binary', type=pathlib.Path)
    a = p.parse_args()

    root = pathlib.Path(__file__).resolve().parents[1]
    rc = 0
    ran = False

    if a.check_resources:
        ran = True
        st, detail = check_resources(root)
        print(f'[{st}] resources: {detail}')
        if st != 'PASS':
            rc = 2

    if a.deploy_name:
        ran = True
        if a.config is None:
            print('[FAIL] deploy-name: missing config path', file=sys.stderr)
            return 1
        st, detail = check_deploy_name(a.config.read_text(encoding='utf-8'), a.deploy_name)
        print(f'[{st}] deploy-name: {detail}')
        if st == 'FAIL':
            rc = 1

    if a.binary:
        ran = True
        st, detail = check_binary(a.binary)
        print(f'[{st}] binary: {detail}')
        if st == 'FAIL':
            rc = 1

    if a.descriptor_set:
        ran = True
        if a.config is None:
            print('[FAIL] schema: missing config path', file=sys.stderr)
            return 1
        try:
            msg = parse_config(a.descriptor_set.read_bytes(), a.config.read_text(encoding='utf-8'))
            if a.binary_out:
                a.binary_out.write_bytes(msg.SerializeToString())
            print('[PASS] schema: parsed with supplied descriptor (runtime support NOT tested)')
        except ImportError:
            print('[UNKNOWN] schema: install Python protobuf on the HOST', file=sys.stderr)
            return 2
        except Exception as e:
            print(f'[FAIL] schema: {type(e).__name__}: {e}', file=sys.stderr)
            return 1

    if not ran:
        print('nothing to do: pass --descriptor-set and/or --check-resources/'
              '--deploy-name/--binary', file=sys.stderr)
        return 2

    print('[UNKNOWN] runtime: preflight cannot prove readiness/injection/stop/flush; '
          'require notify-fd byte, trace content, stats and logs')
    return rc


if __name__ == '__main__':
    raise SystemExit(main())
