#!/usr/bin/env bash

resolve_framework_binary() {
  local framework_path="$1"
  local framework_name="$2"
  local candidates=(
    "$framework_path/Versions/A/$framework_name"
    "$framework_path/Versions/Current/$framework_name"
    "$framework_path/$framework_name"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

# AppleDouble (._*) files break the framework bundle seal: Gatekeeper rejects
# them with "unsealed contents present in the root directory of an embedded
# framework". Signatures are embedded in the Mach-O binaries and _CodeSignature
# directories, so dropping xattrs is safe post-signing.
sanitize_release_payload() {
  local payload_dir="$1"

  find "$payload_dir" -type f \( -name "._*" -o -name ".DS_Store" \) -delete
  xattr -cr "$payload_dir"
}

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
  sanitize_release_payload "$destination_dir"
}
