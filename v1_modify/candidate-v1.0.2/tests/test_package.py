import pathlib
import re
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]

class PackageTests(unittest.TestCase):
    def test_frontmatter(self):
        text=(ROOT/'SKILL.md').read_text()
        self.assertTrue(text.startswith('---\nname: perfetto-memory-debugging\ndescription: Use when'))
        self.assertLess(len(text.split('---')[1]),1024)

    def test_local_markdown_links_exist(self):
        missing=[]
        for p in ROOT.rglob('*.md'):
            for link in re.findall(r'\]\(([^)]+)\)',p.read_text()):
                if '://' in link or link.startswith('#'):continue
                target=link.split('#',1)[0]
                if target and not (p.parent/target).exists():missing.append(f'{p.relative_to(ROOT)}: {target}')
        self.assertEqual(missing,[])

    def test_eleven_user_sources(self):
        text=(ROOT/'references/sources.md').read_text()
        for n in range(1,12): self.assertIn(f'| S{n:02d} |',text)

    def test_ten_config_assets(self):
        self.assertEqual(len(list((ROOT/'configs').glob('*.pbtxt'))),10)

    def test_no_device_success_claim_in_report(self):
        text=(ROOT/'TEST_REPORT.md').read_text()
        self.assertIn('X5 / Android',text)
        self.assertIn('未执行',text)

if __name__ == '__main__': unittest.main()
