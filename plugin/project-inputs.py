# SPDX-License-Identifier: MIT
"""Ask Nix for pinned native npm repositories; retain their outputs locally."""
import json
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[1])
import project_inputs
_, _, lockfile, state, references, refresh = sys.argv
file, state = Path(lockfile), Path(state)
try:
    previous = json.loads(file.read_text()).get('projectInputs', []) if file.exists() else []
except json.JSONDecodeError:
    previous = []
requested = json.loads(references)
if requested is None:
    requested = [item['reference'] for item in previous]
pins = project_inputs.pin(requested, previous, refresh == 'true')
state.mkdir(parents=True, exist_ok=True)
views = project_inputs.npm_views(pins, state/'repositories')
print(json.dumps({'projectInputs':pins, 'views':views}, default=str))
