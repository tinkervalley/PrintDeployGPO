#!/bin/bash
set -euo pipefail
task_source_root="$(cd "$(dirname "$0")/.." && pwd)"
task_output_dir="${1:-$task_source_root/MacConfigurator/build}"
task_cache_dir="${TMPDIR:-/tmp}/printdeploy-swift-cache"
mkdir -p "$task_output_dir" "$task_cache_dir"
task_app="$task_output_dir/PrintDeployGPO.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources/WindowsBundle"
for task_arch in arm64 x86_64; do
  xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$task_cache_dir" -target "$task_arch-apple-macos13.0" \
    "$task_source_root/MacConfigurator/Sources/DeploymentModel.swift" \
    "$task_source_root/MacConfigurator/Sources/INFModels.swift" \
    "$task_source_root/MacConfigurator/Sources/ConfiguratorApp.swift" \
    "$task_source_root/MacConfigurator/Sources/MacSmoke.swift" \
    -o "$task_output_dir/PrintDeployGPO-$task_arch"
done
lipo -create "$task_output_dir/PrintDeployGPO-arm64" "$task_output_dir/PrintDeployGPO-x86_64" -output "$task_app/Contents/MacOS/PrintDeployGPO"
cp "$task_source_root/MacConfigurator/Info.plist" "$task_app/Contents/Info.plist"
for task_file in PrinterDeployment.ps1 Launch-Configurator.cmd README.md; do cp "$task_source_root/$task_file" "$task_app/Contents/Resources/WindowsBundle/$task_file"; done
for task_folder in Modules Templates; do
  mkdir -p "$task_app/Contents/Resources/WindowsBundle/$task_folder"
  cp "$task_source_root/$task_folder/"* "$task_app/Contents/Resources/WindowsBundle/$task_folder/"
done
codesign --force --sign - "$task_app"
printf 'Built %s\n' "$task_app"
