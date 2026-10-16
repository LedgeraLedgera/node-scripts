#!/usr/bin/env bash
# Swap the node binary for a new release and restart.
#   ./tools/upgrade.sh <network>              # version the network runs now
#   ./tools/upgrade.sh <network> <tag>        # a specific release, e.g. at an upgrade height
#   ./tools/upgrade.sh <network> --rollback   # put the previous binary back

source "$(dirname "$0")/../lib/common.sh"

[[ $# -ge 1 ]] || die "usage: $0 <network> [tag|--rollback]   ($(list_networks))"
load_network "$1"
load_state
detect_arch
require_sudo

current="$BIN_DIR/$BINARY"
prev="$BIN_DIR/$BINARY.prev"

if [[ "${2:-}" == "--rollback" ]]; then
  [[ -f "$prev" ]] || die "no previous binary at $prev"
  step "rollback $NAME"
  $SUDO systemctl stop "$SERVICE"
  $SUDO mv "$current" "$current.rollback"
  $SUDO mv "$prev" "$current"
  $SUDO mv "$current.rollback" "$prev"
  $SUDO systemctl start "$SERVICE"
  info "running $("$current" version 2>&1 | head -n1)"
  exit 0
fi

target="${2:-}"
if [[ -z "$target" ]]; then
  target=$(network_version) || die "could not read the live version — pass the tag explicitly"
fi
target="v${target#v}"

running="v$("$current" version 2>&1 | head -n1 | sed 's/^v//')"
if [[ "$running" == "$target" ]]; then
  info "$NAME is already on $target"
  exit 0
fi

step "$NAME $running -> $target"
fetch_binary "$target" "$current.new"

$SUDO systemctl stop "$SERVICE"
$SUDO cp -p "$current" "$prev"
$SUDO mv "$current.new" "$current"
$SUDO systemctl start "$SERVICE"
$SUDO sed -i "s/^INSTALLED_VERSION=.*/INSTALLED_VERSION=$target/" "$STATE_DIR/$NETWORK.conf"

sleep 3
systemctl is-active --quiet "$SERVICE" || {
  warn "$SERVICE did not come back — roll back with: $0 $NETWORK --rollback"
  exit 1
}
info "running $("$current" version 2>&1 | head -n1) · previous binary kept at $prev"
