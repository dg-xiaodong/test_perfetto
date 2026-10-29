#!/usr/bin/env python3
"""Strict recipe-subset policy checks; optional REAL protobuf schema validation.
Not a full TraceConfig parser. Unknown recipe fields are rejected, not silently
accepted. --descriptor needs a JSON sidecar binding SHA256 and collector_version.
"""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
TOKEN=re.compile(r'\s+|\#[^\n]*|//[^\n]*|"(?:[^"\\]|\\.)*"|[A-Za-z_][A-Za-z_0-9]*|-?\d+|[{}:]')
# (type, repeated); nested maps deliberately cover only the package recipes.
TE={'disabled_categories':('str',True),'enabled_categories':('str',True)}
FT={'buffer_size_kb':('uint',False),'drain_period_ms':('uint',False),'ftrace_events':('str',True)}
CFG={'name':('str',False),'target_buffer':('uint',False),'track_event_config':(TE,False),
     'ftrace_config':(FT,False),
     'process_stats_config':({'scan_all_processes_on_start':('bool',False),'proc_stats_poll_ms':('uint',False)},False)}
SCHEMA={'duration_ms':('uint',False),'buffers':({'size_kb':('uint',False),'fill_policy':('fill',False)},True),
        'data_sources':({'config':(CFG,False)},True)}


def parse_subset(text):
    tokens=[];end=0
    for m in TOKEN.finditer(text):
        if text[end:m.start()].strip(): raise ValueError('unsupported syntax near '+text[end:m.start()][:50])
        t=m.group();end=m.end()
        if not t.isspace() and not t.startswith(('#','//')):tokens.append(t)
    if text[end:].strip(): raise ValueError('unsupported trailing syntax')
    pos=0
    def node(spec,closing=False):
        nonlocal pos
        out={}
        while pos<len(tokens) and tokens[pos]!='}':
            key=tokens[pos];pos+=1
            if key not in spec: raise ValueError('unknown recipe field: '+key)
            kind,repeated=spec[key]
            if key in out and not repeated: raise ValueError('duplicate field: '+key)
            if pos<len(tokens) and tokens[pos]==':':pos+=1
            if isinstance(kind,dict):
                if pos>=len(tokens) or tokens[pos]!='{':raise ValueError('expected message for '+key)
                pos+=1;val=node(kind,True)
            else:
                if pos>=len(tokens):raise ValueError('missing scalar '+key)
                val=tokens[pos];pos+=1
                if kind=='str':
                    if not val.startswith('"'):raise ValueError('expected string '+key)
                    val=json.loads(val)
                elif kind=='uint':
                    if not re.fullmatch(r'\d+',val):raise ValueError('expected unsigned integer '+key)
                    val=int(val)
                elif kind=='bool':
                    if val not in ('true','false'):raise ValueError('expected boolean '+key)
                    val=val=='true'
                elif kind=='clock' and val not in ('PERF_CLOCK_MONOTONIC','PERF_CLOCK_BOOTTIME'):
                    raise ValueError('unsupported clock enum '+val)
                elif kind=='fill' and val not in ('RING_BUFFER','DISCARD'):raise ValueError('invalid fill enum')
            if repeated:out.setdefault(key,[]).append(val)
            else:out[key]=val
        if closing:
            if pos>=len(tokens) or tokens[pos]!='}':raise ValueError('unclosed message')
            pos+=1
        return out
    result=node(SCHEMA)
    if pos!=len(tokens):raise ValueError('unexpected closing brace')
    return result


