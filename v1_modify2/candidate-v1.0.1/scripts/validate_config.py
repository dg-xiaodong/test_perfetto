#!/usr/bin/env python3
"""Validate pbtxt using a descriptor set from YOUR collector's Perfetto source.

Preflight checks (no descriptor needed):
  --check-resources   required references/sql/scripts/tests exist AND are readable
  --deploy-name NAME  launched basename is among config's process_cmdline targets
  --binary PATH       ELF has PT_INTERP (dynamic preload target needs dynamic linking)

Exit convention (static checks only):
  0  every requested static check PASS
  1  at least one requested static check FAIL
  2  a requested static check could not be completed (UNKNOWN) or host dep missing

Runtime readiness/injection/stop/flush are NOT proven by preflight; the tool prints a
[NOTE] line for that and never turns it into a static FAIL.
"""
from __future__ import annotations
import argparse
import pathlib
import re
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
CMD_RE = re.compile(r'process_cmdline\s*[:=]\s*(?:"([^"]*)"|\'([^\']*)\'|([^\s,;}\)]+))')


def _readable_nonempty(path: pathlib.Path) -> bool:
    try:
        with open(path, 'rb') as f:
            return len(f.read(512)) > 0
    except OSError:
        return False


def check_resources(root: pathlib.Path):
    """All required files readable & non-empty; every config readable & non-empty."""
    bad = []
    for rel in REQUIRED:
        p = root / rel
        if not p.is_file() or not _readable_nonempty(p):
            bad.append(rel)
    cfgs = sorted((root / 'configs').glob('*.pbtxt')) if (root / 'configs').is_dir() else []
    if len(cfgs) < MIN_CONFIGS:
        bad.append(f'configs/*.pbtxt (<{MIN_CONFIGS})')
    for c in cfgs:
        if not _readable_nonempty(c):
            bad.append(f'configs/{c.name} (empty/unreadable)')
    if bad:
        return 'UNKNOWN', 'cannot complete resource check: ' + ', '.join(bad)
    return 'PASS', f'{len(REQUIRED)} required files + {len(cfgs)} configs readable'


def read_targets(config_text: str):
    """Extract process_cmdline values anywhere in the text (same line/minified ok)."""
    out = []
    for m in CMD_RE.finditer(config_text):
        val = next((g for g in m.groups() if g is not None), '')
        if val:
            out.append(val.strip())
    return out


def normalize_target(name: str):
    """Return basename for a target name, or None if it contains a glob (unsupported)."""
    n = name.strip().strip('"').strip("'")
    if any(ch in n for ch in '*?['):
        return None
    return pathlib.PurePath(n).name


def check_deploy_name(config_text: str, deploy_name: str):
    """heapprofd matches argv[0] basename; compare against every configured target."""
    targets = read_targets(config_text)
    if not targets:
        return 'UNKNOWN', 'config has no process_cmdline (not a heapprofd target config)'
    got = pathlib.PurePath(deploy_name.strip()).name
    if any(ch in got for ch in '*?['):
        return 'UNKNOWN', f'launched name {deploy_name!r} contains a glob; cannot verify statically'
    normalized = []
    for t in targets:
        nt = normalize_target(t)
        if nt is None:
            return 'UNKNOWN', f'target {t!r} contains a glob; heapprofd matches exact basename'
        normalized.append(nt)
    if got in normalized:
        return 'PASS', f'launched basename={got!r} matches target(s) {targets!r}'
    return 'FAIL', (f"launched basename={got!r} not in config targets {targets!r}; "
                    'heapprofd will not match this process and BLOCKING_INIT may hang')


def elf_has_interp(path: pathlib.Path):
    """True/False for PT_INTERP; None (UNKNOWN) for non-ELF or truncated/corrupt ELF."""
    try:
        with open(path, 'rb') as f:
            ident = f.read(16)
            if len(ident) < 16 or ident[:4] != b'\x7fELF':
                return None
            cls, data = ident[4], ident[5]
            if data not in (1, 2) or cls not in (1, 2):
                return None
            endian = '<' if data == 1 else '>'
            if cls == 2:
                f.seek(0x20); phoff = struct.unpack(endian + 'Q', f.read(8))[0]
                f.seek(0x36); phentsize = struct.unpack(endian + 'H', f.read(2))[0]
                f.seek(0x38); phnum = struct.unpack(endian + 'H', f.read(2))[0]
            else:
                f.seek(0x1C); phoff = struct.unpack(endian + 'I', f.read(4))[0]
                f.seek(0x2A); phentsize = struct.unpack(endian + 'H', f.read(2))[0]
                f.seek(0x2C); phnum = struct.unpack(endian + 'H', f.read(2))[0]
            if phnum == 0 or phentsize < 8 or phoff <= 0:
                return None
            size = path.stat().st_size
            if phoff + phnum * phentsize > size:
                return None
            for i in range(phnum):
                f.seek(phoff + i * phentsize)
                raw = f.read(4)
                if len(raw) < 4:
                    return None
                if struct.unpack(endian + 'I', raw)[0] == 3:  # PT_INTERP
                    return True
            return False
    except (OSError, struct.error, ValueError):
        return None


def check_binary(path: pathlib.Path):
    has = elf_has_interp(path)
    if has is None:
        return 'UNKNOWN', f'{path} is not a readable/complete ELF; cannot judge dynamic linking'
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
    ran = False
    fail = False
    unknown = False

    if a.check_resources:
        ran = True
        st, detail = check_resources(root)
        print(f'[{st}] resources: {detail}')
        fail |= st == 'FAIL'
        unknown |= st == 'UNKNOWN'

    if a.deploy_name:
        ran = True
        if a.config is None:
            print('[UNKNOWN] deploy-name: missing config path (cannot complete check)')
            unknown = True
        else:
            st, detail = check_deploy_name(a.config.read_text(encoding='utf-8', errors='replace'),
                                           a.deploy_name)
            print(f'[{st}] deploy-name: {detail}')
            fail |= st == 'FAIL'
            unknown |= st == 'UNKNOWN'

    if a.binary:
        ran = True
        st, detail = check_binary(a.binary)
        print(f'[{st}] binary: {detail}')
        fail |= st == 'FAIL'
        unknown |= st == 'UNKNOWN'

    if a.descriptor_set:
        ran = True
        if a.config is None:
            print('[UNKNOWN] schema: missing config path (cannot complete check)')
            unknown = True
        else:
            try:
                msg = parse_config(a.descriptor_set.read_bytes(),
                                   a.config.read_text(encoding='utf-8'))
                if a.binary_out:
                    a.binary_out.write_bytes(msg.SerializeToString())
                print('[PASS] schema: parsed with supplied descriptor (runtime support NOT tested)')
            except ImportError:
                print('[UNKNOWN] schema: install Python protobuf on the HOST')
                unknown = True
            except Exception as e:
                print(f'[FAIL] schema: {type(e).__name__}: {e}')
                fail = True

    if not ran:
        print('[UNKNOWN] nothing to do: pass --descriptor-set and/or '
              '--check-resources/--deploy-name/--binary')
        return 2

    print('[NOTE] runtime not verified by preflight: pass/fail above covers only '
          'static premises; readiness/injection/stop/flush still need runtime evidence')
    if fail:
        return 1
    if unknown:
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
