#!/usr/bin/env bash
# Stop and remove a node installed by these scripts.
#   ./tools/remove.sh <network>           # service + binary, keeps the data directory
#   ./tools/remove.sh <network> --purge   # also deletes the home directory (keys backed up first)

source "$(dirname "$0")/../lib/common.sh"

[[ $# -ge 1 ]] || die "usage: $0 <network> [--purge]   ($(list_networks))"
load_network "$1"
load_state
require_sudo
PURGE=0
if [[ "${2:-}" == "--purge" ]]; then PURGE=1; fi

step "remove $NAME ($SERVICE)"
$SUDO systemctl disable --now "$SERVICE" 2>/dev/null || true
$SUDO rm -f "/etc/systemd/system/$SERVICE.service"
$SUDO systemctl daemon-reload
$SUDO rm -f "$BIN_DIR/$BINARY" "$BIN_DIR/$BINARY.prev"
$SUDO rm -f "$STATE_DIR/$NETWORK.conf"
info "service and binary removed"

if (( PURGE )); then
  backup="$HOME/ledgera-backup-$NETWORK-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup"
  for f in config/priv_validator_key.json config/node_key.json data/priv_validator_state.json; do
    if [[ -f "$NODE_HOME/$f" ]]; then cp -p "$NODE_HOME/$f" "$backup/"; fi
  done
  chmod 700 "$backup"
  info "keys backed up to $backup"

  read -r -p "    type '$NETWORK' to delete $NODE_HOME: " ans
  [[ "$ans" == "$NETWORK" ]] || die "aborted — $NODE_HOME kept"
  rm -rf "$NODE_HOME"
  info "$NODE_HOME deleted"
else
  info "data kept at $NODE_HOME"
fi
