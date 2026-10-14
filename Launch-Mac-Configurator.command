#!/bin/bash
set -euo pipefail
task_source_root="$(cd "$(dirname "$0")" && pwd)"
bash "$task_source_root/MacConfigurator/build.sh"
open "$task_source_root/MacConfigurator/build/PrintDeployGPO.app"
