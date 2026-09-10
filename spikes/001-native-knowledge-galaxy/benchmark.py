#!/usr/bin/env python3
"""Synthetic offscreen measurements. Not display FPS or a transcription benchmark."""
import json
from pathlib import Path
import re
import subprocess

here = Path(__file__).resolve().parent
binary = here / '.build' / 'ListenGalaxy'
output = here / 'results'
output.mkdir(exist_ok=True)
results = []
for size in (80, 400, 1200):
    command = ['/usr/bin/time', '-l', str(binary), '--nodes', str(size),
               '--frames', '120', '--probe', str(output / f'probe-{size}.png')]
    process = subprocess.run(command, text=True, capture_output=True, check=True)
    result = json.loads(process.stdout)
    match = re.search(r'(\d+)\s+maximum resident set size', process.stderr)
    if match:
        result['process_peak_rss_mib'] = int(match.group(1)) / (1024 * 1024)
    result['measurement'] = 'Synthetic spherical force layout; sparse thematic edges; 1280x800 offscreen. Mean of 120 frames including first frame. CPU metric includes synchronous GPU wait. Peak RSS is whole probe process, not renderer alone.'
    results.append(result)
    print(json.dumps(result, sort_keys=True))
(output / 'shell-benchmarks.json').write_text(json.dumps(results, indent=2, sort_keys=True) + '\n')
