#!/usr/bin/env bash
#
# Starts Ecash App as the statecoin demo's sender.
#
# Usage: ./run-sender.sh [--fresh]
#   --fresh  start with a new wallet, e.g. after restarting devimint

exec "$(dirname "${BASH_SOURCE[0]}")/scripts/run-demo-wallet.sh" sender "$@"
