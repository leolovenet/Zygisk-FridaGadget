#!/system/bin/sh

TARGETS_CONFIG="targets.conf"
DEPLOY_LOG=""
SELECTOR_MAX_BYTES=256
DEPLOY_SELECTED=""
DEPLOY_PACKAGES=""

deploy_log() {
  local msg="$1"

  if [ -n "$DEPLOY_LOG" ]; then
    echo "$msg" >> "$DEPLOY_LOG" 2>/dev/null
  fi

  if [ -n "$OUTFD" ]; then
    echo "ui_print $msg" > /proc/self/fd/"$OUTFD"
    echo "ui_print" > /proc/self/fd/"$OUTFD"
  else
    echo "$msg"
  fi
}

valid_match() {
  case "$1" in
    exact|prefix|suffix|contains) return 0 ;;
  esac
  return 1
}

valid_abi() {
  case "$1" in
    auto|arm64-v8a|armeabi-v7a) return 0 ;;
  esac
  return 1
}

trim_field() {
  local value="$1"

  value="${value#"${value%%[!	 ]*}"}"
  value="${value%"${value##*[!	 ]}"}"
  echo "$value"
}

find_ref_so() {
  local dir="$1"
  local file

  for file in "$dir"/*.so; do
    [ -f "$file" ] || continue
    case "$file" in
      */libgadget.so|*/libgadget.config.so) continue ;;
    esac
    echo "$file"
    return 0
  done

  return 1
}

sync_metadata() {
  local dir="$1"
  local so="$dir/libgadget.so"
  local cfg="$dir/libgadget.config.so"
  local ref_so owner group mode

  ref_so=$(find_ref_so "$dir")

  if [ -n "$ref_so" ]; then
    owner=$(stat -c '%U' "$ref_so" 2>/dev/null)
    group=$(stat -c '%G' "$ref_so" 2>/dev/null)
    mode=$(stat -c '%a' "$ref_so" 2>/dev/null)

    [ -n "$owner" ] && [ -n "$group" ] && chown "$owner:$group" "$so" "$cfg" 2>/dev/null
    [ -n "$mode" ] && chmod "$mode" "$so" 2>/dev/null
    chmod 0644 "$cfg" 2>/dev/null

    if command -v chcon >/dev/null 2>&1; then
      chcon --reference="$ref_so" "$so" "$cfg" 2>/dev/null
    fi
  else
    chmod 0755 "$so" 2>/dev/null
    chmod 0644 "$cfg" 2>/dev/null
    if command -v restorecon >/dev/null 2>&1; then
      restorecon "$so" "$cfg" 2>/dev/null
    fi
  fi
}