def check_policy(text):
    c=parse_subset(text)
    if not 1000<=c.get('duration_ms',0)<=120000:raise ValueError('bounded duration required (1000..120000ms)')
    bs=c.get('buffers',[])
    if len(bs)!=1 or not 1024<=bs[0].get('size_kb',0)<=65536:raise ValueError('one bounded buffer required')
    if bs[0].get('fill_policy')!='DISCARD':raise ValueError('first-version recipe uses DISCARD; loss still must be checked')
    ds=[d.get('config',{}) for d in c.get('data_sources',[])]
    names=[d.get('name') for d in ds]
    if len(names)!=len(set(names)):raise ValueError('duplicate data source')
    if 'track_event' not in names or set(names)-{'track_event','linux.ftrace','linux.process_stats'}:raise ValueError('TrackEvent recipe only')
    te=next(d for d in ds if d['name']=='track_event').get('track_event_config',{})
    en=te.get('enabled_categories',[])
    if te.get('disabled_categories')!=['*'] or len(en)!=1 or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_.-]{0,63}',en[0]):raise ValueError('one exact enabled category required')
    if 'linux.ftrace' in names:
        if 'linux.process_stats' not in names:raise ValueError('joint recipe needs process identity')
        ft=next(d for d in ds if d['name']=='linux.ftrace').get('ftrace_config',{})
        if set(ft.get('ftrace_events',[]))!={'sched/sched_switch','sched/sched_waking'}:raise ValueError('unexpected/missing sched event')
        if not 1<=ft.get('buffer_size_kb',0)<=4096:raise ValueError('ftrace buffer bound')
    return c


def validate_schema(text,descriptor,metadata,collector_version):
    from google.protobuf import descriptor_pb2,descriptor_pool,message_factory,text_format
    raw=descriptor.read_bytes();meta=json.loads(metadata.read_text())
    if meta.get('sha256')!=hashlib.sha256(raw).hexdigest():raise ValueError('descriptor hash mismatch')
    if not collector_version or meta.get('collector_version')!=collector_version:raise ValueError('collector/descriptor version mismatch')
    fs=descriptor_pb2.FileDescriptorSet();fs.ParseFromString(raw)
    pool=descriptor_pool.DescriptorPool();pending=list(fs.file)
    while pending:
        rest=[];done=0
        for f in pending:
            try:pool.Add(f);done+=1
            except Exception:rest.append(f)
        if not done:raise ValueError('unresolved descriptor imports')
        pending=rest
    cls=message_factory.GetMessageClass(pool.FindMessageTypeByName('perfetto.protos.TraceConfig'))
    msg=cls();text_format.Parse(text,msg,allow_unknown_field=False)
    return msg


def check_resources(root):
    required=json.loads((root/'RESOURCE_LIST.json').read_text())
    missing=[name for name in required if not (root/name).is_file()]
    if missing:raise ValueError('missing resources: '+', '.join(missing))
    return len(required)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('config',nargs='?',type=Path)
    p.add_argument('--check-resources',action='store_true')
    p.add_argument('--root',type=Path,default=ROOT)
    p.add_argument('--descriptor',type=Path)
    p.add_argument('--descriptor-metadata',type=Path)
    p.add_argument('--collector-version')
    p.add_argument('--binary-out',type=Path)
    a=p.parse_args()
    try:
        if a.check_resources:print('RESOURCES_PASS count='+str(check_resources(a.root)))
        if a.config:
            text=a.config.read_text();check_policy(text);print('POLICY_PASS (recipe checks, NOT official schema)')
            if a.descriptor:
                if not a.descriptor_metadata:raise ValueError('--descriptor-metadata required')
                msg=validate_schema(text,a.descriptor,a.descriptor_metadata,a.collector_version)
                if a.binary_out:
                    with a.binary_out.open('xb') as f:f.write(msg.SerializeToString())
                print('SCHEMA_PASS collector='+a.collector_version+'; metadata provenance must be trusted')
            else:
                if a.binary_out:raise ValueError('--binary-out needs matching official descriptor')
                print('SCHEMA_UNKNOWN (no matching descriptor executed)')
        if not (a.config or a.check_resources):p.error('config or --check-resources required')
    except Exception as e:
        print('FAIL: '+str(e),file=sys.stderr);return 2
    return 0
if __name__=='__main__':raise SystemExit(main())
