#!/system/bin/sh

SKIPUNZIP=1
CONFIG_BACKUP="$MODPATH/.config-backup"
CONFIG_FILES="targets.conf module.conf libgadget.config.so gadget/arm64-v8a/libgadget.config.so gadget/armeabi-v7a/libgadget.config.so"
LIVE_MODPATH="/data/adb/modules/zygisk_frida_gadget"

backup_one_config() {
  local source_dir="$1"
  local file="$2"

  [ -e "$source_dir/$file" ] || return 0
  case "$file" in
    */*) mkdir -p "$CONFIG_BACKUP/${file%/*}" 2>/dev/null ;;
  esac
  cp -af "$source_dir/$file" "$CONFIG_BACKUP/$file" 2>/dev/null
}

backup_profile_configs() {
  local source_dir="$1"
  local source file

  for source in \
    "$source_dir"/libgadget-*.config.so \
    "$source_dir"/gadget/arm64-v8a/libgadget-*.config.so \
    "$source_dir"/gadget/armeabi-v7a/libgadget-*.config.so; do
    [ -e "$source" ] || continue
    file=${source#"$source_dir"/}
    backup_one_config "$source_dir" "$file"
  done
}

backup_user_config() {
  local file source_dir

  rm -rf "$CONFIG_BACKUP" 2>/dev/null
  mkdir -p "$CONFIG_BACKUP" 2>/dev/null

  source_dir="$LIVE_MODPATH"
  [ -d "$source_dir" ] || source_dir="$MODPATH"

  for file in $CONFIG_FILES; do
    backup_one_config "$source_dir" "$file"
  done

  backup_profile_configs "$source_dir"
}

restore_or_create_config() {
  local file source

  for file in $CONFIG_FILES; do
    if [ -e "$CONFIG_BACKUP/$file" ]; then
      case "$file" in
        */*) mkdir -p "$MODPATH/${file%/*}" 2>/dev/null ;;
      esac
      cp -af "$CONFIG_BACKUP/$file" "$MODPATH/$file" 2>/dev/null
      ui_print "- Preserved existing $file"
    elif [ ! -e "$MODPATH/$file" ] && [ -e "$MODPATH/$file.example" ]; then
      cp -af "$MODPATH/$file.example" "$MODPATH/$file" 2>/dev/null
      ui_print "- Created $file from $file.example"
    fi

    [ -e "$MODPATH/$file" ] && set_perm "$MODPATH/$file" 0 0 0644
    [ -e "$MODPATH/$file.example" ] && set_perm "$MODPATH/$file.example" 0 0 0644
  done

  for source in \
    "$CONFIG_BACKUP"/libgadget-*.config.so \
    "$CONFIG_BACKUP"/gadget/arm64-v8a/libgadget-*.config.so \
    "$CONFIG_BACKUP"/gadget/armeabi-v7a/libgadget-*.config.so; do
    [ -e "$source" ] || continue
    file=${source#"$CONFIG_BACKUP"/}
    case "$file" in
      */*) mkdir -p "$MODPATH/${file%/*}" 2>/dev/null ;;
    esac
    cp -af "$source" "$MODPATH/$file" 2>/dev/null
    set_perm "$MODPATH/$file" 0 0 0644
    ui_print "- Preserved existing $file"
  done

  rm -rf "$CONFIG_BACKUP" 2>/dev/null
}

ui_print "Installing Zygisk - Frida Gadget"
ui_print "Please make sure Zygisk is enabled in Magisk."

backup_user_config

ui_print "- Extracting module files"
unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2 || abort "! Failed to extract module zip"

set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/deploy_gadget.sh" 0 0 0755
set_perm "$MODPATH/module.prop" 0 0 0644

restore_or_create_config

. "$MODPATH/deploy_gadget.sh"
deploy_gadget "$MODPATH"
