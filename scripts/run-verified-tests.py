#!/usr/bin/env python3
"""Run every discovered test once; isolate native hosts and require complete xUnit evidence."""
import argparse
import importlib.util
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("completion", Path(__file__).with_name("validate-test-results.py"))
completion = importlib.util.module_from_spec(spec)
spec.loader.exec_module(completion)


def execute(command: list[str], *, timeout: int, capture: bool = False) -> str:
    process = subprocess.Popen(command, stdout=subprocess.PIPE if capture else None,
                               text=True, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        raise RuntimeError(f"Test command exceeded {timeout}s; process group terminated")
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
    if process.returncode:
        raise RuntimeError(f"Test command failed with exit {process.returncode}")
    return output or ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin-path", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    discovery = execute(["swift", "test", "-Xswiftc", "-plugin-path", "-Xswiftc", args.plugin_path, "list"],
                        timeout=300, capture=True)
    (args.output / "discovered-tests.txt").write_text(discovery)
    tests = [line.strip() for line in discovery.splitlines() if line.strip()]
    if not tests or len(tests) != len(set(tests)):
        raise ValueError("Test discovery is empty or contains duplicates")
    groups = []
    # AppKit has process-global windows/responders/run-loop state. Unknown/new test
    # targets default to isolation; only these two non-UI targets are batched.
    for target in ("ChatCoreTests", "AgentRuntimeTests"):
        group = [test for test in tests if test.split(".")[0].split("/")[0] == target]
        if group:
            groups.append(group)
    groups += [[test] for test in tests if test.split(".")[0].split("/")[0]
               not in {"ChatCoreTests", "AgentRuntimeTests"}]
    combined = ET.Element("testsuites")
    for index, group in enumerate(groups):
        report = args.output / f"results-{index:03d}.xml"
        report.unlink(missing_ok=True)
        # SwiftPM discovery and Swift Testing's internal filter IDs use different
        # separators/suffixes. Match qualified components, then require exact xUnit IDs.
        patterns = [".*".join(re.escape(part) for part in re.split(r"[./]", test.split("(", 1)[0]))
                    for test in group]
        pattern = "(?:" + "|".join(patterns) + ")"
        print(f"Verified test group {index + 1}/{len(groups)}: {group[0]} ({len(group)} functions)", flush=True)
        execute(["swift", "test", "--skip-build", "--filter", pattern, "--xunit-output", str(report.resolve())],
                timeout=180)
        completion.validate("\n".join(group), report.read_text())
        combined.extend(ET.fromstring(report.read_text()))
    aggregate = ET.tostring(combined, encoding="unicode")
    (args.output / "test-results.xml").write_text(aggregate)
    count = completion.validate(discovery, aggregate)
    print(f"Verified full run: all {count} discovered test functions completed; no skips, failures, errors or retries", flush=True)
    return 0


if __name__ == "__main__":
    def cancelled(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, cancelled)
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, ET.ParseError) as error:
        print(f"Verified tests failed: {error}", file=sys.stderr)
        raise SystemExit(1)
