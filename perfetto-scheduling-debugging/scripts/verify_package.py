#!/usr/bin/env python3
"""Verify package manifest hashes and required resource paths, without network."""
import hashlib,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def main():
    try:
        m=json.loads((ROOT/'MANIFEST.json').read_text());bad=[]
        for name,expected in m['files'].items():
            p=ROOT/name
            if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=expected:bad.append(name)
        from validate_config import check_resources
        n=check_resources(ROOT)
        if bad:raise ValueError('hash mismatch/missing: '+', '.join(bad))
        print(f"PACKAGE_PASS version={m['version']} status={m['status']} hashes={len(m['files'])} resources={n}")
        return 0
    except (OSError,KeyError,ValueError) as e:print('PACKAGE_FAIL '+str(e),file=sys.stderr);return 2
if __name__=='__main__':raise SystemExit(main())
