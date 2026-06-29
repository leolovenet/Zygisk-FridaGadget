#!/system/bin/sh

MODDIR=${0%/*}

echo "[Zygisk - Frida Gadget] redeploy start"
echo

. "$MODDIR/deploy_gadget.sh"
DEPLOY_LOG_STDOUT=0
deploy_gadget "$MODDIR"

echo
echo "[Zygisk - Frida Gadget] deploy result"
echo "----------------------------------------"

if [ -f "$MODDIR/deploy.log" ]; then
  cat "$MODDIR/deploy.log"
else
  echo "deploy.log not found"
fi

echo "----------------------------------------"
echo "[Zygisk - Frida Gadget] done"
