from pathlib import Path
import json
import subprocess
import tempfile

binary = Path(__file__).resolve().parents[1] / '.build' / 'ListenGalaxy'
assert binary.exists(), 'CLI executable is missing'

def run(*args):
    return subprocess.run([str(binary), *args], capture_output=True, text=True)

p = run('--summary', '--nodes', '80')
assert p.returncode == 0, p.stderr
summary = json.loads(p.stdout)
assert summary['synthetic'] is True and summary['nodes'] == 80, summary
assert summary['nodes_by_kind']['device'] == 1, summary
assert all(kind in summary['nodes_by_kind'] for kind in ['person', 'note', 'chat', 'recording']), summary
with tempfile.TemporaryDirectory(prefix='listen-galaxy-cli-') as root:
    p = run('--summary', '--library', root)
    assert p.returncode == 0, p.stderr
    summary = json.loads(p.stdout)
    assert summary['synthetic'] is False and summary['nodes'] == 1 and summary['nodes_by_kind'] == {'device': 1}, summary
p = run('--summary', '--library', '/nonexistent/listen-galaxy-test')
assert p.returncode != 0 and not p.stdout.strip(), p
assert run('--nodes', 'garbage').returncode != 0
assert run('--unknown').returncode != 0
print('PASS: CLI synthetic/live separation, empty library and invalid arguments')
