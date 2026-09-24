#!/usr/bin/env python3
"""Check the exchange tables shared by the macOS and Windows MarketClock.

- Both platforms must carry identical closure/half-day tables and index sets.
- Listed dates must be weekdays (weekends are closed anyway) and unique per table.
- The tables must cover the current year and, from December 1, the next one.
  China's holiday notice and HKEX's calendar are published once a year; a missing
  year silently falls back to "weekdays are open". Coverage problems are warnings,
  or errors with --strict (the scheduled CI run), so a late notice does not block
  unrelated pushes.
"""
import datetime as dt
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
swift = (root / 'Sources/MarketClock.swift').read_text()
csharp = (root / 'Windows/Whirlpool.Core/MarketClock.cs').read_text()
strict = '--strict' in sys.argv[1:]
errors, warnings = [], []


def block(source, start, end, name):
    match = re.search(re.escape(start) + r'(.*?)' + re.escape(end), source, re.S)
    if not match:
        errors.append(f'{name}: table not found')
        return []
    return re.findall(r'"([^"]+)"', match.group(1))


tables = {
    'sseClosed': (block(swift, 'static let sseClosed: Set<String> = [', ']', 'Swift sseClosed'),
                  block(csharp, 'SseClosed = Dates(', ');', 'C# SseClosed')),
    'hkexClosed': (block(swift, 'static let hkexClosed: Set<String> = [', ']', 'Swift hkexClosed'),
                   block(csharp, 'HkexClosed = Dates(', ');', 'C# HkexClosed')),
    'hkexHalfDay': (block(swift, 'static let hkexHalfDay: Set<String> = [', ']', 'Swift hkexHalfDay'),
                    block(csharp, 'HkexHalfDay = Dates(', ');', 'C# HkexHalfDay')),
}
indices = {
    'usIndices': (block(swift, 'static let usIndices: Set<String> = [', ']', 'Swift usIndices'),
                  block(csharp, 'UsIndices = [', '];', 'C# UsIndices')),
    'hongKongIndices': (block(swift, 'static let hongKongIndices: Set<String> = [', ']', 'Swift hongKongIndices'),
                        block(csharp, 'HongKongIndices = [', '];', 'C# HongKongIndices')),
}

for name, (mac, win) in {**tables, **indices}.items():
    if set(mac) != set(win):
        errors.append(f'{name} differs: macOS only {sorted(set(mac) - set(win))}, Windows only {sorted(set(win) - set(mac))}')
    if len(set(mac)) != len(mac):
        errors.append(f'{name}: duplicate entries')

dates = {}
for name, (mac, _) in tables.items():
    parsed = []
    for text in mac:
        try:
            day = dt.date.fromisoformat(text)
        except ValueError:
            errors.append(f'{name}: {text} is not a date')
            continue
        if day.weekday() >= 5:
            errors.append(f'{name}: {text} is a weekend')
        parsed.append(day)
    dates[name] = parsed
overlap = set(dates['hkexClosed']) & set(dates['hkexHalfDay'])
if overlap:
    errors.append(f'hkexClosed and hkexHalfDay overlap: {sorted(map(str, overlap))}')

today = dt.date.today()
required = {today.year} | ({today.year + 1} if today.month == 12 else set())
for exchange, name in (('China A-shares', 'sseClosed'), ('HKEX', 'hkexClosed')):
    missing = sorted(required - {d.year for d in dates[name]})
    if missing:
        warnings.append(f'{exchange} closures for {", ".join(map(str, missing))} are missing from {name}: '
                        'add the published holiday table to Sources/MarketClock.swift and Windows/Whirlpool.Core/MarketClock.cs')

for message in errors:
    print(f'::error::{message}')
for message in warnings:
    print(f'::{"error" if strict else "warning"}::{message}')
if errors or (strict and warnings):
    sys.exit(1)
covered = {name: sorted({d.year for d in days}) for name, days in dates.items()}
print(f'Exchange tables match on both platforms; years covered: {covered}')
