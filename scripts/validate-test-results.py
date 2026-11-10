#!/usr/bin/env python3
"""Fail closed if SwiftPM exits successfully without completing discovered tests."""
import argparse
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


def assert_success(root: ET.Element) -> None:
    if root.tag != "testsuites":
        raise ValueError("Missing xUnit testsuites report")
    for node in root.iter():
        if node.tag in {"failure", "error", "skipped"}:
            raise ValueError(f"xUnit contains {node.tag}")
        for attribute in ("failures", "errors", "skipped"):
            if int(node.get(attribute, "0")):
                raise ValueError(f"xUnit reports {attribute}")


def validate(discovery: str, report: str) -> int:
    expected = set()
    for line in discovery.splitlines():
        line = line.strip()
        if not line:
            continue
        if not re.fullmatch(r"[A-Za-z_][\w.]*(?:/[\w/]+)?\(.*\)", line):
            raise ValueError(f"Unexpected test discovery entry: {line}")
        expected.add(line.replace("/", "."))
    if not expected:
        raise ValueError("No tests discovered")
    try:
        root = ET.fromstring(report)
    except ET.ParseError as error:
        raise ValueError(f"Incomplete or malformed xUnit report: {error}") from error
    assert_success(root)
    completed = set()
    cases = root.findall(".//testcase")
    for case in cases:
        # Swift Testing reports parameterized cases under their declared function name.
        name = f"{case.get('classname', '')}.{case.get('name', '')}".replace("/", ".")
        completed.add(name)
    missing = expected - completed
    if missing:
        raise ValueError("Discovered tests did not complete:\n" + "\n".join(sorted(missing)))
    unexpected = completed - expected
    if unexpected:
        raise ValueError("Test filter also ran unexpected functions:\n" + "\n".join(sorted(unexpected)))
    if not cases:
        raise ValueError("No completed test cases")
    return len(expected)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("discovery", type=Path)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    try:
        count = validate(args.discovery.read_text(), args.report.read_text())
    except (OSError, ValueError, ET.ParseError) as error:
        print(f"Test completion validation failed: {error}", file=sys.stderr)
        return 1
    print(f"Test completion validated: all {count} discovered test functions completed; no skips/failures/errors")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
