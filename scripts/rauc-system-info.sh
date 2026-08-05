#!/usr/bin/env bash
# system-info.sh - RAUC system-info handler.
#
# Reports the Arasaka system version to RAUC so it can be shown in
# `rauc status` and compared against bundle versions. The version comes from
# the baked-in /etc/arasaka/version (written by the CI build) and reflects
# the installed image date/run.
set -euo pipefail

if [ -f /etc/arasaka/version ]; then
    printf 'RAUC_SYSTEM_VERSION=%s\n' "$(cat /etc/arasaka/version)"
fi

printf 'RAUC_SYSTEM_SERIAL=arasaka-x86_64\n'
