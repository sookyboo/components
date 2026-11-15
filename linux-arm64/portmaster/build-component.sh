#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
components_root="$(git -C "$script_dir/../.." rev-parse --show-toplevel)"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/retrodeck-portmaster-arm.XXXXXX")"
artifact_dir="$script_dir/artifacts"
recipe_dir=""
trap 'rm -rf "$workdir"; [[ -z "$recipe_dir" ]] || rm -rf "$recipe_dir"' EXIT

for command_name in flatpak jq git envsubst tar; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  fi
done

native_arch="$(flatpak --default-arch)"
if [[ "$native_arch" != "aarch64" ]]; then
  printf 'Build PortMaster on an AArch64 host; Flatpak reports architecture %s.\n' "$native_arch" >&2
  exit 1
fi

cd "$components_root"
export COMPONENT_ARTIFACTS_DIR="$artifact_dir"

if [[ -n "${PORTMASTER_ARCHIVE_PATH:-}" ]]; then
  if [[ ! -s "$PORTMASTER_ARCHIVE_PATH" ]]; then
    printf 'PortMaster archive not found or empty: %s\n' "$PORTMASTER_ARCHIVE_PATH" >&2
    exit 1
  fi

  recipe_dir="$(mktemp -d "${TMPDIR:-/tmp}/retrodeck-portmaster-recipe.XXXXXX")"
  # The recipe's file-rename asset moves its source: hand it a copy, not the caller's archive.
  archive="$recipe_dir/retrodeck.portmaster.zip"
  cp "$PORTMASTER_ARCHIVE_PATH" "$archive"
  jq --arg archive "$archive" \
    --arg version "${PORTMASTER_ARCHIVE_VERSION:-2026.11.12-1059}" \
    '.portmaster[0].source_type = "local"
     | .portmaster[0].source_url = $archive
     | (.portmaster[0].assets[] | select(.type == "file-rename").source) = $archive
     | (.portmaster[0].assets[] | select(.dest == "component_version").contents) = $version' \
    "$components_root/portmaster/component_recipe.json" \
    > "$recipe_dir/component_recipe.json"
  recipe_path="$recipe_dir/component_recipe.json"
else
  recipe_path="$components_root/portmaster/component_recipe.json"
fi

bash "$components_root/automation-tools/alchemist/alchemist.sh" \
  --file "$recipe_path" \
  --versions "$script_dir/desired_versions.sh" \
  --output "$workdir"
