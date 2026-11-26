#!/usr/bin/env bash
# Move the LineageOS pins in default.xml to the current head of its
# LineageOS branch (doha_android#107), e.g. to pick up a monthly security
# merge. doha's own projects keep their pins.
#
# Usage: ./repin.sh [BASE_DIR]
#
# BASE_DIR is a plain LineageOS checkout of the branch default.xml follows
# (default: ~/android/base/<branch>), with no local manifests and no device
# projects. It is synced to the branch head; nothing in it is patched.
#
# doha's delta is worked out from default.xml itself, by comparing it with
# the LineageOS manifest at the commit default.xml currently pins
# (project LineageOS/android):
#   - projects doha adds keep their entries and pins;
#   - projects doha replaces at an upstream path (a different name or
#     remote, e.g. AOSPA's external/fastrpc) keep doha's entry;
#   - upstream projects doha leaves out stay out;
#   - every other project takes upstream's new pin, and projects that are
#     new upstream are added.
# The remotes and <default> stay doha's. Conflicts (upstream now has a
# project where doha adds one, or upstream changed a project doha replaces
# or leaves out) are reported; they need a look by hand.
#
# Then default.xml is rewritten, a summary of what moved is printed, with
# the security patch level before and after, and every patch for an
# upstream project is checked with `git apply --check` against the synced
# base tree. Committing and a test build are left to you.
#
# Environment:
#   SKIP_SYNC=1   don't sync BASE_DIR; take its current state. With BASE_DIR
#                 at the existing pins this is a dry run that must leave
#                 default.xml unchanged.
#   SYNC_JOBS     parallel repo sync jobs (default: 4)
#   REPO_IMAGE    Docker image used for repo when it isn't installed
#                 (default: lineageos4microg/docker-lineage-cicd:latest)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SYNC_JOBS=${SYNC_JOBS:-4}
REPO_IMAGE=${REPO_IMAGE:-lineageos4microg/docker-lineage-cicd:latest}
MANIFEST=$HERE/default.xml

die() { printf 'repin.sh: %s\n' "$*" >&2; exit 1; }

git -C "$HERE" diff --quiet HEAD -- default.xml ||
  die "default.xml has uncommitted changes; commit or stash them first"

# The LineageOS branch default.xml follows, from its <default revision=...>.
branch=$(python3 -I - "$MANIFEST" <<'PY'
import sys, xml.etree.ElementTree as ET
d = ET.parse(sys.argv[1]).getroot().find('default')
rev = d.get('revision', '') if d is not None else ''
print(rev.removeprefix('refs/heads/'))
PY
)
case $branch in
  lineage-*) ;;
  *) die "default.xml's <default revision> is '$branch', not a lineage-* branch" ;;
esac

BASE=$(cd "${1:-$HOME/android/base/$branch}" && pwd)
[ -d "$BASE/.repo/manifests" ] || die "$BASE is not a repo checkout"
if compgen -G "$BASE/.repo/local_manifests/*.xml" >/dev/null; then
  die "$BASE has local manifests; it must be a plain LineageOS checkout"
fi
tracking=$(git -C "$BASE/.repo/manifests" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)
[ "$tracking" = "origin/$branch" ] ||
  die "$BASE follows '${tracking:-nothing}', not origin/$branch"

# Same Git settings as build.sh: works in a container whose user doesn't own
# the checkout, and writes nothing to ~/.gitconfig.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'

run_repo() {
  if command -v repo >/dev/null; then
    (cd "$BASE" && repo "$@")
  else
    command -v docker >/dev/null || die "neither repo nor docker is installed"
    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
      -e GIT_CONFIG_COUNT -e GIT_CONFIG_KEY_0 -e GIT_CONFIG_VALUE_0 \
      -v "$BASE":/src -w /src --entrypoint repo "$REPO_IMAGE" "$@"
  fi
}

