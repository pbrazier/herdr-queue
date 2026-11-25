#!/bin/sh
# Cut a Herdr Queue release: bump the version everywhere, run the same checks as CI,
# commit, tag, and push. Pushing the tag makes the "Native builds" workflow build every
# platform and publish the GitHub release with SHA-256 checksums.
#
# Usage: scripts/release.sh <new-version> [--yes] [--dry-run]
#   <new-version>  e.g. 0.2.2 (no leading "v")
#   --dry-run      bump and check locally, then restore the files; commit and push nothing
#   --yes          skip the confirmation prompt before committing and pushing
set -eu

die() { echo "release: $*" >&2; exit 1; }

new=""
dry_run=0
assume_yes=0
for argument in "$@"; do
    case "$argument" in
        --dry-run) dry_run=1 ;;
        --yes) assume_yes=1 ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option: $argument" ;;
        *) [ -z "$new" ] || die "only one version may be given"; new=$argument ;;
    esac
done
[ -n "$new" ] || die "usage: scripts/release.sh <new-version> [--yes] [--dry-run]"
printf '%s\n' "$new" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || die "version must look like 1.2.3 (got '$new')"

cd "$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
command -v cargo >/dev/null 2>&1 || die "cargo is required"
command -v perl >/dev/null 2>&1 || die "perl is required"

current=$(sed -n 's/^version = "\(.*\)"$/\1/p' Cargo.toml | head -1)
[ -n "$current" ] || die "could not read the current version from Cargo.toml"
[ "$new" != "$current" ] || die "version is already $current"
# The new version must sort after the current one.
highest=$(printf '%s\n%s\n' "$current" "$new" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
[ "$highest" = "$new" ] || die "$new is lower than the current version $current"

tag="v$new"
branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" = main ] || die "releases are cut from main (on '$branch')"
[ -z "$(git status --porcelain)" ] || die "working tree has uncommitted changes"
git fetch --quiet origin main --tags
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || die "main is not in sync with origin/main; pull or push first"
! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || die "tag $tag already exists"

files="Cargo.toml Cargo.lock herdr-plugin.toml install.sh native/tests/launcher.rs"
restore() { git checkout --quiet -- $files; }

echo "Bumping $current -> $new"
# Only the package version lines; dependency versions are left alone.
perl -pi -e 's/^version = "\Q'"$current"'\E"$/version = "'"$new"'"/ if $. <= 5' Cargo.toml
perl -pi -e 's/^version = "\Q'"$current"'\E"$/version = "'"$new"'"/ if $. <= 5' herdr-plugin.toml
perl -pi -e 's/^VERSION=\Q'"$current"'\E$/VERSION='"$new"'/' install.sh
perl -pi -e 's/\Q'"$current"'\E/'"$new"'/g' native/tests/launcher.rs
cargo update --offline --quiet -p herdr-queue

for file in $files; do
    git diff --quiet -- "$file" && { restore; die "$file did not change; check the bump rules"; }
done
if git grep -n -F "$current" -- Cargo.toml herdr-plugin.toml install.sh native/tests/launcher.rs; then
    restore
    die "old version $current still present in the lines above"
fi

echo "Running the CI checks (fmt, clippy, tests)"
if ! { cargo fmt --check && cargo clippy --locked --all-targets -- -D warnings && cargo test --locked; }; then
    restore
    die "checks failed; files restored"
fi

git --no-pager diff --stat
if [ "$dry_run" = 1 ]; then
    restore
    echo "Dry run passed. Files restored; nothing committed, tagged or pushed."
    exit 0
fi

if [ "$assume_yes" != 1 ]; then
    printf 'Commit, tag %s and push to origin? [y/N] ' "$tag"
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) restore; die "aborted; files restored" ;; esac
fi

git add -- $files
git commit --quiet -m "chore(release): $tag"
git tag -a "$tag" -m "Herdr Queue $tag"
# Atomic: either both main and the tag land on origin, or neither does.
git push --atomic origin main "$tag"

echo "Pushed $tag. CI is building the release:"
echo "  gh run watch --repo \"\$(gh repo view --json nameWithOwner -q .nameWithOwner)\""
echo "Then update Herdr with: herdr plugin update herdr-drafts"
