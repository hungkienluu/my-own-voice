#!/usr/bin/env bash

# Keeps SwiftPM/Clang build artifacts inside the workspace so verification can
# run under a workspace-write sandbox.
configure_swiftpm_environment() {
  local root_dir="${ROOT_DIR:-}"
  if [[ -z "$root_dir" ]]; then
    if [[ -f "Package.swift" && -d "Sources" ]]; then
      root_dir="$(pwd)"
    else
      root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    fi
  fi

  local cache_dir="${MY_OWN_VOICE_SWIFTPM_CACHE_DIR:-$root_dir/.build/clang-module-cache}"
  local shared_cache_dir="${MY_OWN_VOICE_SWIFTPM_SHARED_CACHE_DIR:-$root_dir/.build/swiftpm-cache}"
  local config_dir="${MY_OWN_VOICE_SWIFTPM_CONFIG_DIR:-$root_dir/.build/swiftpm-config}"
  local security_dir="${MY_OWN_VOICE_SWIFTPM_SECURITY_DIR:-$root_dir/.build/swiftpm-security}"

  mkdir -p "$cache_dir" "$shared_cache_dir" "$config_dir" "$security_dir"
  export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$cache_dir}"
  SWIFTPM_COMMON_ARGS=(
    "--disable-sandbox"
    "--cache-path" "$shared_cache_dir"
    "--config-path" "$config_dir"
    "--security-path" "$security_dir"
    "--manifest-cache" "local"
  )
}

configure_swiftpm_environment