security_patch() {
  cat "$BASE"/vendor/lineage/release/flag_values/*/RELEASE_PLATFORM_SECURITY_PATCH.textproto 2>/dev/null |
    sed -n 's/.*string_value: *"\(.*\)".*/\1/p' | sort -u | paste -sd' '
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

sp_before=$(security_patch)
if [ "${SKIP_SYNC:-0}" != 1 ]; then
  echo "Syncing $BASE to $branch ..."
  run_repo sync -c -j"$SYNC_JOBS" --retry-fetches=5 --no-tags --no-clone-bundle
fi
sp_after=$(security_patch)
# repo prints its own notices on stderr; only stdout is the manifest.
run_repo manifest -r -o - > "$tmp/upstream.xml"

python3 -I - "$MANIFEST" "$tmp/upstream.xml" "$BASE/.repo/manifests" "$tmp/new.xml" <<'PY'
import subprocess, sys, xml.etree.ElementTree as ET

cur_file, new_file, manifests_git, out_file = sys.argv[1:]
cur = ET.parse(cur_file).getroot()
new = ET.parse(new_file).getroot()
problems = []

def path(p):
    return p.get('path', p.get('name'))

def projects(root):
    return [e for e in root if e.tag == 'project']

def default_remote(root):
    d = root.find('default')
    return d.get('remote') if d is not None else None

def ident(p, dremote):
    return (p.get('name'), p.get('remote', dremote))

# The upstream manifest at the commit default.xml pins, with its includes:
# which projects LineageOS had then, by path, as (name, remote).
cur_by_path = {path(p): p for p in projects(cur)}
pin = next((p.get('revision') for p in projects(cur)
            if p.get('name') == 'LineageOS/android'), None)
if not pin:
    sys.exit('default.xml has no LineageOS/android project to tell the old upstream manifest by')

def git_show(name):
    try:
        return subprocess.run(['git', '-C', manifests_git, 'show', f'{pin}:{name}'],
                              check=True, capture_output=True).stdout
    except subprocess.CalledProcessError as e:
        sys.exit(f'cannot read {name} at {pin} from {manifests_git}: '
                 f'{e.stderr.decode().strip()}')

old = {}
old_dremote = [None]
def load_old(name):
    root = ET.fromstring(git_show(name))
    for e in root:
        if e.tag == 'default' and e.get('remote'):
            old_dremote[0] = e.get('remote')
        elif e.tag == 'include':
            load_old(e.get('name'))
        elif e.tag == 'project':
            old[path(e)] = e
        elif e.tag == 'remove-project':
            for k, p in list(old.items()):
                if (e.get('path') and k == e.get('path')) or \
                   (not e.get('path') and p.get('name') == e.get('name')):
                    del old[k]
load_old('default.xml')
old = {k: ident(p, old_dremote[0]) for k, p in old.items()}

cdr, ndr = default_remote(cur), default_remote(new)
new_by_path = {path(p): p for p in projects(new)}
cur_id = {k: ident(p, cdr) for k, p in cur_by_path.items()}
new_id = {k: ident(p, ndr) for k, p in new_by_path.items()}

added = [k for k in cur_by_path if k not in old]
replaced = [k for k in cur_by_path if k in old and cur_id[k] != old[k]]
dropped = [k for k in old if k not in cur_by_path]

for k in added:
    if k in new_by_path:
        problems.append(f'upstream now has {new_id[k][0]} at {k}, where doha adds '
                        f'{cur_id[k][0]}; kept doha\'s, upstream\'s left out')
for k in replaced:
    if k not in new_by_path:
        problems.append(f'upstream removed {old[k][0]} at {k}, which doha replaces '
                        f'with {cur_id[k][0]}; kept doha\'s')
    elif new_id[k] != old[k]:
        problems.append(f'upstream changed {k} from {old[k][0]} to {new_id[k][0]}; '
                        f'doha replaces it with {cur_id[k][0]}; kept doha\'s')
for k in dropped:
    if k in new_by_path and new_id[k] != old[k]:
        problems.append(f'upstream changed {k}, which doha leaves out, from '
                        f'{old[k][0]} to {new_id[k][0]}; still left out')

# Build the result in upstream's element order, with doha's remotes and
# <default> in place of upstream's, and doha's own projects at the end.
out = ET.Element('manifest', new.attrib)
cur_head = [e for e in cur if e.tag in ('remote', 'default')]
cur_remotes = {e.get('name') for e in cur_head if e.tag == 'remote'}
new_remotes = {e.get('name'): e for e in new if e.tag == 'remote'}
head_done = False
body = []
for e in new:
    if e.tag in ('remote', 'default'):
        continue
    if e.tag == 'project':
        k = path(e)
        if k in dropped or k in added:
            continue
        body.append(cur_by_path[k] if k in replaced else e)
    else:
        body.append(e)
# doha's own projects: the ones it adds, and replacements upstream dropped.
own = [cur_by_path[k] for k in cur_by_path
       if k in added or (k in replaced and k not in new_by_path)]

used = {p.get('remote', cdr) for p in body + own if p.tag == 'project'}
extra_remotes = []
for name in sorted(used - cur_remotes):
    if name not in new_remotes:
        sys.exit(f'remote {name} is used but defined nowhere')
    extra_remotes.append(new_remotes[name])
    problems.append(f'added upstream remote {name} '
                    f'(fetch="{new_remotes[name].get("fetch")}"); check its fetch URL')
nd, cd = new.find('default'), cur.find('default')
if nd is not None and cd is not None and nd.attrib != cd.attrib:
    problems.append(f'upstream <default> is now {nd.attrib}; kept doha\'s {cd.attrib}')
lost = [e.tag for e in cur if e.tag not in ('remote', 'default', 'project')
        and e.tag not in {x.tag for x in new}]
for tag in lost:
    problems.append(f'<{tag}> in default.xml has no upstream counterpart any more; dropped')

remotes = [e for e in cur_head if e.tag == 'remote']
others = [e for e in cur_head if e.tag != 'remote']
out.extend(remotes + extra_remotes + others + body + own)
tree = ET.ElementTree(out)
ET.indent(tree, '  ')
tree.write(out_file, xml_declaration=True, encoding='UTF-8')
with open(out_file, 'a') as f:
    f.write('\n')

# Summary.
res_by_path = {path(p): p for p in body + own if p.tag == 'project'}
moved = sorted(k for k in res_by_path if k in cur_by_path
               and res_by_path[k].get('revision') != cur_by_path[k].get('revision'))
new_upstream = sorted(k for k in res_by_path if k not in cur_by_path)
gone = sorted(k for k in cur_by_path if k not in res_by_path)
print(f'doha delta: {len(added)} added, {len(replaced)} replaced '
      f'({", ".join(replaced) or "-"}), {len(dropped)} left out ({", ".join(dropped) or "-"})')
print(f'{len(moved)} projects moved:')
for k in moved:
    print(f'  {k}  {cur_by_path[k].get("revision")[:12]} -> {res_by_path[k].get("revision")[:12]}')
for k in new_upstream:
    print(f'  new upstream: {k} ({res_by_path[k].get("name")})')
for k in gone:
    print(f'  removed upstream: {k} ({cur_by_path[k].get("name")})')
for p in problems:
    print(f'CHECK: {p}')
with open(out_file + '.upstream-paths', 'w') as f:
    for k in res_by_path:
        if k not in added and k not in replaced:
            f.write(k + '\n')
PY

if cmp -s "$tmp/new.xml" "$MANIFEST"; then
  echo "default.xml unchanged."
else
  cp "$tmp/new.xml" "$MANIFEST"
  echo "default.xml rewritten: $(git -C "$HERE" diff --numstat -- default.xml | awk '{print $1 " lines in, " $2 " out"}')."
fi
echo "Security patch level: ${sp_before:-?} -> ${sp_after:-?}"

# Patches for upstream projects must still apply to the new pins. doha's own
# projects keep their pins, so their patches can't break here (and they
# aren't in the base tree). Placeholders are filled in as build.sh does.
failed=0
while IFS= read -r patch; do
  proj=${patch#"$HERE/patches/"}
  proj=${proj%.patch}
  grep -qxF "$proj" "$tmp/new.xml.upstream-paths" || continue
  if sed -e 's/@SKIN_THROTTLE_MC@/40000/g' -e 's|@UPDATER_URI@|https://example.invalid/x.json|g' "$patch" |
     git -C "$BASE/$proj" apply --check --whitespace=nowarn 2>"$tmp/apply.err"; then
    echo "applies: patches/$proj.patch"
  else
    echo "FAILS:   patches/$proj.patch"
    sed 's/^/    /' "$tmp/apply.err"
    failed=1
  fi
done < <(find "$HERE/patches" -name '*.patch' | sort)

if [ "$failed" = 1 ]; then
  echo "Some patches no longer apply; refresh them before building." >&2
  exit 1
fi
echo "Next: review 'git diff default.xml', commit, and run a test build."
