#!/bin/sh
set -eu
# Hyper-V KVP pool files; hv_kvp_daemon creates entries the host reads via integration services.
mkdir -p /var/lib/hyperv
exec ./hv_kvp_daemon -n
