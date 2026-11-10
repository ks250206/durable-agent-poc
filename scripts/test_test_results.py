import importlib.util
from pathlib import Path
import unittest
import re
import tempfile
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("completion", Path(__file__).with_name("validate-test-results.py"))
completion = importlib.util.module_from_spec(spec)
spec.loader.exec_module(completion)
runner_spec = importlib.util.spec_from_file_location("runner", Path(__file__).with_name("run-verified-tests.py"))
runner = importlib.util.module_from_spec(runner_spec)
runner_spec.loader.exec_module(runner)

DISCOVERY = "ChatUITests.NativeUITests/TrajectoryTests/jump()\nChatCoreTests/send()\n"
REPORT = '''<testsuites><testsuite tests="2" failures="0" errors="0" skipped="0">
<testcase classname="ChatUITests.NativeUITests.TrajectoryTests" name="jump()"/>
<testcase classname="ChatCoreTests" name="send()"/></testsuite></testsuites>'''


class CompletionTests(unittest.TestCase):
    def test_complete_report(self):
        self.assertEqual(completion.validate(DISCOVERY, REPORT), 2)
        self.assertEqual(completion.validate(DISCOVERY.replace("ChatCoreTests/send", "ChatCoreTests.send"), REPORT), 2)

    def test_unexpected_functions_are_not_silently_repeated(self):
        with self.assertRaisesRegex(ValueError, "unexpected functions"):
            completion.validate(DISCOVERY, REPORT.replace("</testsuite>",
                '<testcase classname="ChatCoreTests" name="sendAgain()"/></testsuite>'))

    def test_missing_target_or_early_clean_exit_is_not_success(self):
        for report in (REPORT.replace('<testcase classname="ChatUITests.NativeUITests.TrajectoryTests" name="jump()"/>', ''),
                       '<testsuites><testsuite tests="0"/></testsuites>'):
            with self.subTest(report=report), self.assertRaisesRegex(ValueError, "did not complete"):
                completion.validate(DISCOVERY, report)

    def test_skip_failure_and_error_are_rejected(self):
        for tag in ("skipped", "failure", "error"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                completion.validate(DISCOVERY, REPORT.replace('name="send()"/>', f'name="send()"><{tag}/></testcase>'))
        with self.assertRaises(ValueError):
            completion.validate(DISCOVERY, REPORT.replace('skipped="0"', 'skipped="1"'))

    def test_empty_discovery_and_malformed_reports_fail(self):
        for discovery, report in (("", REPORT), ("unexpected log text", REPORT), (DISCOVERY, "<testsuites>")):
            with self.subTest(discovery=discovery, report=report), self.assertRaises(ValueError):
                completion.validate(discovery, report)


class ReportSelectionTests(unittest.TestCase):
    def test_primary_and_swift_testing_only_layouts(self):
        with tempfile.TemporaryDirectory() as temp:
            primary = Path(temp) / "results-000.xml"
            for path in runner.report_paths(primary):
                with self.subTest(path=path):
                    runner.clear_reports(primary)
                    path.write_text(REPORT)
                    self.assertEqual(completion.validate(DISCOVERY, runner.read_reports(primary)), 2)

    def test_both_reports_are_combined_and_both_are_deleted_before_a_run(self):
        with tempfile.TemporaryDirectory() as temp:
            primary = Path(temp) / "results-000.xml"
            primary.write_text('<testsuites><testsuite><testcase classname="LegacyTests" name="legacy()"/></testsuite></testsuites>')
            runner.report_paths(primary)[1].write_text(REPORT)
            self.assertEqual(completion.validate(DISCOVERY + 'LegacyTests.legacy()\n', runner.read_reports(primary)), 3)
            runner.clear_reports(primary)
            self.assertTrue(all(not path.exists() for path in runner.report_paths(primary)))
            with self.assertRaises(FileNotFoundError):
                runner.read_reports(primary)

    def test_bad_primary_cannot_be_hidden_by_good_swift_testing_report(self):
        with tempfile.TemporaryDirectory() as temp:
            primary = Path(temp) / "results-000.xml"
            runner.report_paths(primary)[1].write_text(REPORT)
            for bad in ('<testsuites errors="1"/>', '<testsuites><testsuite><skipped/></testsuite></testsuites>'):
                primary.write_text(bad)
                with self.assertRaises(ValueError):
                    runner.read_reports(primary)
            primary.write_text('<testsuites>')
            with self.assertRaises(ET.ParseError):
                runner.read_reports(primary)

    def test_filter_matches_exact_method_name_in_both_id_spellings(self):
        pattern = runner.filter_pattern(['ChatUITests.NativeUITests/TrajectoryTests/jump()'])
        for identity in ('ChatUITests.NativeUITests/TrajectoryTests/jump()',
                         'ChatUITests/NativeUITests/TrajectoryTests/jump'):
            self.assertIsNotNone(re.search(pattern, identity))
        self.assertIsNone(re.search(pattern, 'ChatUITests/NativeUITests/TrajectoryTests/jumpToUser()'))


if __name__ == "__main__":
    unittest.main()
