"""Uses an intentionally SMALL FIXTURE schema, not the official TraceConfig.
These tests prove strictness/import resolution only. See TEST_REPORT.md.
"""
import importlib.util
import pathlib
import unittest
try:
    from google.protobuf import descriptor_pb2
except ImportError:
    descriptor_pb2 = None
ROOT = pathlib.Path(__file__).resolve().parents[1]

@unittest.skipIf(descriptor_pb2 is None, 'Optional host dependency: protobuf')
class ValidatorTests(unittest.TestCase):
    def setUp(self):
        spec=importlib.util.spec_from_file_location('validator',ROOT/'scripts/validate_config.py')
        self.module=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.module)
        f=descriptor_pb2.FileDescriptorProto(name='fixture.proto',package='perfetto.protos',syntax='proto2')
        msg=f.message_type.add(name='TraceConfig')
        msg.field.add(name='duration_ms',number=1,type=13,label=1)
        enum=msg.enum_type.add(name='Counter')
        enum.value.add(name='MEMINFO_CACHED',number=0)
        msg.field.add(name='counter',number=2,type=14,type_name='.perfetto.protos.TraceConfig.Counter',label=1)
        self.fd=f
        self.desc=descriptor_pb2.FileDescriptorSet(file=[f]).SerializeToString()

    def test_valid_fixture(self):
        msg=self.module.parse_config(self.desc,'duration_ms: 1000 counter: MEMINFO_CACHED')
        self.assertEqual(msg.duration_ms,1000)

    def test_unknown_field(self):
        with self.assertRaises(Exception): self.module.parse_config(self.desc,'invented_field: 1')

    def test_unknown_enum(self):
        with self.assertRaises(Exception): self.module.parse_config(self.desc,'counter: MEMINFO_MEM_CACHED')

    def test_invalid_integer(self):
        with self.assertRaises(Exception): self.module.parse_config(self.desc,'duration_ms: -1')

    def test_missing_import(self):
        self.fd.dependency.append('not-included.proto')
        data=descriptor_pb2.FileDescriptorSet(file=[self.fd]).SerializeToString()
        with self.assertRaisesRegex(ValueError,'Unresolved'):self.module.parse_config(data,'')

    def test_empty_descriptor(self):
        with self.assertRaisesRegex(ValueError,'Empty'):self.module.parse_config(b'','duration_ms: 1')

if __name__ == '__main__': unittest.main()
