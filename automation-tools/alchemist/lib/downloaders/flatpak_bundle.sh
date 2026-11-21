#!/bin/bash

downloader_info() {
  echo "type:flatpak-bundle,flatpak_bundle"
}

download() {
  local flatpak_bundle_file="$1"
  local flatpak_install_mode="$2"
  local flatpak_id="$3"
  local type="$4"
  local max_retries="${5:-3}"
  local initial_delay="${6:-2}"
  local max_delay="${7:-30}"
  local resolve_version="$8"

  if [[ "$ALCHEMIST_FLATPAK_MODE" == "directory" ]]; then
    flatpak_install_mode="user"
  fi

  if [[ "$resolve_version" == "true" ]]; then
    echo "DOWNLOADED_VERSION=$flatpak_id"
    return 0
  fi

  if [[ "$flatpak_install_mode" == "user" ]]; then
    final_dest="$FLATPAK_USER_ROOT/app/$flatpak_id/current/active/files"
  elif [[ "$flatpak_install_mode" == "system" ]]; then
    final_dest="$FLATPAK_SYSTEM_ROOT/app/$flatpak_id/current/active/files"
  else
    log warn "Provided Flatpak destination invalid. Valid options are \"user\" or \"system\". Defaulting to \"$FLATPAK_DEFAULT_INSTALL_MODE\" install type."
    flatpak_install_mode="$FLATPAK_DEFAULT_INSTALL_MODE"
    final_dest="$FLATPAK_USER_ROOT/app/$flatpak_id/current/active/files"
  fi

  log info "Installing: $flatpak_bundle_file"
  log info "Destination: $final_dest"
  log info "Flatpak Install Mode: $flatpak_install_mode"

  download_cmd() {
    install_flatpak "$flatpak_bundle_file" "bundle" "$flatpak_install_mode" "bundle" 2>&1
  }

  if [[ -d "$final_dest" ]]; then # If the bundle is already installed, flatpak cannot update it in place. Removing first
    log info "Flatpak bundle $flatpak_id is already installed, removing first to freshen..."
    flatpak remove --"$flatpak_install_mode" -y --noninteractive "$flatpak_id"
  fi

  if ! try "$max_retries" "$initial_delay" "$max_delay" download_cmd; then
    log error "Download failed: $flatpak_bundle_file"
    return 1
  fi

  # Resolve the deployment location because temporary directory mode can use
  # a different XDG data root from the user's normal Flatpak installation.
  local install_location
  install_location="$(flatpak info --"$flatpak_install_mode" --show-location "$flatpak_id" 2>/dev/null)" || {
    log error "Could not locate the installed Flatpak ref for $flatpak_id"
    return 1
  }
  final_dest="$install_location/files"

  # Verify local Flatpak install exists
  if [[ ! -d "$final_dest" ]]; then
    log error "Flatpak not installed at desired destination: $final_dest"
    return 1
  fi

  log info "Flatpak install completed successfully"
  echo "DOWNLOADED_VERSION=$flatpak_id"
  echo "DOWNLOADED_FILE=$final_dest"
  return 0
}
