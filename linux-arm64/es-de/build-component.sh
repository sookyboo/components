#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
components_root="$(git -C "$script_dir/../.." rev-parse --show-toplevel)"
retrodeck_root="$(dirname "$components_root")/RetroDECK-arm-0.11.0"
manifest="$retrodeck_root/net.retrodeck.esde-arm64-build.yml"
state_dir="${FLATPAK_BUILDER_STATE_DIR:-$retrodeck_root/.flatpak-builder-state}"
build_dir="${ESDE_BUILD_DIR:-$retrodeck_root/.flatpak-builder/esde-arm64-component}"
artifact_dir="$script_dir/artifacts"

for command_name in flatpak-builder tar sha256sum python3; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  fi
done

if [[ ! -f "$manifest" ]]; then
  printf 'ES-DE ARM build manifest not found: %s\n' "$manifest" >&2
  exit 1
fi

mkdir -p "$(dirname "$build_dir")"
(
  cd "$retrodeck_root"
  flatpak-builder --user --state-dir="$state_dir/esde" --force-clean --jobs="${ESDE_BUILD_JOBS:-2}" --arch=aarch64 \
    --install-deps-from=flathub "$build_dir" "$manifest"
)

app_files="$build_dir/files"
component_dir="$(mktemp -d "${TMPDIR:-/tmp}/retrodeck-esde-arm.XXXXXX")"
trap 'rm -rf "$component_dir"' EXIT

if [[ ! -x "$app_files/bin/es-de" ]]; then
  printf 'Built ES-DE executable is missing: %s\n' "$app_files/bin/es-de" >&2
  exit 1
fi
if [[ ! -f "$app_files/share/es-de/resources/systems/linuxarm/es_systems.xml" || \
      ! -f "$app_files/share/es-de/resources/systems/linuxarm/es_find_rules.xml" ]]; then
  printf 'The build is missing ES-DE Linux ARM system definitions.\n' >&2
  exit 1
fi
if [[ ! -d "$app_files/share/es-de/themes/RetroDECK-theme-main" ]]; then
  printf 'RetroDECK ES-DE theme was not staged by the build manifest.\n' >&2
  exit 1
fi

install -Dm755 "$app_files/bin/es-de" "$component_dir/bin/es-de"
mkdir -p "$component_dir/share" "$component_dir/lib"
cp -a "$app_files/share/es-de" "$component_dir/share/"

# Keep the private shared-library dependencies next to the ES-DE component.
for library in "$app_files"/lib/libfreeimage* "$app_files"/lib/libgit2* "$app_files"/lib/libpugixml*; do
  if [[ -e "$library" || -L "$library" ]]; then
    cp -a "$library" "$component_dir/lib/"
  fi
done

for asset in component_functions.sh component_launcher.sh component_manifest.json component_recipe.json; do
  cp -a "$components_root/es-de/$asset" "$component_dir/"
done
cp -a "$components_root/es-de/rd_assets/rd_config" "$component_dir/rd_config"
cp -a "$components_root/es-de/rd_assets/helper_files" "$component_dir/helper_files"
cp -a "$components_root/es-de/rd_assets/res" "$component_dir/res"

# Prefer the bundled AArch64 GearColeco core for ColecoVision.
python3 "$script_dir/set-default-core.py" \
  "$component_dir/share/es-de/resources/systems/linuxarm/es_systems.xml" \
  colecovision Gearcoleco
python3 "$script_dir/set-default-core.py" \
  "$component_dir/share/es-de/resources/systems/linuxarm/es_systems.xml" \
  nds DeSmuME
python3 "$script_dir/set-default-core.py" \
  "$component_dir/share/es-de/resources/systems/linuxarm/es_systems.xml" \
  psx SwanStation
python3 "$script_dir/set-ppsspp-default.py" \
  "$component_dir/share/es-de/resources/systems/linuxarm/es_systems.xml"

python3 "$script_dir/add-portmaster-system.py" \
  "$component_dir/share/es-de/resources/systems/linuxarm/es_systems.xml" \
  "$component_dir/share/es-de/resources/systems/linuxarm/es_find_rules.xml"

# Launch ScummVM games from their selected game directory, including folders
# whose paths contain spaces, and resolve the bundled standalone launcher.
python3 - "$component_dir/share/es-de/resources/systems/linuxarm/es_systems.xml" <<'PYTHON'
from pathlib import Path
import sys

systems_path = Path(sys.argv[1])
systems = systems_path.read_text()
old = '<command label="ScummVM (Standalone)">%STARTDIR%=%GAMEDIR% %EMULATOR_SCUMMVM% %BASENAME%</command>'
new = '<command label="ScummVM (Standalone)">%STARTDIR%=%GAMEDIR% %EMULATOR_SCUMMVM% --path=%GAMEDIR% --auto-detect</command>'
if old not in systems:
    if new not in systems:
        raise SystemExit('ScummVM standalone command was not found in ES-DE systems')
