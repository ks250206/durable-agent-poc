#!/usr/bin/env python3
"""Fail-closed Swift string-site inventory, including nested interpolation and raw strings.

This is an audited source boundary, not a general Swift parser or linguistic-quality check.
No update/bless mode is provided: inventory changes require explicit review.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys


class InventoryError(ValueError):
    pass


def string_sites(source):
    sites = []

    def code(i, interpolation=False):
        depth = 1
        while i < len(source):
            if source.startswith('//', i):
                end = source.find('\n', i)
                i = len(source) if end < 0 else end
            elif source.startswith('/*', i):
                nesting = 1
                i += 2
                while nesting and i < len(source):
                    if source.startswith('/*', i):
                        nesting += 1
                        i += 2
                    elif source.startswith('*/', i):
                        nesting -= 1
                        i += 2
                    else:
                        i += 1
                if nesting:
                    raise InventoryError('unterminated comment')
            elif match := re.match(r'(#{0,})"', source[i:]):
                start = i
                hashes = match[1]
                quote = '"""' if source.startswith('"""', i + len(hashes)) else '"'
                i += len(hashes) + len(quote)
                end = quote + hashes
                escape = '\\' + hashes
                while i < len(source):
                    if source.startswith(end, i):
                        i += len(end)
                        line_start = source.rfind('\n', 0, start) + 1
                        # Prefix binds the literal to its actual sink (Text, AX, diagnostic, wire,
                        # localizer, etc.). Counts catch additions even of an existing allowed key.
                        prefix = source[line_start:start].strip()
                        sites.append((prefix, source[start:i]))
                        break
                    if source.startswith(escape + '(', i):
                        i = code(i + len(escape) + 1, True)
                    elif source.startswith(escape, i):
                        i += len(escape) + 1
                    else:
                        i += 1
                else:
                    raise InventoryError('unterminated string')
            elif interpolation and source[i] == '(':
                depth += 1
                i += 1
            elif interpolation and source[i] == ')':
                depth -= 1
                i += 1
                if not depth:
                    return i
            else:
                i += 1
        if interpolation:
            raise InventoryError('unterminated interpolation')
        return i

    code(0)
    return Counter(sites)


def validate(root, inventory):
    problems = []
    actual_files = {str(p.relative_to(root)) for p in (root / 'Sources').rglob('*.swift')}
    expected_files = set(inventory['sources'])
    for path in sorted(actual_files ^ expected_files):
        problems.append(f'{path}: source file added/removed; audit its strings explicitly')
    references = {table: set() for table in inventory['tables']}
    for path in sorted(actual_files & expected_files):
        entries = inventory['sources'][path]
        expected = Counter()
        for entry in entries:
            expected[(entry['prefix'], entry['literal'])] += entry['count']
            if entry['kind'] not in ('localized', 'diagnostic', 'dynamic', 'allowlisted') or not inventory['reasons'].get(entry['reason'], '').strip():
                problems.append(f'{path}: missing classification/reason')
            for table, keys in entry.get('keys', {}).items():
                if table not in references:
                    problems.append(f'{path}: unknown table {table}')
                    continue
                for key in keys:
                    references[table].add(key)
                    if key not in inventory['tables'][table]:
                        problems.append(f'{path}: unregistered {table} key {key!r}')
        actual = string_sites((root / path).read_text())
        for prefix, literal in sorted((actual - expected).elements()):
            problems.append(f'{path}: uncovered string at {prefix} {literal[:180]}')
        for prefix, literal in sorted((expected - actual).elements()):
            problems.append(f'{path}: stale inventory at {prefix} {literal[:180]}')
    for table, keys in inventory['reservedKeys'].items():
        for key, reason in keys.items():
            if key not in inventory['tables'][table] or not reason.strip():
                problems.append(f'{table}: invalid reserved key {key!r}')
            references[table].add(key)
    for table, keys in inventory['tables'].items():
        for key in sorted(set(keys) - references[table]):
            problems.append(f'{table}: key without audited source/dynamic coverage {key!r}')
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    inventory = json.loads((args.root / 'scripts/localization/inventory.json').read_text())
    problems = validate(args.root, inventory)
    if problems:
        print('\n'.join(problems), file=sys.stderr)
        return 1
    print(f"Source audit passed: {len(inventory['sources'])} Swift files; all string sites classified; "
          + ', '.join(f'{table} {len(keys)}' for table, keys in inventory['tables'].items()))
    return 0


if __name__ == '__main__':
    sys.exit(main())
