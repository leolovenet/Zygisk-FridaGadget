#!/system/bin/sh

MODDIR=${0%/*}
CONFIG="$MODDIR/targets.conf"

remove_gadget_for_package() {
  local package="$1"
  local apk_path app_dir dir

  apk_path=$(pm path "$package" 2>/dev/null | sed -n 's/^package://p' | head -n 1)
  [ -n "$apk_path" ] || return 0

  app_dir=${apk_path%/*}
  for dir in "$app_dir/lib/arm64" "$app_dir/lib/arm" "$app_dir/lib"; do
    [ -d "$dir" ] || continue
    rm -f "$dir/libgadget.so" "$dir/libgadget.config.so" 2>/dev/null
  done
}

[ -f "$CONFIG" ] || exit 0

while IFS='|' read -r package process match abi; do
  case "$package" in
    ""|\#*) continue ;;
  esac
  remove_gadget_for_package "$package"
done < "$CONFIG"