else:
    systems_path.write_text(systems.replace(old, new, 1))
PYTHON

python3 - "$component_dir/share/es-de/resources/systems/linuxarm/es_find_rules.xml" <<'PYTHON'
from pathlib import Path
import sys

rules_path = Path(sys.argv[1])
rules = rules_path.read_text()
start = rules.index('<emulator name="SCUMMVM">')
end = rules.index('</emulator>', start)
block = rules[start:end]
static_path = '<rule type="staticpath">'
launcher = '<entry>/app/retrodeck/components/scummvm/component_launcher.sh</entry>'
if launcher not in block:
    if static_path not in block:
        raise SystemExit('ScummVM staticpath rule was not found in ES-DE rules')
    block = block.replace(static_path, static_path + '\n            ' + launcher, 1)
    rules_path.write_text(rules[:start] + block + rules[end:])
PYTHON

# Resolve the standalone Flathub emulator launchers bundled in the ARM app.
python3 - "$component_dir/share/es-de/resources/systems/linuxarm/es_find_rules.xml" <<'PYTHON'
from pathlib import Path
import sys

rules_path = Path(sys.argv[1])
rules = rules_path.read_text()
for emulator, component in (
    ('AZAHAR', 'azahar'),
    ('DOLPHIN', 'dolphin'),
    ('MELONDS', 'melonds'),
    ('MAME', 'mame'),
    ('XEMU', 'xemu'),
    ('CEMU', 'cemu'),
    ('DUCKSTATION', 'duckstation'),
    ('RPCS3', 'rpcs3'),
    ('VITA3K', 'vita3k'),
):
    start = rules.index(f'<emulator name="{emulator}">')
    end = rules.index('</emulator>', start)
    block = rules[start:end]
    static_path = '<rule type="staticpath">'
    launcher = f'<entry>/app/retrodeck/components/{component}/component_launcher.sh</entry>'
    if launcher not in block:
        if static_path not in block:
            raise SystemExit(f'{emulator} staticpath rule was not found in ES-DE rules')
        block = block.replace(static_path, static_path + '\n            ' + launcher, 1)
        rules = rules[:start] + block + rules[end:]
rules_path.write_text(rules)
PYTHON

# Let ES-DE resolve the bundled standalone Ruffle launcher.
python3 - "$component_dir/share/es-de/resources/systems/linuxarm/es_find_rules.xml" <<'PYTHON'
from pathlib import Path
import sys

rules_path = Path(sys.argv[1])
rules = rules_path.read_text()
start = rules.index('<emulator name="RUFFLE">')
end = rules.index('</emulator>', start)
block = rules[start:end]
static_path = '<rule type="staticpath">'
launcher = '<entry>/app/retrodeck/components/ruffle/component_launcher.sh</entry>'
if launcher not in block:
    if static_path not in block:
        raise SystemExit('Ruffle staticpath rule was not found in ES-DE rules')
    block = block.replace(static_path, static_path + '\n            ' + launcher, 1)
    rules_path.write_text(rules[:start] + block + rules[end:])
PYTHON

# Let ES-DE resolve the bundled standalone PPSSPP launcher.
python3 - "$component_dir/share/es-de/resources/systems/linuxarm/es_find_rules.xml" <<'PYTHON'
from pathlib import Path
import sys

rules_path = Path(sys.argv[1])
rules = rules_path.read_text()
start = rules.index('<emulator name="PPSSPP">')
end = rules.index('</emulator>', start)
block = rules[start:end]
static_path = '<rule type="staticpath">'
launcher = '<entry>/app/retrodeck/components/ppsspp/component_launcher.sh</entry>'
if launcher not in block:
    if static_path not in block:
        raise SystemExit('PPSSPP staticpath rule was not found in ES-DE rules')
    block = block.replace(static_path, static_path + '\n            ' + launcher, 1)
    rules_path.write_text(rules[:start] + block + rules[end:])
PYTHON

printf '3.5.0\n' > "$component_dir/component_version"

mkdir -p "$artifact_dir"
archive_tmp="$artifact_dir/es-de.tar.gz.tmp"
trap 'rm -rf "$component_dir"; rm -f "$archive_tmp"' EXIT
tar -czf "$archive_tmp" -C "$component_dir" .
mv -f "$archive_tmp" "$artifact_dir/es-de.tar.gz"
sha256sum "$artifact_dir/es-de.tar.gz" | awk '{print $1}' > "$artifact_dir/es-de.tar.gz.sha"

printf 'Created ARM ES-DE component archive:\n%s\n' "$artifact_dir/es-de.tar.gz"