find_gadget_so_in_dir() {
  local dir="$1"
  local file found count target selector_size

  if [ -L "$dir/libgadget.so" ]; then
    target=$(readlink "$dir/libgadget.so" 2>/dev/null)
    [ -n "$target" ] || {
      deploy_log "- libgadget.so symlink is unreadable in $dir"
      return 1
    }

    case "$target" in
      /*) ;;
      *) target="$dir/$target" ;;
    esac

    [ -f "$target" ] || {
      deploy_log "- libgadget.so symlink target not found: $target"
      return 1
    }

    echo "$target"
    return 0
  fi

  if [ -f "$dir/libgadget.so" ]; then
    selector_size=$(stat -c '%s' "$dir/libgadget.so" 2>/dev/null)
    if [ -n "$selector_size" ] && [ "$selector_size" -gt 0 ] && [ "$selector_size" -le "$SELECTOR_MAX_BYTES" ]; then
      target=$(cat "$dir/libgadget.so" 2>/dev/null)
      case "$target" in
        /*) ;;
        *) target="$dir/$target" ;;
      esac

      [ -f "$target" ] || {
        deploy_log "- libgadget.so selector target not found: $target"
        return 1
      }

      echo "$target"
      return 0
    fi

    echo "$dir/libgadget.so"
    return 0
  fi

  found=""
  count=0
  for file in "$dir"/libgadget-*.so "$dir"/frida-gadget-*.so; do
    [ -f "$file" ] || continue
    found="$file"
    count=$((count + 1))
  done

  if [ "$count" -eq 1 ]; then
    ln -s "$(basename "$found")" "$dir/libgadget.so" 2>/dev/null
    echo "$found"
    return 0
  fi

  if [ "$count" -gt 1 ]; then
    deploy_log "- Multiple Gadget files found in $dir; select one with libgadget.so symlink"
  fi

  return 1
}

gadget_source_so() {
  local moddir="$1"
  local abi="$2"
  local so

  case "$abi" in
    arm64-v8a)
      so=$(find_gadget_so_in_dir "$moddir/gadget/arm64-v8a") && echo "$so" && return 0
      ;;
    armeabi-v7a)
      so=$(find_gadget_so_in_dir "$moddir/gadget/armeabi-v7a") && echo "$so" && return 0
      ;;
  esac

  so=$(find_gadget_so_in_dir "$moddir/gadget/arm64-v8a") && echo "$so" && return 0
  so=$(find_gadget_so_in_dir "$moddir/gadget/armeabi-v7a") && echo "$so" && return 0
  so=$(find_gadget_so_in_dir "$moddir") && echo "$so" && return 0

  return 1
}

gadget_config_for_so() {
  local moddir="$1"
  local gadget_so="$2"
  local src_dir

  src_dir=${gadget_so%/*}
  [ -f "$src_dir/libgadget.config.so" ] && echo "$src_dir/libgadget.config.so" && return 0
  [ -f "$moddir/libgadget.config.so" ] && echo "$moddir/libgadget.config.so" && return 0

  return 1
}

copy_to_lib_dir() {
  local moddir="$1"
  local package="$2"
  local lib_dir="$3"
  local source_abi="$4"
  local gadget_so gadget_config

  gadget_so=$(gadget_source_so "$moddir" "$source_abi") || {
    deploy_log "- Gadget file not found for $package abi=$source_abi"
    return 1
  }

  gadget_config=$(gadget_config_for_so "$moddir" "$gadget_so") || {
    deploy_log "- libgadget.config.so not found for $package abi=$source_abi"
    return 1
  }

  cp -f "$gadget_so" "$lib_dir/libgadget.so" || {
    deploy_log "- Failed to copy Gadget to $lib_dir"
    return 1
  }

  cp -f "$gadget_config" "$lib_dir/libgadget.config.so" || {
    deploy_log "- Failed to copy Gadget config to $lib_dir"
    return 1
  }

  sync_metadata "$lib_dir"
  deploy_log "- Gadget deployed for $package abi=$source_abi to $lib_dir"
  return 0
}

cleanup_extra_dirs() {
  local selected="$1"
  local app_dir="$2"
  local dir

  for dir in "$app_dir/lib/arm64" "$app_dir/lib/arm" "$app_dir/lib"; do
    [ -d "$dir" ] || continue
    case "$selected" in
      *"|$dir|"*) continue ;;
    esac
    rm -f "$dir/libgadget.so" "$dir/libgadget.config.so" 2>/dev/null
  done
}

record_package() {
  local package="$1"

  [ -n "$DEPLOY_PACKAGES" ] || return 0
  [ -f "$DEPLOY_PACKAGES" ] || return 0

  if grep -Fqx "$package" "$DEPLOY_PACKAGES" 2>/dev/null; then
    return 0
  fi

  echo "$package" >> "$DEPLOY_PACKAGES" 2>/dev/null
}

record_selected_dir() {
  local package="$1"
  local app_dir="$2"
  local lib_dir="$3"

  [ -n "$DEPLOY_SELECTED" ] || return 0
  [ -f "$DEPLOY_SELECTED" ] || return 0

  echo "$package|$app_dir|$lib_dir" >> "$DEPLOY_SELECTED" 2>/dev/null
}

cleanup_deployed_packages() {
  local package app_dir lib_dir selected line

  [ -n "$DEPLOY_PACKAGES" ] || return 0
  [ -n "$DEPLOY_SELECTED" ] || return 0
  [ -f "$DEPLOY_PACKAGES" ] || return 0
  [ -f "$DEPLOY_SELECTED" ] || return 0

  while IFS= read -r package; do
    [ -n "$package" ] || continue
    app_dir=""
    selected="|"

    while IFS='|' read -r line_package line_app_dir line_lib_dir; do
      [ "$line_package" = "$package" ] || continue
      [ -n "$line_app_dir" ] || continue
      [ -n "$line_lib_dir" ] || continue
      app_dir="$line_app_dir"
      case "$selected" in
        *"|$line_lib_dir|"*) ;;
        *) selected="$selected$line_lib_dir|" ;;
      esac
    done < "$DEPLOY_SELECTED"

    [ -n "$app_dir" ] || continue
    cleanup_extra_dirs "$selected" "$app_dir"
  done < "$DEPLOY_PACKAGES"
}

deploy_one_target() {
  local moddir="$1"
  local package="$2"
  local process="$3"
  local match="$4"
  local abi="$5"
  local apk_path app_dir selected

  : "$process"


  valid_match "$match" || {
    deploy_log "- Invalid match for $package: $match"
    return 0
  }

  valid_abi "$abi" || {
    deploy_log "- Invalid abi for $package: $abi"
    return 0
  }

  apk_path=$(pm path "$package" 2>/dev/null | sed -n 's/^package://p' | head -n 1)
  [ -n "$apk_path" ] || {
    deploy_log "- Target package not found: $package"
    return 0
  }

  app_dir=${apk_path%/*}
  selected="|"

  if [ "$abi" = "auto" ]; then
    if [ -d "$app_dir/lib/arm64" ] && copy_to_lib_dir "$moddir" "$package" "$app_dir/lib/arm64" "arm64-v8a"; then
      selected="$selected$app_dir/lib/arm64|"
      record_selected_dir "$package" "$app_dir" "$app_dir/lib/arm64"
    fi

    if [ -d "$app_dir/lib/arm" ] && copy_to_lib_dir "$moddir" "$package" "$app_dir/lib/arm" "armeabi-v7a"; then
      selected="$selected$app_dir/lib/arm|"
      record_selected_dir "$package" "$app_dir" "$app_dir/lib/arm"
    fi

    if [ "$selected" = "|" ] && [ -d "$app_dir/lib" ] && copy_to_lib_dir "$moddir" "$package" "$app_dir/lib" "auto"; then
      selected="$selected$app_dir/lib|"
      record_selected_dir "$package" "$app_dir" "$app_dir/lib"
    fi
  elif [ "$abi" = "arm64-v8a" ]; then
    if [ -d "$app_dir/lib/arm64" ] && copy_to_lib_dir "$moddir" "$package" "$app_dir/lib/arm64" "$abi"; then
      selected="$selected$app_dir/lib/arm64|"
      record_selected_dir "$package" "$app_dir" "$app_dir/lib/arm64"
    fi
  elif [ "$abi" = "armeabi-v7a" ]; then
    if [ -d "$app_dir/lib/arm" ] && copy_to_lib_dir "$moddir" "$package" "$app_dir/lib/arm" "$abi"; then
      selected="$selected$app_dir/lib/arm|"
      record_selected_dir "$package" "$app_dir" "$app_dir/lib/arm"
    fi
  fi

  [ "$selected" != "|" ] || {
    deploy_log "- Target native lib directory or matching Gadget ABI not found: $package abi=$abi"
    return 0
  }

  record_package "$package"
}

deploy_gadget() {
  local moddir="$1"
  local config="$moddir/$TARGETS_CONFIG"
  local package process match abi extra

  DEPLOY_LOG="$moddir/deploy.log"
  DEPLOY_SELECTED="$moddir/deploy.selected"
  DEPLOY_PACKAGES="$moddir/deploy.packages"
  : > "$DEPLOY_LOG" 2>/dev/null
  : > "$DEPLOY_SELECTED" 2>/dev/null
  : > "$DEPLOY_PACKAGES" 2>/dev/null
  chmod 0644 "$DEPLOY_LOG" 2>/dev/null

  [ -f "$config" ] || {
    deploy_log "- targets.conf not found"
    return 0
  }

  while IFS='|' read -r package process match abi extra; do
    package=$(trim_field "$package")
    process=$(trim_field "$process")
    match=$(trim_field "$match")
    abi=$(trim_field "$abi")
    extra=$(trim_field "$extra")

    case "$package" in
      ""|\#*) continue ;;
    esac

    [ -n "$package" ] || continue
    [ -n "$process" ] || process="$package"
    [ -n "$match" ] || match="exact"
    [ -n "$abi" ] || abi="auto"

    if [ -n "$extra" ]; then
      deploy_log "- Invalid targets.conf line for $package: too many fields"
      continue
    fi

    deploy_one_target "$moddir" "$package" "$process" "$match" "$abi"
  done < "$config"

  cleanup_deployed_packages
  rm -f "$DEPLOY_SELECTED" "$DEPLOY_PACKAGES" 2>/dev/null
}
