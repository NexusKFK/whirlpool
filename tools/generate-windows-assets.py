#!/usr/bin/env python3
"""Package the existing LED glyphs and PNG icons for the Windows build."""
from pathlib import Path
import json, re, struct
root = Path(__file__).resolve().parent.parent
font = {key: [int(value.strip(), 16) for value in values.split(',') if value.strip()]
        for key, values in re.findall(r'"(.)": \[([^\]]+)\]', (root / 'Sources/FontData.swift').read_text())}
(root / 'Shared/font.json').write_text(json.dumps(font, ensure_ascii=False, indent=2) + '\n')
parts = [(size, (root / f'icons/pinwheel.iconset/icon_{size}x{size}.png').read_bytes()) for size in [16, 32, 128, 256]]
offset = 6 + 16 * len(parts)
output = struct.pack('<HHH', 0, 1, len(parts))
for size, data in parts:
    output += struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(data), offset)
    offset += len(data)
(root / 'icons/pinwheel.ico').write_bytes(output + b''.join(data for _, data in parts))
