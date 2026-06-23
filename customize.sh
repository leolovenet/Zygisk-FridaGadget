#!/system/bin/sh

SKIPUNZIP=1
CONFIG_BACKUP="$MODPATH/.config-backup"
CONFIG_FILES="targets.conf module.conf libgadget.config.so"

backup_user_config() {
  local file

  rm -rf "$CONFIG_BACKUP" 2>/dev/null
  mkdir -p "$CONFIG_BACKUP" 2>/dev/null

  for file in $CONFIG_FILES; do
    [ -e "$MODPATH/$file" ] || continue
    cp -af "$MODPATH/$file" "$CONFIG_BACKUP/$file" 2>/dev/null
  done
}

restore_or_create_config() {
  local file

  for file in $CONFIG_FILES; do
    if [ -e "$CONFIG_BACKUP/$file" ]; then
      cp -af "$CONFIG_BACKUP/$file" "$MODPATH/$file" 2>/dev/null
      ui_print "- Preserved existing $file"
    elif [ ! -e "$MODPATH/$file" ] && [ -e "$MODPATH/$file.example" ]; then
      cp -af "$MODPATH/$file.example" "$MODPATH/$file" 2>/dev/null
      ui_print "- Created $file from $file.example"
    fi

    [ -e "$MODPATH/$file" ] && set_perm "$MODPATH/$file" 0 0 0644
    [ -e "$MODPATH/$file.example" ] && set_perm "$MODPATH/$file.example" 0 0 0644
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
