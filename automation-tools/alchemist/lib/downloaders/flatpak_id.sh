#!/bin/bash

# Describe this downloader's capabilities
downloader_info() {
  echo "type:flatpak_id,flatpak-id"
}

download() {
  local flatpak_id="$1"
  local flatpak_install_mode="$2"
  local flatpak_version="$3"
  local type="$4"
  local max_retries="${5:-3}"
  local initial_delay="${6:-2}"
  local max_delay="${7:-30}"
  local resolve_version="$8"

  local resolved_flatpak_version="$flatpak_version"
  local directory_mode="false"

  if [[ "$ALCHEMIST_FLATPAK_MODE" == "directory" ]]; then
    # Directory mode overrides the recipe's user/system installation target.
    flatpak_install_mode="user"
    directory_mode="true"
    if ! flatpak remote-add --user --if-not-exists flathub "$FLATHUB_REPO"; then
      log error "Flathub could not be added to the temporary Flatpak directory"
      return 1
    fi
  fi

  if [[ "$flatpak_version" == "latest" ]]; then # Resolve "latest" version if needed
    log info "Resolving $flatpak_version version for $flatpak_id"
    resolved_flatpak_version=$(get_latest_flatpak_release_version "$flatpak_id")
    if [[ $? -ne 0 || -z "$resolved_flatpak_version" ]]; then
      log error "Failed to resolve latest version"
      return 1
    fi
    log info "Resolved latest version: $resolved_flatpak_version"
  fi

  if [[ "$resolve_version" == "true" ]]; then
    echo "DOWNLOADED_VERSION=$resolved_flatpak_version"
    return 0
  fi
  
  if [[ "$directory_mode" == "true" ]]; then
    final_dest="$FLATPAK_USER_ROOT/app/$flatpak_id/current/$resolved_flatpak_version/files"
  elif [[ "$flatpak_install_mode" == "user" ]]; then
    final_dest="$FLATPAK_USER_ROOT/app/$flatpak_id/current/$resolved_flatpak_version/files"
  elif [[ "$flatpak_install_mode" == "system" ]]; then
    final_dest="$FLATPAK_SYSTEM_ROOT/app/$flatpak_id/current/$resolved_flatpak_version/files"
  else
    log warn "Provided Flatpak destination invalid. Valid options are \"user\" or \"system\". Defaulting to \"$FLATPAK_DEFAULT_INSTALL_MODE\" install type."
    flatpak_install_mode="$FLATPAK_DEFAULT_INSTALL_MODE"
    final_dest="$FLATPAK_USER_ROOT/app/$flatpak_id/current/$resolved_flatpak_version/files"
  fi

  log info "Downloading: $flatpak_id"
  log info "Destination: $final_dest"
  log info "Flatpak Install Mode: $flatpak_install_mode"

  download_cmd() {
    install_flatpak "$flatpak_id" "$resolved_flatpak_version" "$flatpak_install_mode" "app" 2>&1
  }

  if ! try "$max_retries" "$initial_delay" "$max_delay" download_cmd; then
    log error "Download failed: $flatpak_id"
    return 1
  fi

  # Flatpak deploy paths include architecture, branch, and commit. Ask Flatpak
  # for the resolved installation location rather than assuming the layout.
  local install_location
  install_location="$(flatpak info --"$flatpak_install_mode" --show-location "$flatpak_id" 2>/dev/null)" || {
    log error "Could not locate the installed Flatpak ref for $flatpak_id"
    return 1
  }
  final_dest="$install_location/files"

  if [[ "$resolved_flatpak_version" != "latest" ]]; then
    local installed_commit
    installed_commit="$(flatpak info --"$flatpak_install_mode" --show-commit "$flatpak_id" 2>/dev/null)" || {
      log error "Could not determine the installed commit for $flatpak_id"
      return 1
    }
    if [[ "$installed_commit" != "$resolved_flatpak_version" ]]; then
      log error "Requested commit $resolved_flatpak_version for $flatpak_id, but commit $installed_commit is installed"
      return 1
    fi
  fi

  # Verify local Flatpak install exists
  if [[ ! -d "$final_dest" ]]; then
    log error "Flatpak files directory does not exist: $final_dest"
    return 1
  fi

  if [[ "$directory_mode" == "true" ]]; then
    log info "Flatpak app unpacked in temporary directory: $final_dest"
  else
    log info "Flatpak install completed successfully"
  fi
  echo "DOWNLOADED_VERSION=$resolved_flatpak_version"
  echo "DOWNLOADED_FILE=$final_dest"
  return 0
}
