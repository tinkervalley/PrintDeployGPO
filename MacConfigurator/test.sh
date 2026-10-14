#!/bin/bash
set -euo pipefail
task_source_root="$(cd "$(dirname "$0")/.." && pwd)"
task_test_root="$(mktemp -d "${TMPDIR:-/tmp}/printdeploy-mac-tests.XXXXXX")"
trap 'rm -rf "$task_test_root"' EXIT
cd "$task_source_root"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$task_test_root/cache" \
  MacConfigurator/Sources/DeploymentModel.swift MacConfigurator/Sources/INFModels.swift MacConfigurator/Tests/ModelTests.swift \
  -o "$task_test_root/model-tests"
"$task_test_root/model-tests"
bash MacConfigurator/build.sh "$task_test_root/build"
"$task_test_root/build/PrintDeployGPO.app/Contents/MacOS/PrintDeployGPO" --smoke-test
