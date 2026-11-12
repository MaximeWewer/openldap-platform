#!/usr/bin/env python3
"""Point the chart at freshly built openldap-init / openldap-tools images.

Driven by the tool-images workflow. Several blocks in the values files carry a
`repository:` / `tag:` pair at the same depth (OpenLDAP image, exporter, init
image, TLS job, CLI), so the edits walk the YAML path of each block instead of
matching on indentation or on a value that may already have changed.

Edited blocks, in the subchart and inside the umbrella's `openldap:` key:
  initImage        -> openldap-init
  cli.image        -> openldap-tools   (+ cli.version / cli.kubectlVersion,
  tls.job.image    -> openldap-tools      kept in step for the alpine fallback)
"""
import os
import re
import sys
from pathlib import Path

OWNER = os.environ["OWNER"]
TAG = os.environ["TAG"]                        # e.g. 2026.11.12
CLI_VERSION = os.environ["CLI_VERSION"]        # e.g. v2026.11.1
KUBECTL_NEWEST = os.environ["KUBECTL_NEWEST"]  # e.g. v1.37.2

INIT = f"ghcr.io/{OWNER}/openldap-init"
TOOLS = f"ghcr.io/{OWNER}/openldap-tools"

ROOT = Path(__file__).resolve().parents[2]
SUB = ROOT / "kubernetes/charts/openldap-platform/charts/openldap/values.yaml"
UMB = ROOT / "kubernetes/charts/openldap-platform/values.yaml"


def find_block(lines, path, start=0, indent=0):
    """Index of the line holding the last key of `path` (a list of keys)."""
    i, ind = start, indent
    for key in path:
        pat = re.compile(rf"^{' ' * ind}{re.escape(key)}:\s*(#.*)?$")
        for j in range(i, len(lines)):
            line = lines[j]
            if pat.match(line):
                i, ind = j + 1, ind + 2
                break
            # Left the parent block: a non-empty line indented less than us.
            if line.strip() and not line.startswith("#") and len(line) - len(line.lstrip()) < ind:
                raise KeyError(f"{'.'.join(path)}: '{key}' not found")
        else:
            raise KeyError(f"{'.'.join(path)}: '{key}' not found")
    return i - 1, ind


def set_in_block(lines, path, values, base_indent=0):
    """Set scalar children of the block at `path`."""
    head, ind = find_block(lines, path, indent=base_indent)
    for key, val in values.items():
        pat = re.compile(rf"^({' ' * ind}{re.escape(key)}:\s*)(\S.*?)(\s+#.*)?$")
        for j in range(head + 1, len(lines)):
            line = lines[j]
            if line.strip() and len(line) - len(line.lstrip()) < ind:
                raise KeyError(f"{'.'.join(path)}.{key} not found")
            m = pat.match(line)
            if m:
                lines[j] = f"{m.group(1)}{val}{m.group(3) or ''}"
                break
        else:
            raise KeyError(f"{'.'.join(path)}.{key} not found")


def bump(path: Path, prefix):
    lines = path.read_text().split("\n")
    base = 2 if prefix else 0
    p = [prefix] if prefix else []
    set_in_block(lines, p + ["initImage"], {"repository": INIT, "tag": f'"{TAG}"'}, 0)
    set_in_block(lines, p + ["cli", "image"], {"repository": TOOLS, "tag": f'"{TAG}"'}, 0)
    set_in_block(lines, p + ["cli"], {"version": f'"{CLI_VERSION}"', "kubectlVersion": f'"{KUBECTL_NEWEST}"'}, 0)
    set_in_block(lines, p + ["tls", "job", "image"], {"repository": TOOLS, "tag": f'"{TAG}"'}, 0)
    path.write_text("\n".join(lines))
    print(f"bumped {path.relative_to(ROOT)}")


try:
    bump(SUB, None)
    bump(UMB, "openldap")
except KeyError as exc:
    sys.exit(f"bump-tool-images: {exc}")
