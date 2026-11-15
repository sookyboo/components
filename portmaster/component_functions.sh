#!/bin/bash

_set_setting_value::portmaster() {
  local file="$1" name="$2" value="$3"

  local tmp
  tmp=$(jq --arg key "$name" --arg val "$value" \
    '(.[$key]) |= (if type == "number" then ($val | tonumber) elif type == "boolean" then ($val | test("true")) else $val end)' \
    "$file") && printf '%s\n' "$tmp" > "$file"
}

_get_setting_value::portmaster() {
  local file="$1" name="$2"

  jq -r --arg key "$name" '.[$key]' "$file"
}

_prepare_component::portmaster() {
  local action="$1"
  shift

  local component_config="$(get_own_component_path)/rd_config"

  case "$action" in

    reset)
      log i "----------------------"
      log i "Performing Portmaster $action actions"
      log i "----------------------"

      local portmaster_data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
      local portmaster_install_dir="$portmaster_data_home/PortMaster"
      local portmaster_config="$portmaster_install_dir/config/config.json"
      local config_backup=""

      # Keep the user's PortMaster settings and installed ports while updating
      # the bundled application files.
      if [[ -f "$portmaster_config" ]]; then
        config_backup="$(mktemp)"
        cp -f "$portmaster_config" "$config_backup"
      fi
      create_dir "$portmaster_install_dir"
      if ! unzip -oq "/app/retrodeck/components/portmaster/PortMaster.zip" -d "$portmaster_data_home"; then
        log e "Could not extract the bundled PortMaster release"
        [[ -z "$config_backup" ]] || rm -f "$config_backup"
        return 1
      fi

      if [[ -n "$config_backup" ]]; then
        create_dir "$(dirname "$portmaster_config")"
        cp -f "$config_backup" "$portmaster_config"
        rm -f "$config_backup"
      elif [[ ! -f "$portmaster_config" ]]; then
        create_dir "$(dirname "$portmaster_config")"
        cp -f "$component_config/config.json" "$portmaster_config"
      fi

      # PortMaster's upstream hook assumes /var/data, which is unavailable in
      # the RetroDECK Flatpak. Retarget it to the writable XDG data directory.
      for control_file in \
        "$portmaster_install_dir/control.txt" \
        "$portmaster_install_dir/retrodeck/control.txt"; do
        if [[ -f "$control_file" ]]; then
          sed -i \
            's|export controlfolder="/var/data/PortMaster"|export controlfolder="${XDG_DATA_HOME:-$HOME/.local/share}/PortMaster"|g' \
            "$control_file"
          sed -i \
            '\#^export LD_LIBRARY_PATH="/usr/lib:/lib:/app/retrodeck/components/shared-libs#s|^export LD_LIBRARY_PATH=.*|export LD_LIBRARY_PATH="/usr/lib:/lib:/app/retrodeck/components/shared-libs/org.kde.Sdk/6.11/:/app/retrodeck/components/shared-libs/org.kde.Platform/6.11/:/app/retrodeck/components/shared-libs/org.freedesktop.Platform/25.08/:$LD_LIBRARY_PATH"|' \
            "$control_file"
        fi
      done

      if [[ -f "$portmaster_install_dir/retrodeck/PortMaster.txt" ]]; then
        sed -i \
          's|cp retrodeck/control.txt \$controlfolder|cp "$controlfolder/retrodeck/control.txt" "$controlfolder/control.txt"|' \
          "$portmaster_install_dir/retrodeck/PortMaster.txt"
      fi

      cp -f "$portmaster_install_dir/retrodeck/PortMaster.txt" "$portmaster_install_dir/PortMaster.sh"
      chmod +x "$portmaster_install_dir/PortMaster.sh"
      rm -f "$roms_path/portmaster/PortMaster.sh"
      install -Dm755 "$portmaster_install_dir/PortMaster.sh" "$roms_path/portmaster/PortMaster.sh"
      install -Dm755 "/app/retrodeck/components/portmaster/harbourmaster" "$portmaster_install_dir/harbourmaster"
      create_dir "$portmaster_path"
    ;;

    startup)
      log i "------------------------"
      log i "Performing Portmaster $action actions"
      log i "------------------------"

      log d "Checking if PortMaster should be shown"
      if [[ $(get_component_option "portmaster" "portmaster_show") == "false" ]]; then
        log d "Assuring that PortMaster is hidden on ES-DE"
        portmaster_show "false"
      else
        log d "Assuring that PortMaster is shown on ES-DE"
        portmaster_show "true"
      fi
    ;;

  esac
}

