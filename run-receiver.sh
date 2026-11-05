#!/usr/bin/env bash
#
# Starts Ecash App as the statecoin demo's receiver.
#
# Usage: ./run-receiver.sh [--fresh]
#   --fresh  start with a new wallet, e.g. after restarting devimint

exec "$(dirname "${BASH_SOURCE[0]}")/scripts/run-demo-wallet.sh" receiver "$@"
