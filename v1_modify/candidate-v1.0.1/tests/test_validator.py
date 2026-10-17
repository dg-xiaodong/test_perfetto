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


class PreflightTests(unittest.TestCase):
    """Static preflight: resources, deploy-name, ELF PT_INTERP. No protobuf needed."""
    @classmethod
    def setUpClass(cls):
        import importlib.util
        spec=importlib.util.spec_from_file_location('validator',ROOT/'scripts/validate_config.py')
        cls.m=importlib.util.module_from_spec(spec); spec.loader.exec_module(cls.m)

    def _elf(self, ptype, path):
        import struct
        ident=b'\x7fELF'+bytes([2,1,1,0])+b'\x00'*8
        hdr=bytearray(64); hdr[:16]=ident
        struct.pack_into('<Q',hdr,0x20,64)      # e_phoff
        struct.pack_into('<H',hdr,0x36,56)      # e_phentsize
        struct.pack_into('<H',hdr,0x38,1)       # e_phnum
        ph=bytearray(56); struct.pack_into('<I',ph,0,ptype)  # p_type
        path.write_bytes(bytes(hdr)+bytes(ph)); return path

    def test_resources_complete(self):
        self.assertEqual(self.m.check_resources(ROOT)[0],'PASS')

    def test_resources_missing(self):
        import tempfile, shutil
        with tempfile.TemporaryDirectory() as d:
            d=pathlib.Path(d); shutil.copy(ROOT/'SKILL.md',d/'SKILL.md')
            st,detail=self.m.check_resources(d)
        self.assertEqual(st,'FAIL'); self.assertIn('references/02-native.md',detail)

    def test_deploy_name_match(self):
        cfg='heapprofd_config {\n  process_cmdline: "memprobe"\n}\n'
        st,_=self.m.check_deploy_name(cfg,'/data/memprobe')
        self.assertEqual(st,'PASS')

    def test_deploy_name_mismatch(self):
        st,detail=self.m.check_deploy_name('linear {\n  process_cmdline: "memprobe"\n}\n','memprobe_arm64')
        self.assertEqual(st,'FAIL'); self.assertIn('BLOCKING_INIT',detail)

    def test_deploy_name_not_heapprofd(self):
        st,_=self.m.check_deploy_name('duration_ms: 1000','memprobe')
        self.assertEqual(st,'UNKNOWN')

    def test_binary_dynamic(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            p=self._elf(3,pathlib.Path(d)/'dyn'); st,_=self.m.check_binary(p)
        self.assertEqual(st,'PASS')

    def test_binary_static(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            p=self._elf(1,pathlib.Path(d)/'st'); st,_=self.m.check_binary(p)
        self.assertEqual(st,'FAIL')

    def test_binary_not_elf(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'x'; p.write_bytes(b'hello')
            st,_=self.m.check_binary(p)
        self.assertEqual(st,'UNKNOWN')

    def test_main_exit_codes(self):
        import sys, unittest.mock as mock, tempfile
        cfg=ROOT/'configs/native.pbtxt'
        with mock.patch.object(sys,'argv',['v','--check-resources']):
            self.assertEqual(self.m.main(),0)
        with mock.patch.object(sys,'argv',['v',str(cfg),'--deploy-name','definitely-not-matching']):
            self.assertEqual(self.m.main(),1)
        with mock.patch.object(sys,'argv',['v']):
            self.assertEqual(self.m.main(),2)

if __name__ == '__main__': unittest.main()
