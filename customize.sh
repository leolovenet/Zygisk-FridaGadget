#!/system/bin/sh

SKIPUNZIP=0

ui_print "Installing Zygisk - Frida Gadget"
ui_print "Please make sure Zygisk is enabled in Magisk."

set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/deploy_gadget.sh" 0 0 0755

. "$MODPATH/deploy_gadget.sh"
deploy_gadget "$MODPATH"
