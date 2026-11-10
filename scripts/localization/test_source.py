import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('audit', Path(__file__).with_name('validate-source.py'))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class SourceAuditTests(unittest.TestCase):
    def test_nested_interpolation_raw_multiline_and_comments(self):
        source = '''/* "ignored" /* nested */ */
let text = "outer \\(label("Inner")) suffix"
let raw = #"raw \\#(label("Nested"))"# // "ignored"
let multi = """
long text
"""
'''
        sites = audit.string_sites(source)
        literals = [literal for _, literal in sites]
        self.assertEqual(len(literals), 5)
        self.assertIn('"Inner"', literals)
        self.assertIn('"Nested"', literals)
        self.assertTrue(any('long text' in value for value in literals))
        with self.assertRaises(audit.InventoryError):
            audit.string_sites('let bad = "unterminated')

    def test_new_label_ax_and_diagnostic_sites_fail_even_for_previously_known_keys(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'Sources').mkdir()
            file = root / 'Sources/View.swift'
            initial = 'Text(localizer.chat("Send"))\n'
            file.write_text(initial)
            entries = [dict(prefix=p, literal=s, count=n, kind='localized', reason='R', keys={'ChatUI':['Send']})
                       for (p, s), n in audit.string_sites(initial).items()]
            inventory = dict(tables={'ChatUI':['Send']}, sources={'Sources/View.swift':entries},
                             reasons={'R':'Localized label'}, reservedKeys={})
            self.assertEqual(audit.validate(root, inventory), [])
            for addition in ['Text("New naked label")', '.accessibilityHelp("New AX help")',
                             'failure = "New canonical failure"', 'Text(localizer.chat("Send"))']:
                file.write_text(initial + addition)
                self.assertTrue(any('uncovered' in p for p in audit.validate(root, inventory)))
            file.write_text(initial.replace('localizer.chat(', 'verbatim: ('))
            self.assertTrue(audit.validate(root, inventory)) # Sink change is not grandfathered.
            file.write_text(initial)
            (root / 'Sources/New.swift').write_text('Text("New screen")')
            self.assertTrue(any('file added' in p for p in audit.validate(root, inventory)))
            (root / 'Sources/New.swift').unlink()
            inventory['tables']['ChatUI'].append('Orphan key')
            self.assertTrue(any('without audited' in p for p in audit.validate(root, inventory)))


if __name__ == '__main__':
    unittest.main()
