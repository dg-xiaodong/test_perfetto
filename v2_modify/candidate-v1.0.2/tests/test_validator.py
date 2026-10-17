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
    """Static preflight: resources, deploy-name, ELF PT_INTERP. No protobuf needed.

    Exit convention: 0=PASS, 1=FAIL, 2=UNKNOWN/incomplete.
    """
    @classmethod
    def setUpClass(cls):
        import importlib.util
        spec=importlib.util.spec_from_file_location('validator',ROOT/'scripts/validate_config.py')
        cls.m=importlib.util.module_from_spec(spec); spec.loader.exec_module(cls.m)

    def _elf(self, ptype, path, phnum=1, phoff=64, truncate=False):
        import struct
        ident=b'\x7fELF'+bytes([2,1,1,0])+b'\x00'*8
        hdr=bytearray(64); hdr[:16]=ident
        struct.pack_into('<Q',hdr,0x20,phoff)
        struct.pack_into('<H',hdr,0x36,56)
        struct.pack_into('<H',hdr,0x38,phnum)
        ph=bytearray(56); struct.pack_into('<I',ph,0,ptype)
        data=bytes(hdr)+bytes(ph)
        if truncate: data=data[:60]
        path.write_bytes(data); return path

    # ---- resources ----
    def test_resources_complete(self):
        self.assertEqual(self.m.check_resources(ROOT)[0],'PASS')

    def test_new_v102_resources_required(self):
        import tempfile, shutil
        new_resources = [
            'scripts/linux_session_lib.sh',
            'scripts/linux_trace_session.sh',
            'scripts/linux_heapprofd_session.sh',
            'scripts/host_pull.sh',
            'sql/11-cpu-time-buckets.sql',
            'sql/12-cpu-spike-episodes.sql',
        ]
        for rel in new_resources:
            with tempfile.TemporaryDirectory() as d:
                root = pathlib.Path(d) / 'pkg'
                shutil.copytree(ROOT, root,
                                ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
                (root / rel).unlink()
                st, detail = self.m.check_resources(root)
            self.assertNotEqual(st, 'PASS', f'{rel} removed but check passed')
            self.assertIn(rel, detail)

    def test_resources_missing(self):
        import tempfile, shutil
        with tempfile.TemporaryDirectory() as d:
            d=pathlib.Path(d); shutil.copy(ROOT/'SKILL.md',d/'SKILL.md')
            st,detail=self.m.check_resources(d)
        self.assertEqual(st,'UNKNOWN'); self.assertIn('references/02-native.md',detail)

    def test_resources_empty_config_is_not_ok(self):
        import tempfile, shutil
        with tempfile.TemporaryDirectory() as d:
            d=pathlib.Path(d)
            for rel in self.m.REQUIRED:
                src=ROOT/rel
                if not src.is_file(): continue
                (d/rel).parent.mkdir(parents=True,exist_ok=True); shutil.copy(src,d/rel)
            (d/'configs').mkdir(exist_ok=True)
            for i in range(10):
                (d/'configs'/f'c{i}.pbtxt').write_text('',encoding='utf-8')  # empty -> unreadable content
            st,detail=self.m.check_resources(d)
        self.assertEqual(st,'UNKNOWN'); self.assertIn('empty/unreadable',detail)

    # ---- deploy name ----
    def test_deploy_name_match_same_line(self):
        st,_=self.m.check_deploy_name('heapprofd_config { process_cmdline: "memprobe" }','/data/memprobe')
        self.assertEqual(st,'PASS')

    def test_deploy_name_match_multiple_targets(self):
        cfg='heapprofd_config {\n process_cmdline: "a"\n process_cmdline: "memprobe"\n}\n'
        st,detail=self.m.check_deploy_name(cfg,'memprobe')
        self.assertEqual(st,'PASS'); self.assertIn('memprobe',detail)

    def test_deploy_name_normalizes_paths(self):
        st,_=self.m.check_deploy_name('heapprofd_config { process_cmdline: "/data/memprobe" }','./memprobe')
        self.assertEqual(st,'PASS')

    def test_deploy_name_mismatch(self):
        st,detail=self.m.check_deploy_name('heapprofd_config { process_cmdline: "memprobe" }','memprobe_arm64')
        self.assertEqual(st,'FAIL'); self.assertIn('BLOCKING_INIT',detail)

    def test_deploy_name_not_heapprofd(self):
        self.assertEqual(self.m.check_deploy_name('duration_ms: 1000','memprobe')[0],'UNKNOWN')

    def test_deploy_name_glob_is_unknown(self):
        st,detail=self.m.check_deploy_name('heapprofd_config { process_cmdline: "memprobe*" }','memprobe')
        self.assertEqual(st,'UNKNOWN'); self.assertIn('glob',detail)

    # ---- binary ----
    def test_binary_dynamic(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            st,_=self.m.check_binary(self._elf(3,pathlib.Path(d)/'dyn'))
        self.assertEqual(st,'PASS')

    def test_binary_static(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            st,_=self.m.check_binary(self._elf(1,pathlib.Path(d)/'st'))
        self.assertEqual(st,'FAIL')

    def test_binary_not_elf(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'x'; p.write_bytes(b'hello')
            self.assertEqual(self.m.check_binary(p)[0],'UNKNOWN')

    def test_binary_truncated_elf_is_unknown_not_crash(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            p=self._elf(3,pathlib.Path(d)/'t',phnum=10,phoff=64,truncate=True)
            self.assertEqual(self.m.check_binary(p)[0],'UNKNOWN')

    def test_binary_no_phdr_is_unknown(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            p=self._elf(3,pathlib.Path(d)/'n',phnum=0)
            self.assertEqual(self.m.check_binary(p)[0],'UNKNOWN')

    # ---- exit codes ----
    def test_main_exit_codes(self):
        import sys, unittest.mock as mock
        cfg=ROOT/'configs/native.pbtxt'
        with mock.patch.object(sys,'argv',['v','--check-resources']):
            self.assertEqual(self.m.main(),0)
        with mock.patch.object(sys,'argv',['v',str(cfg),'--deploy-name','definitely-not-matching']):
            self.assertEqual(self.m.main(),1)
        with mock.patch.object(sys,'argv',['v']):
            self.assertEqual(self.m.main(),2)

    def test_comment_is_not_a_field(self):
        # 复现：注释里写 memprobe、有效字段是 other_app → 必须 FAIL，不能 PASS
        cfg = '# process_cmdline: "memprobe"\nheapprofd_config { process_cmdline: "other_app" }\n'
        st, detail = self.m.check_deploy_name(cfg, '/data/memprobe')
        self.assertEqual(st, 'FAIL')
        self.assertIn('other_app', detail)

    def test_similar_field_name_not_matched(self):
        st, _ = self.m.check_deploy_name('heapprofd_config { not_process_cmdline: "memprobe" }', 'memprobe')
        self.assertEqual(st, 'UNKNOWN')

    def test_cmdline_inside_string_ignored(self):
        st, _ = self.m.check_deploy_name('heapprofd_config { heap_name: "process_cmdline: memprobe" }', 'memprobe')
        self.assertEqual(st, 'UNKNOWN')

    def test_unbalanced_braces_unknown(self):
        st, detail = self.m.check_deploy_name('heapprofd_config { process_cmdline: "memprobe"', 'memprobe')
        self.assertEqual(st, 'UNKNOWN'); self.assertIn('unbalanced', detail)

    def test_cmdline_outside_heapprofd_config_unknown(self):
        st, detail = self.m.check_deploy_name('process_cmdline: "memprobe"', 'memprobe')
        self.assertEqual(st, 'UNKNOWN'); self.assertIn('outside heapprofd_config', detail)

    def test_at_suffix_normalized(self):
        # NormalizeCmdLine: 截断首个 '@'，再取 basename
        cfg = 'heapprofd_config { process_cmdline: "/system/bin/app_process@/system/bin/app_process64" }'
        self.assertEqual(self.m.check_deploy_name(cfg, 'app_process')[0], 'PASS')
        self.assertEqual(self.m.check_deploy_name(cfg, '/system/bin/app_process@x')[0], 'PASS')

    def test_nested_block_scope_is_honored(self):
        cfg = 'data_sources { config { heapprofd_config { process_cmdline: "memprobe" } } }'
        self.assertEqual(self.m.check_deploy_name(cfg, './memprobe')[0], 'PASS')

    def test_main_unknown_is_exit_2(self):
        import sys, tempfile, unittest.mock as mock
        with tempfile.TemporaryDirectory() as d:
            cfg=pathlib.Path(d)/'c.pbtxt'; cfg.write_text('duration_ms: 1',encoding='utf-8')
            with mock.patch.object(sys,'argv',['v',str(cfg),'--deploy-name','memprobe']):
                self.assertEqual(self.m.main(),2)


if __name__ == '__main__': unittest.main()
