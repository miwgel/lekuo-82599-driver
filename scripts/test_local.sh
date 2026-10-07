#!/bin/bash
# Run fixtures and a fail-closed helper smoke test, never changing networking.
set -euo pipefail
cd "$(dirname "$0")/.."
workspace="$(mktemp -d "${TMPDIR:-/tmp}/lekuo-control-tests.XXXXXX")"
trap 'python3 - "$workspace" <<"PY"
import pathlib, shutil, sys
path = pathlib.Path(sys.argv[1])
if path.name.startswith("lekuo-control-tests."):
    shutil.rmtree(path)
PY' EXIT

flags=(-parse-as-library -swift-version 5 -strict-concurrency=complete -warnings-as-errors)
xcrun swiftc "${flags[@]}" Lekuo82599App/AdapterService.swift \
    scripts/tests/test_adapter_service.swift -o "$workspace/adapter-tests"
"$workspace/adapter-tests"
xcrun swiftc "${flags[@]}" tools/mtu_protocol.swift tools/mtu_tests.swift \
    -o "$workspace/mtu-tests"
"$workspace/mtu-tests"
xcrun swiftc "${flags[@]}" Lekuo82599App/AdapterService.swift \
    Lekuo82599App/DiagnosticReport.swift scripts/tests/test_control_models.swift \
    -o "$workspace/control-tests"
"$workspace/control-tests"
xcrun swiftc "${flags[@]}" tools/mtu_protocol.swift tools/mtu_watchdog.swift \
    -o "$workspace/watchdog"
python3 - "$workspace/watchdog" <<'PY'
import json, subprocess, sys
result = subprocess.run([sys.argv[1]], input=bytes(32) + b'{}\n',
                        capture_output=True, timeout=5)
reply = json.loads(result.stdout)
assert reply['event'] == 'error'
assert not result.stderr
print('Watchdog rejected invalid authorization before accessing network preferences.')
PY
python3 scripts/check_public_source.py
git diff --check
