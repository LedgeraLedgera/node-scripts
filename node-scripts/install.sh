#!/usr/bin/env bash
# Ledgera node installer.
#   ./install.sh <network> --moniker <name> [options]
# See README.md or run with --help.

source "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<EOF
usage: ./install.sh <network> --moniker <name> [options]

networks: $(list_networks)

options:
  --moniker <name>     node name (required)
  --port-prefix <NN>   port prefix, 26656 -> NN656 (default: per network)
  --home <dir>         node home directory (default: per network, under \$HOME)
  --version <tag>      release tag to install (default: what the network runs now)
  --snapshot <url>     restore a data snapshot instead of state sync
  --no-statesync       start from genesis (only useful on very young chains)
  --keep-indexer       keep the tx indexer on (default: off, for validators)
  --strict             refuse binaries without a published checksum
  -y, --yes            do not ask for confirmation
EOF
  exit "${1:-0}"
}

[[ $# -ge 1 ]] || usage 1
case "$1" in -h|--help) usage 0 ;; esac
load_network "$1"; shift

MONIKER="" VERSION="" SNAPSHOT="" HOME_ARG="" PORT_ARG=""
STATESYNC=1 INDEXER="null" STRICT=0 ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --moniker)      MONIKER="${2:?}"; shift 2 ;;
    --port-prefix)  PORT_ARG="${2:?}"; shift 2 ;;
    --home)         HOME_ARG="${2:?}"; shift 2 ;;
    --version)      VERSION="${2:?}"; shift 2 ;;
    --snapshot)     SNAPSHOT="${2:?}"; shift 2 ;;
    --no-statesync) STATESYNC=0; shift ;;
    --keep-indexer) INDEXER="kv"; shift ;;
    --strict)       STRICT=1; shift ;;
    -y|--yes)       ASSUME_YES=1; shift ;;
    -h|--help)      usage 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$MONIKER" ]] || die "--moniker is required"
PORT_PREFIX="${PORT_ARG:-$DEFAULT_PORT_PREFIX}"
NODE_HOME="${HOME_ARG:-$HOME/$DEFAULT_HOME_DIR}"
[[ "$PORT_PREFIX" =~ ^[1-5][0-9]$ ]] || die "--port-prefix must be 10..59"

# ---------------------------------------------------------------- preflight

step "$NAME · $CHAIN_ID"
check_host

[[ ! -e "$NODE_HOME" ]] || die "$NODE_HOME already exists — remove it or pass --home"
if [[ -f "$STATE_DIR/$NETWORK.conf" ]]; then
  die "$NETWORK is already installed — see tools/remove.sh"
fi
if ss -ltn 2>/dev/null | grep -qE ":(${PORT_PREFIX}656|${PORT_PREFIX}657)\b"; then
  die "ports ${PORT_PREFIX}656/${PORT_PREFIX}657 are in use — pick another --port-prefix"
fi

if [[ -z "$VERSION" ]]; then
  if VERSION=$(network_version); then
    info "network is running $VERSION"
  else
    VERSION="$FALLBACK_VERSION"
    warn "could not read the live version from RPC — using $VERSION"
  fi
fi

info "moniker: $MONIKER"
info "home:    $NODE_HOME"
info "ports:   p2p ${PORT_PREFIX}656 · rpc ${PORT_PREFIX}657 · grpc ${PORT_PREFIX}090 · api ${PORT_PREFIX}317"
if [[ -n "$SNAPSHOT" ]]; then info "sync:    snapshot"
elif (( STATESYNC )); then info "sync:    state sync"
else info "sync:    from genesis"; fi

if (( ! ASSUME_YES )); then
  read -r -p "    continue? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "aborted"
fi

# ---------------------------------------------------------------- install

step "system"
require_sudo
install_deps
prepare_host

step "binary"
fetch_binary "$VERSION" "$BIN_DIR/$BINARY"
info "$BINARY $("$BIN_DIR/$BINARY" version 2>&1 | head -n1)"

step "init"
init_out=$("$BIN_DIR/$BINARY" init "$MONIKER" --chain-id "$CHAIN_ID" --home "$NODE_HOME" 2>&1) \
  || die "$BINARY init failed: $init_out"
configure_node
if [[ -f "$NODE_HOME/config/client.toml" ]]; then
  toml_set "$NODE_HOME/config/client.toml" chain-id "\"$CHAIN_ID\""
fi

step "sync"
if [[ -n "$SNAPSHOT" ]]; then
  restore_snapshot "$SNAPSHOT"
elif (( STATESYNC )); then
  configure_statesync
fi

step "service"
save_state
write_service
$SUDO systemctl start "$SERVICE"
sleep 3
systemctl is-active --quiet "$SERVICE" || die "$SERVICE failed to start — journalctl -u $SERVICE -n 50"

step "done"
cat <<EOF
    $NAME node is running as '$SERVICE'.

    logs     journalctl -fu $SERVICE -o cat
    status   bash tools/status.sh $NETWORK
    upgrade  bash tools/upgrade.sh $NETWORK
    node id  $("$BIN_DIR/$BINARY" tendermint show-node-id --home "$NODE_HOME" 2>/dev/null || echo "n/a")

    Back up $NODE_HOME/config/priv_validator_key.json now.
    Create the validator only after status shows catching_up=false.
EOF
