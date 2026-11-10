import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("completion", Path(__file__).with_name("validate-test-results.py"))
completion = importlib.util.module_from_spec(spec)
spec.loader.exec_module(completion)

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


if __name__ == "__main__":
    unittest.main()
