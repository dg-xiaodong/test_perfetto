#!/usr/bin/env python3
"""Explicit host-only dependency preparation, pinned tag v58.2; never downloads during tests.
Online: read official release asset digest. Offline: require --zip and independently verified --sha256.
Only perfetto.h/.cc are extracted, preventing zip path traversal; provenance retained.
"""
import argparse,hashlib,io,json,re,sys,urllib.request,zipfile
from pathlib import Path
TAG='v58.2'
API='https://api.github.com/repos/google/perfetto/releases/tags/'+TAG

def get(url):
    req=urllib.request.Request(url,headers={'User-Agent':'perfetto-latency-skill/0.1.1'})
    with urllib.request.urlopen(req,timeout=30) as r:
        data=r.read(32*1024*1024+1)
    if len(data)>32*1024*1024:raise ValueError('dependency exceeds 32 MiB bound')
    return data

def extract_sdk(raw,expected,dest):
    if not re.fullmatch(r'[0-9a-fA-F]{64}',expected):raise ValueError('SHA256 must contain 64 hex digits')
    actual=hashlib.sha256(raw).hexdigest()
    if actual!=expected.lower():raise ValueError('SDK archive SHA256 mismatch')
    z=zipfile.ZipFile(io.BytesIO(raw));found={}
    for name in ('perfetto.h','perfetto.cc'):
        matches=[i for i in z.infolist() if Path(i.filename).name==name and not i.is_dir()]
        if len(matches)!=1 or matches[0].file_size>32*1024*1024:raise ValueError('missing/ambiguous/oversized '+name)
        found[name]=z.read(matches[0])
    Path(dest).mkdir(parents=False,exist_ok=False)
    for name,data in found.items():(Path(dest)/name).write_bytes(data)
    return dict(archive_sha256=actual,files={n:hashlib.sha256(d).hexdigest() for n,d in found.items()})

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--dest',required=True,type=Path)
    p.add_argument('--zip',type=Path);p.add_argument('--sha256');a=p.parse_args()
    try:
        if a.zip:
            if not a.sha256:raise ValueError('offline archive requires verified --sha256')
            raw=a.zip.read_bytes();expected=a.sha256;source=str(a.zip)
        else:
            release=json.loads(get(API))
            if release.get('tag_name')!=TAG:raise ValueError('release tag mismatch')
            matches=[x for x in release.get('assets',[]) if x['name'] in ('perfetto-cpp-sdk-src.zip','sdk.zip')]
            if len(matches)!=1:raise ValueError('inspect official release; SDK asset name ambiguous/missing')
            asset=matches[0];source=asset['browser_download_url'];digest=asset.get('digest') or ''
            expected=a.sha256 or (digest[7:] if digest.startswith('sha256:') else '')
            if not expected:raise ValueError('release has no digest; supply independently verified --sha256')
            if not source.startswith('https://github.com/google/perfetto/releases/download/'+TAG+'/'):raise ValueError('unexpected asset origin')
            raw=get(source)
        meta=extract_sdk(raw,expected,a.dest);meta.update(version=TAG,source=source,release_api=API,
            note='Checksum verifies bytes against supplied/release metadata; not a substitute for source trust.')
        (a.dest/'SDK_PROVENANCE.json').write_text(json.dumps(meta,indent=2)+'\n')
        print(json.dumps(meta));return 0
    except Exception as e:print('SDK_BLOCKED:',e,file=sys.stderr);return 2
if __name__=='__main__':raise SystemExit(main())
