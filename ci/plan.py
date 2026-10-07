"""Regenerate the caller workflow from the pinned preflight planner."""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
manifest = (root / "build.zig.zon").read_text()
ref = re.search(r'github.com/pedronaugusto/preflight#([0-9a-f]+)', manifest)[1]
matrices = {}
for tier in ("fast", "merge", "release"):
    with tempfile.TemporaryDirectory() as scratch:
        output = Path(scratch) / "plan"
        subprocess.run(
            [sys.argv[1], "plan", "--tier", tier, "--output", str(output)],
            cwd=root, check=True,
        )
        values = dict(line.split("=", 1) for line in output.read_text().splitlines())
        matrices[tier + "-matrix"] = values["matrix"]
        if tier != "fast":
            matrices[tier + "-compile-matrix"] = values["compile_matrix"]
            matrices[tier + "-run-matrix"] = values["run_matrix"]
        # Validate the complete planner output before writing the workflow.
        for key in ("matrix", "compile_matrix", "run_matrix"):
            json.loads(values[key])

workflow = root / ".github/workflows/ci.yml"
text = workflow.read_text()
text = re.sub(r'(preflight/\.github/workflows/\w+\.yml@)[0-9a-f]+', r'\g<1>' + ref, text)
text = re.sub(r'(preflight-ref: )[0-9a-f]+', r'\g<1>' + ref, text)
text = re.sub(r'# Generated[^\n]*', '# Generated from ci/workflow.json with zig build plan.', text)
for key, matrix in matrices.items():
    text, count = re.subn(r'(' + re.escape(key) + r': >-\n)[^\n]*', r'\g<1>        ' + matrix, text)
    if count != 1:
        raise ValueError("expected one workflow matrix: " + key)
workflow.write_text(text)
