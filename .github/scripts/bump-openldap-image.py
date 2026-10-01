#!/usr/bin/env python3
"""Move every reference to the OpenLDAP image onto a new version.

Driven by the mirror workflow. Kept out of the YAML because the edits are
indentation-sensitive: `securityContext.runAsUser` in the subchart values sits
two spaces in, the same key four spaces in inside the umbrella's `openldap:`
block, and a careless anchor-free sed happily rewrites the CLI's own
`version:` line instead of the image tag.

The ldap uid/gid travels with the tag on purpose: the account baked into the
image moved between OpenLDAP majors (2.6 ships 101:102, 2.7 ships 102:103) and
/var/lib/openldap is 0700 for it, so a tag bump that leaves securityContext
behind produces a pod that cannot read its own volume. The chart refuses to
render that mismatch, which would turn this PR into a broken build rather than
a broken deployment - but it is better not to open it wrong in the first place.
"""
import os
import re
import sys
from pathlib import Path

OLD = os.environ["OLD"]
NEW = os.environ["NEW"]
OWNER = os.environ["OWNER"]
UID = os.environ["NEW_UID"]
GID = os.environ["NEW_GID"]

UPSTREAM = "cleanstart/openldap"
MIRROR = f"ghcr.io/{OWNER}/openldap"

ROOT = Path(__file__).resolve().parents[2]
SUB = ROOT / "kubernetes/charts/openldap-platform/charts/openldap"
UMB = ROOT / "kubernetes/charts/openldap-platform"

changed = []


def edit(path: Path, subs):
    """Apply (pattern, replacement) pairs, reporting the ones that missed."""
    text = path.read_text()
    before = text
    for pattern, repl in subs:
        text, n = re.subn(pattern, repl, text, flags=re.M)
        if n == 0:
            print(f"  note: no match for {pattern!r} in {path.relative_to(ROOT)}")
    if text != before:
        path.write_text(text)
        changed.append(str(path.relative_to(ROOT)))


# --- subchart values: image tag + the uid that has to follow it --------------
# The tag is matched on its CURRENT VALUE, never on indentation alone: these
# files hold several `tag:` keys at the same depth - the Alpine init image and
# the Prometheus exporter among them - and an indentation-only anchor renames
# all of them. Only the one that still reads as the old OpenLDAP version is
# the image this bump is about.
def image_subs(indent: str):
    i = indent
    return [
        (rf'^({i}repository: )(?:.*/)?openldap$', rf'\g<1>{MIRROR}'),
        (rf'^({i}tag: "){re.escape(OLD)}(")$', rf'\g<1>{NEW}\g<2>'),
        (rf'^({i}runAsUser: )\d+$', rf'\g<1>{UID}'),
        (rf'^({i}runAsGroup: )\d+$', rf'\g<1>{GID}'),
        (rf'^({i}fsGroup: )\d+$', rf'\g<1>{GID}'),
    ]


edit(SUB / "values.yaml", image_subs("  "))

# --- umbrella values: same keys, one level deeper ----------------------------
edit(UMB / "values.yaml", image_subs("    "))

# --- appVersion follows the server, not the chart ----------------------------
for chart in (UMB / "Chart.yaml", SUB / "Chart.yaml"):
    edit(chart, [
        (r'^(appVersion: ")[^"]+(")$', rf'\g<1>{NEW}\g<2>'),
        # The umbrella's artifacthub images annotation, when present. Anchored
        # on the image name so the exporter entry beside it is left alone.
        (rf'^(\s*image: )(?:.*/)?openldap:\S+$', rf'\g<1>{MIRROR}:{NEW}'),
    ])

# --- Compose stacks, their setup/cert helpers and the docs -------------------
pat = re.compile(rf'(?:{re.escape(UPSTREAM)}|{re.escape(MIRROR)}):{re.escape(OLD)}')
for path in sorted((ROOT / "docker").rglob("*")):
    if not path.is_file() or path.suffix not in (".yml", ".yaml", ".sh", ".md"):
        continue
    text = path.read_text()
    new_text = pat.sub(f"{MIRROR}:{NEW}", text)
    if new_text != text:
        path.write_text(new_text)
        changed.append(str(path.relative_to(ROOT)))

if not changed:
    print(f"nothing referenced {OLD} - no bump to make", file=sys.stderr)
    sys.exit(1)

print(f"bumped {OLD} -> {NEW} ({UID}:{GID}) in:")
for c in changed:
    print("  " + c)
