#!/system/bin/sh

MODDIR=${0%/*}

. "$MODDIR/deploy_gadget.sh"
deploy_gadget "$MODDIR"
