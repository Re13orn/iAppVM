#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

ipa=${1:-build/iOSVM-unsigned.ipa}
log=${2:-build/device-audit/full-regression-$(date +%Y%m%d-%H%M%S).log}
test -f "$ipa" || { echo "Missing IPA: $ipa" >&2; exit 2; }
task_stage=$(mktemp -d)
trap 'rm -rf "$task_stage"' EXIT
ditto -x -k "$ipa" "$task_stage"
shopt -s nullglob
apps=("$task_stage"/Payload/*.app)
[[ ${#apps[@]} -eq 1 ]] || { echo "Expected one app in the IPA" >&2; exit 2; }
app=${apps[0]}

mkdir -p "$(dirname "$log")"
: > "$log"
group_count=0

run_group() {
    local label=$1
    shift
    {
        printf '\n[%s]\n$' "$label"
        printf ' %q' "$@"
        printf '\n'
        "$@"
    } 2>&1 | tee -a "$log"
    group_count=$((group_count + 1))
}

{
    printf 'Regression root: %s\n' "$PWD"
    printf 'IPA: %s\n' "$ipa"
    printf 'App from IPA: %s\n' "$app"
} | tee -a "$log"

run_group scripts/check-console-log-filter.sh \
    bash scripts/check-console-log-filter.sh
run_group scripts/check-frida-download.sh \
    bash scripts/check-frida-download.sh ${IOSVM_FRIDA_DOWNLOAD_NETWORK:+--network}
run_group scripts/check-frida-script-resources.py \
    python3 scripts/check-frida-script-resources.py "$app"
run_group scripts/check-managed-storage.sh \
    bash scripts/check-managed-storage.sh
run_group scripts/check-frida-log-cleaner.sh \
    bash scripts/check-frida-log-cleaner.sh
run_group scripts/check-frida-compatibility.sh \
    bash scripts/check-frida-compatibility.sh
run_group scripts/check-guest-sessions.sh \
    bash scripts/check-guest-sessions.sh
run_group scripts/check-frida-sources.sh \
    bash scripts/check-frida-sources.sh
run_group scripts/check-phone-script-logs.sh \
    bash scripts/check-phone-script-logs.sh
run_group scripts/check-frida-workbench.sh \
    bash scripts/check-frida-workbench.sh
run_group scripts/check-socket-proxy.sh \
    bash scripts/check-socket-proxy.sh
run_group scripts/check-nyxian.sh \
    bash scripts/check-nyxian.sh
run_group scripts/check-sandbox-backups.sh \
    bash scripts/check-sandbox-backups.sh
run_group scripts/check-tls-analysis.sh \
    bash scripts/check-tls-analysis.sh

run_group scripts/check-tls-interception.sh \
    bash scripts/check-tls-interception.sh
run_group scripts/check-tls-review-regressions.sh \
    bash scripts/check-tls-review-regressions.sh
run_group scripts/verify-package.py \
    python3 scripts/verify-package.py "$ipa"
run_group codesign-verify-final-app \
    codesign --verify --deep --strict --verbose=2 "$app"

printf '\nFINAL: %s check groups passed\n' "$group_count" | tee -a "$log"
