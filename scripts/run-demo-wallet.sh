#!/usr/bin/env bash
#
# Starts Ecash App as one wallet of the statecoin demo, with a data directory
# of its own, against the esplora of the devimint federation running in
# ../fedimint. run-sender.sh and run-receiver.sh call this.
#
# Usage: scripts/run-demo-wallet.sh <name> [--fresh]
#   --fresh  start with a new wallet, e.g. after restarting devimint

set -euo pipefail

usage() {
  echo "Usage: $0 <name> [--fresh]" >&2
  exit 1
}

NAME="${1:-}"
[ -n "$NAME" ] || usage

FRESH=false
case "${2:-}" in
  "") ;;
  --fresh) FRESH=true ;;
  *) usage ;;
esac

# The app loads its Rust library from rust/ecashapp/target/release relative to
# the working directory.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

APP=build/linux/x64/debug/bundle/ecashapp
LIB=rust/ecashapp/target/release/libecashapp.so
DATA_DIR="$PWD/demo-data/$NAME"
DEVIMINT_ENV="${DEVIMINT_ENV:-$PWD/../fedimint/target-nix/devimint/env}"

if [ ! -x "$APP" ] || [ ! -f "$LIB" ]; then
  echo "Build the app first: nix develop -c bash -c 'just build-linux && flutter build linux --debug'" >&2
  exit 1
fi

# devimint picks the esplora port at startup and writes it to its env file.
if [ -z "${FM_PORT_ESPLORA:-}" ]; then
  if [ ! -f "$DEVIMINT_ENV" ]; then
    echo "No devimint env at $DEVIMINT_ENV: run 'FM_ENABLE_MODULE_STATECHAIN=1 just devimint-env' in ../fedimint first" >&2
    exit 1
  fi
  FM_PORT_ESPLORA=$(sed -n 's/^export FM_PORT_ESPLORA="\([0-9]*\)"$/\1/p' "$DEVIMINT_ENV")
fi
ESPLORA_URL="http://127.0.0.1:$FM_PORT_ESPLORA"

if ! curl -sf --max-time 5 "$ESPLORA_URL/blocks/tip/height" >/dev/null; then
  echo "Esplora is not answering at $ESPLORA_URL: is devimint running?" >&2
  exit 1
fi

if [ "$FRESH" = true ]; then
  rm -rf "$DATA_DIR"
fi
mkdir -p "$DATA_DIR"

echo "Starting the $NAME (wallet: $DATA_DIR, esplora: $ESPLORA_URL)" >&2
ECASH_APP_DATA_DIR="$DATA_DIR" \
  ECASH_APP_REGTEST_ESPLORA_URL="$ESPLORA_URL" \
  exec "$APP"
