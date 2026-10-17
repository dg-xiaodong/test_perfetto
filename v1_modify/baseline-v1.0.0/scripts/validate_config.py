#!/usr/bin/env python3
"""Validate pbtxt using a descriptor set from YOUR collector's Perfetto source.
Host dependency: Python protobuf. Schema success does not verify runtime support.
"""
from __future__ import annotations
import argparse
import pathlib
import sys

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
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('config', type=pathlib.Path)
    p.add_argument('--descriptor-set', type=pathlib.Path, required=True)
    p.add_argument('--binary-out', type=pathlib.Path)
    a = p.parse_args()
    try:
        msg = parse_config(a.descriptor_set.read_bytes(), a.config.read_text(encoding='utf-8'))
        if a.binary_out: a.binary_out.write_bytes(msg.SerializeToString())
    except ImportError:
        print('ERROR: install Python protobuf on the HOST.', file=sys.stderr)
        return 2
    except Exception as e:
        print(f'INVALID: {type(e).__name__}: {e}', file=sys.stderr)
        return 1
    print('SCHEMA OK using supplied descriptor; runtime support has NOT been tested.')
    return 0

if __name__ == '__main__': raise SystemExit(main())