_post_update::portmaster() {
  local previous_version="$1"

}

_post_update_legacy::portmaster() {
  # This function is to cover users upgrading from prior to 0.11.0, when per-component versioning was introduced. It can be removed once we are confident all users are running 0.11.0 or higher
  
  local previous_version="$1"

  if check_version_is_older_than "$previous_version" "0.9.0b"; then
    log i "New components were added in this version, initializing them"
    prepare_component "reset" "portmaster"
  fi

  if check_version_is_older_than "$previous_version" "0.10.0b"; then
    log i "PortMaster was redesigned, re-initializing it"
    prepare_component "reset" "portmaster"
  fi
}

portmaster_show() {
  log d "Setting PortMaster visibility in ES-DE"
  local portmaster_data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
  if [ "$1" = "true" ]; then
    log d "\"$roms_path/portmaster/PortMaster.sh\" is not found, installing it"
    install -Dm755 "$portmaster_data_home/PortMaster/PortMaster.sh" "$roms_path/portmaster/PortMaster.sh" && log d "PortMaster is correctly showing in ES-DE"
    set_component_option "portmaster" "portmaster_show" "true"
  elif [ "$1" = "false" ]; then
    rm -rf "$roms_path/portmaster/PortMaster.sh" && log d "PortMaster is correctly hidden in ES-DE"
    set_component_option "portmaster" "portmaster_show" "false"
  else
    log e "\"$1\" is not a valid choice, quitting"
  fi
}

configurator_portmaster_toggle_dialog() {
  if [[ $(get_component_option "portmaster" "portmaster_show") == "true" ]]; then
    rd_zenity --question \
    --no-wrap --window-icon="/app/share/icons/hicolor/scalable/apps/net.retrodeck.retrodeck.svg" \
    --title "RetroDECK Configurator - PortMaster Visibility" \
    --text="PortMaster is currently <span foreground='$purple'><b>Visible</b></span> in ES-DE. Do you want to hide it?\n\n\<span foreground='$purple'><b>Note: The installed games will still be visible.</b></span>"

    if [ $? == 0 ] # User clicked "Yes"
    then
      portmaster_show "false"
      rd_zenity --info \
      --no-wrap --window-icon="/app/share/icons/hicolor/scalable/apps/net.retrodeck.retrodeck.svg" \
      --title "RetroDECK Configurator - PortMaster Visibility" \
      --text="PortMaster is now <span foreground='$purple'><b>Hidden</b></span> in ES-DE.\n\Please refresh your game list in ES-DE or restart RetroDECK to see the changes.\n\n\To launch PortMaster, you can access it from:\n<span foreground='$purple'><b>Configurator -> Open Component -> PortMaster</b></span>."
    fi
  else
    rd_zenity --question \
    --no-wrap --window-icon="/app/share/icons/hicolor/scalable/apps/net.retrodeck.retrodeck.svg" \
    --title "RetroDECK Configurator - PortMaster Visibility" \
    --text="PortMaster is currently <span foreground='$purple'><b>Hidden</b></span> in ES-DE. Do you want to show it?"

    if [ $? == 0 ] # User clicked "Yes"
    then
      portmaster_show "true"
      rd_zenity --info \
      --no-wrap --window-icon="/app/share/icons/hicolor/scalable/apps/net.retrodeck.retrodeck.svg" \
      --title "RetroDECK Configurator - PortMaster Visibility" \
      --text="PortMaster is now <span foreground='$purple'><b>Visible</b></span> in ES-DE.\nPlease refresh your game list in ES-DE or restart RetroDECK to see the changes."
    fi
  fi
}
