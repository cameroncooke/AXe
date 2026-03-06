#!/usr/bin/env bash

copy_release_payload() {
  local source_dir="$1"
  local destination_dir="$2"

  if [[ ! -f "${source_dir}/axe" ]]; then
    echo "❌ Error: AXe executable missing from ${source_dir}" >&2
    exit 1
  fi

  if [[ ! -d "${source_dir}/Frameworks" ]]; then
    echo "❌ Error: Frameworks directory missing from ${source_dir}" >&2
    exit 1
  fi

  if [[ ! -d "${source_dir}/AXe_AXe.bundle" ]]; then
    echo "❌ Error: AXe resource bundle missing from ${source_dir}" >&2
    exit 1
  fi

  rm -rf "$destination_dir"
  mkdir -p "$destination_dir"
  cp "$source_dir/axe" "$destination_dir/"
  cp -R "$source_dir/Frameworks" "$destination_dir/"
  cp -R "$source_dir/AXe_AXe.bundle" "$destination_dir/"
}
