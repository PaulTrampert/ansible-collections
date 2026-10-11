#!/usr/bin/env bash
# Run by Renovate once per branch, after it has updated the version pins (see
# postUpgradeTasks in .github/renovate.json5). Bumps the PATCH version in the
# updated collection's galaxy.yml and adds a CHANGELOG.md section listing the
# updates.
#
# Renovate passes the updates in the file named by
# RENOVATE_POST_UPGRADE_COMMAND_DATA_FILE, one per line:
#
#   <package file> <dependency> <current version> <new version>
#
# The new version and changelog are worked out from the files as they are in
# HEAD, the base branch in Renovate's checkout, so running this again on a
# branch it has already bumped gives the same result rather than bumping twice.
set -euo pipefail

data_file=${RENOVATE_POST_UPGRADE_COMMAND_DATA_FILE:?is not set}

collection=""
entries=()
while read -r package_file dep_name current_value new_value; do
  [[ -n $package_file ]] || continue
  if [[ ! $package_file =~ ^(ptrampert/[^/]+)/(roles/([^/]+)/)? ]]; then
    echo "$package_file is not in a collection" >&2
    exit 1
  fi
  if [[ -n $collection && $collection != "${BASH_REMATCH[1]}" ]]; then
    echo "The updates span $collection and ${BASH_REMATCH[1]}; group them by collection" >&2
    exit 1
  fi
  collection=${BASH_REMATCH[1]}
  role=${BASH_REMATCH[3]}

  entry="update \`$dep_name\` from \`$current_value\` to \`$new_value\`."
  if [[ -n $role ]]; then
    entry="\`$role\`: $entry"
  else
    entry="U${entry#u}"
  fi
  entries+=("- $entry")
done <"$data_file"

if [[ -z $collection ]]; then
  echo "No updates in $data_file" >&2
  exit 1
fi

# A pin appears in both defaults/main.yml and meta/argument_specs.yml, so most
# updates arrive twice.
entries_text=$(printf '%s\n' "${entries[@]}" | awk '!seen[$0]++')

galaxy=$collection/galaxy.yml
version=$(git show "HEAD:$galaxy" | sed -n 's/^version: *\([0-9][0-9.]*\) *$/\1/p')
if [[ ! $version =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "Cannot read the version in $galaxy" >&2
  exit 1
fi
new_version=${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))

# Only the version line: the ansible-galaxy manager may have changed the
# dependencies in the same file.
sed -i "s/^version: .*/version: $new_version/" "$galaxy"

# The new section goes above the newest released one, below any Unreleased
# section.
changelog=$collection/CHANGELOG.md
git show "HEAD:$changelog" |
  HEADING="## $new_version" ENTRIES="$entries_text" awk '
    function section() { print ENVIRON["HEADING"]; print ""; print ENVIRON["ENTRIES"] }
    !done && /^## / && $0 != "## Unreleased" { section(); print ""; done = 1 }
    { print }
    END { if (!done) { print ""; section() } }
  ' >"$changelog"
