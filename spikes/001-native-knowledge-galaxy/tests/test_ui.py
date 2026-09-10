import json
from pathlib import Path
import subprocess

binary = Path(__file__).resolve().parents[1] / '.build' / 'ListenGalaxy'
p = subprocess.run([str(binary), '--smoke-ui'], capture_output=True, text=True, timeout=20)
assert p.returncode == 0, p.stderr
assert p.stdout.strip(), 'UI smoke exited before emitting its completion assertions'
result = json.loads(p.stdout)
assert result['ui_smoke'] == 'passed' and result['selection'] is True, result
assert result['evidence_callbacks'] == 1, result
assert result['paused_frames_over_half_second'] == 0, result
assert result['hidden_frames_over_half_second'] == 0, result
if result['motion_permitted']:
    assert result['animated_frames_over_half_second'] > 0, result
print(json.dumps(result, indent=2, sort_keys=True))
