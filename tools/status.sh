#!/usr/bin/env bash
# Node health at a glance.
#   bash tools/status.sh <network>

source "$(dirname "$0")/../lib/common.sh"
trap - ERR
set +e

[[ $# -eq 1 ]] || die "usage: $0 <network>   ($(list_networks))"
load_network "$1"
load_state

local_rpc="http://localhost:${PORT_PREFIX}657"

printf '\n%s · %s\n\n' "$NAME" "$CHAIN_ID"

if systemctl is-active --quiet "$SERVICE"; then
  printf '  %-14s %s\n' service "${C_GRN}active${C_RST} ($SERVICE)"
else
  printf '  %-14s %s\n' service "${C_RED}$(systemctl is-active "$SERVICE")${C_RST} — journalctl -u $SERVICE -n 50"
  exit 1
fi

st=$(curl -fsS -m 5 "$local_rpc/status") || die "local RPC $local_rpc is not answering"
height=$(jq -r '.result.sync_info.latest_block_height' <<<"$st")
catching=$(jq -r '.result.sync_info.catching_up' <<<"$st")
power=$(jq -r '.result.validator_info.voting_power' <<<"$st")
node_id=$(jq -r '.result.node_info.id' <<<"$st")
peers=$(curl -fsS -m 5 "$local_rpc/net_info" | jq -r '.result.n_peers')
local_ver=$(curl -fsS -m 5 "$local_rpc/abci_info" | jq -r '.result.response.version')

net_height="?" net_ver="?"
if ref=$(pick_rpc); then
  net_height=$(curl -fsS -m 10 "$ref/status" | jq -r '.result.sync_info.latest_block_height')
  net_ver=$(curl -fsS -m 10 "$ref/abci_info" | jq -r '.result.response.version')
fi

lag="?"
[[ "$net_height" =~ ^[0-9]+$ ]] && lag=$(( net_height - height ))

if [[ "$catching" == "false" ]]; then sync="${C_GRN}synced${C_RST}"; else sync="${C_YLW}catching up${C_RST}"; fi

printf '  %-14s %s\n' sync "$sync"
printf '  %-14s %s  (network %s, behind %s)\n' height "$height" "$net_height" "$lag"
printf '  %-14s %s\n' peers "$peers"
printf '  %-14s %s  (network %s)\n' version "${local_ver#v}" "${net_ver#v}"
printf '  %-14s %s\n' voting_power "$power"
printf '  %-14s %s@<ip>:%s656\n' node_id "$node_id" "$PORT_PREFIX"
printf '  %-14s %s\n\n' home "$NODE_HOME"

if [[ "$net_ver" != "?" && "${local_ver#v}" != "${net_ver#v}" ]]; then
  warn "version differs from the network — check for a pending upgrade: bash tools/upgrade.sh $NETWORK"
fi
