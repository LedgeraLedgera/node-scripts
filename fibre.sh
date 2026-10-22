#!/usr/bin/env bash
# Fibre server for a Celestia validator (app version 10+).
# Runs next to a celestia-mocha node installed with install.sh.
#   bash fibre.sh install [--port 7980] [--home <dir>] [-y]
#   bash fibre.sh status
#   bash fibre.sh upgrade
#   bash fibre.sh remove [--purge]

source "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<EOF
usage: bash fibre.sh <command> [options]

commands:
  install     download fibre, wire it to the local node, start it under systemd
  status      service, version, port, on-chain registration
  upgrade     match fibre to the version the local node runs, restart
  remove      stop and remove the service and binary (--purge also deletes data)

install options:
  --port <n>    public fibre port (default 7980)
  --home <dir>  fibre data directory (default ~/.celestia-fibre; a separate disk is recommended)
  -y, --yes     do not ask for confirmation
EOF
  exit "${1:-0}"
}

[[ $# -ge 1 ]] || usage 1
CMD="$1"; shift
case "$CMD" in -h|--help) usage 0 ;; esac

# The consensus node this fibre server belongs to.
load_network "celestia-mocha"
load_state
NODE_BINARY="$BINARY"
NODE_SERVICE="$SERVICE"
NODE_CFG="$NODE_HOME/config"
LOCAL_RPC="http://localhost:${PORT_PREFIX}657"
APP_GRPC="127.0.0.1:${PORT_PREFIX}090"

FIBRE_SERVICE="celestia-fibre"
FIBRE_STATE="$STATE_DIR/fibre.conf"

# Fibre ships in the same celestia-app release as its own archive.
asset_name() {
  local a="x86_64"; [[ "$ARCH" == "arm64" ]] && a="arm64"
  echo "fibre_Linux_${a}.tar.gz"
}
checksum_name() { echo "checksums.txt"; }

node_version() {
  local v
  v=$(curl -fsS -m 5 "$LOCAL_RPC/abci_info" | jq -r '.result.response.version // empty')
  [[ -n "$v" ]] || return 1
  echo "v${v#v}"
}

signer_addr() {
  sed -nE '/^priv_validator_grpc_laddr *=/{s/.*= *"([^"]*)".*/\1/p;q;}' "$NODE_CFG/config.toml"
}

fibre_version() {
  "$BIN_DIR/fibre" version 2>/dev/null | head -n1
}

# ---------------------------------------------------------------- install

cmd_install() {
  local port=7980 fhome="$HOME/.celestia-fibre" yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) port="${2:?}"; shift 2 ;;
      --home) fhome="${2:?}"; shift 2 ;;
      -y|--yes) yes=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || die "--port must be 1..65535"
  [[ ! -f "$FIBRE_STATE" ]] || die "fibre is already installed — bash fibre.sh status"

  step "Fibre · $CHAIN_ID"
  detect_arch
  require_sudo
  install_deps

  local mem_gb
  mem_gb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
  if (( mem_gb < 31 )); then
    warn "fibre's default connection caps assume a 32 GB validator — this host has ${mem_gb} GB"
  fi

  # The node must be up, synced, on app v10+, with gRPC and the privval endpoint on.
  local st
  st=$(curl -fsS -m 5 "$LOCAL_RPC/status") || die "$NODE_SERVICE is not answering on $LOCAL_RPC"
  [[ "$(jq -r '.result.sync_info.catching_up' <<<"$st")" == "false" ]] \
    || die "the node is still syncing — install fibre once bash tools/status.sh celestia-mocha shows synced"

  local appv
  appv=$(curl -fsS -m 5 "$LOCAL_RPC/abci_info" | jq -r '.result.response.app_version // 0')
  (( appv >= 10 )) || die "chain is on app version $appv — fibre needs 10 or later"

  local grpc_section
  grpc_section=$(sed -n '/^\[grpc\]/,/^\[/p' "$NODE_CFG/app.toml")
  grep -qE '^enable *= *true' <<<"$grpc_section" \
    || die "app gRPC is disabled in $NODE_CFG/app.toml ([grpc] enable = true)"

  local signer restart_node=0
  signer=$(signer_addr)
  if [[ -z "$signer" ]]; then
    grep -qE '^priv_validator_grpc_laddr *=' "$NODE_CFG/config.toml" \
      || die "priv_validator_grpc_laddr is missing from config.toml — is the node on celestia-app v10+?"
    signer="127.0.0.1:26669"
    restart_node=1
  fi

  local power
  power=$(jq -r '.result.validator_info.voting_power' <<<"$st")
  if [[ "$power" == "0" ]]; then
    warn "this node has no voting power — fibre gets no storage budget and no traffic until the validator is bonded"
  fi

  if ss -ltn 2>/dev/null | grep -qE ":${port}\b"; then
    die "port $port is already in use — pick another --port"
  fi

  local version
  version=$(node_version) || die "could not read the node version from $LOCAL_RPC"

  info "version:  $version (matches the node)"
  info "home:     $fhome"
  info "listen:   0.0.0.0:$port"
  info "app gRPC: $APP_GRPC"
  info "signer:   $signer"
  if (( restart_node )); then info "node:     privval gRPC will be enabled and $NODE_SERVICE restarted"; fi

  if (( ! yes )); then
    read -r -p "    continue? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || die "aborted"
  fi

  if (( restart_node )); then
    step "node signer endpoint"
    toml_set "$NODE_CFG/config.toml" priv_validator_grpc_laddr "\"$signer\""
    $SUDO systemctl restart "$NODE_SERVICE"
    local i
    for i in $(seq 1 30); do
      curl -fsS -m 2 "$LOCAL_RPC/status" >/dev/null 2>&1 && break
      sleep 2
    done
    info "$NODE_SERVICE restarted with priv_validator_grpc_laddr = $signer"
  fi

  step "binary"
  BINARY="fibre"
  fetch_binary "$version" "$BIN_DIR/fibre"
  info "fibre $(fibre_version)"

  step "service"
  mkdir -p "$fhome"
  $SUDO tee "/etc/systemd/system/$FIBRE_SERVICE.service" >/dev/null <<EOF
[Unit]
Description=Celestia Fibre server ($CHAIN_ID)
After=network-online.target $NODE_SERVICE.service
Wants=network-online.target

[Service]
User=$RUN_USER
ExecStart=$BIN_DIR/fibre start --home $fhome --app-grpc-address $APP_GRPC --server-listen-address 0.0.0.0:$port --signer-grpc-address $signer
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable "$FIBRE_SERVICE" >/dev/null 2>&1
  $SUDO systemctl start "$FIBRE_SERVICE"
  sleep 5
  systemctl is-active --quiet "$FIBRE_SERVICE" \
    || die "$FIBRE_SERVICE failed to start — journalctl -u $FIBRE_SERVICE -n 50"

  $SUDO tee "$FIBRE_STATE" >/dev/null <<EOF
FIBRE_HOME=$fhome
FIBRE_PORT=$port
FIBRE_SIGNER=$signer
EOF

  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  step "done"
  cat <<EOF
    fibre is running as '$FIBRE_SERVICE'.

    1. Open the port to the internet, e.g.:
         sudo ufw allow $port/tcp

    2. Register the public address on-chain (signed with your validator account key):
         $NODE_BINARY tx valaddr set-host ${ip:-<public-ip>}:$port \\
           --from <validator-key> --chain-id $CHAIN_ID --home $NODE_HOME \\
           --node tcp://localhost:${PORT_PREFIX}657 --gas auto --gas-adjustment 1.5 --gas-prices 0.004utia
       Use your public IP or DNS name if ${ip:-this host} is behind NAT.

    3. Check it:
         bash fibre.sh status

    logs: journalctl -fu $FIBRE_SERVICE -o cat
EOF
}

# ---------------------------------------------------------------- status

cmd_status() {
  trap - ERR
  set +e
  [[ -f "$FIBRE_STATE" ]] || die "fibre is not installed — bash fibre.sh install"
  # shellcheck source=/dev/null
  source "$FIBRE_STATE"

  printf '\nFibre · %s\n\n' "$CHAIN_ID"
  if systemctl is-active --quiet "$FIBRE_SERVICE"; then
    printf '  %-14s %s\n' service "${C_GRN}active${C_RST} ($FIBRE_SERVICE)"
  else
    printf '  %-14s %s\n' service "${C_RED}$(systemctl is-active "$FIBRE_SERVICE")${C_RST} — journalctl -u $FIBRE_SERVICE -n 50"
  fi

  local fv nv listen
  fv=$(fibre_version)
  nv=$(node_version)
  printf '  %-14s %s  (node %s)\n' version "${fv:-?}" "${nv:-?}"
  if ss -ltn 2>/dev/null | grep -qE ":${FIBRE_PORT}\b"; then listen="listening"; else listen="${C_RED}not listening${C_RST}"; fi
  printf '  %-14s %s %s\n' port "$FIBRE_PORT" "$listen"
  printf '  %-14s %s\n' signer "$FIBRE_SIGNER"
  printf '  %-14s %s\n\n' home "$FIBRE_HOME"

  local cons
  cons=$("$BIN_DIR/$NODE_BINARY" comet show-address --home "$NODE_HOME" 2>/dev/null)
  if [[ -n "$cons" ]]; then
    printf '  on-chain registration (%s):\n' "$cons"
    "$BIN_DIR/$NODE_BINARY" query valaddr provider "$cons" \
      --node "tcp://localhost:${PORT_PREFIX}657" 2>&1 | sed 's/^/    /'
    echo
  fi

  local recent
  recent=$(journalctl -u "$FIBRE_SERVICE" -n 300 --no-pager -o cat 2>/dev/null \
    | grep -E 'server not ready|health check failed|storage budget is 0|level=(ERROR|WARN)|error' | tail -n 3)
  if [[ -n "$recent" ]]; then
    warn "recent warnings in the fibre log (a failed health check names the cause, e.g. check=registration):"
    sed 's/^/    /' <<<"$recent" >&2
  fi
}

# ---------------------------------------------------------------- upgrade

cmd_upgrade() {
  [[ -f "$FIBRE_STATE" ]] || die "fibre is not installed — bash fibre.sh install"
  detect_arch
  require_sudo

  local target running
  target=$(node_version) || die "could not read the node version from $LOCAL_RPC"
  running="v$(fibre_version | sed 's/^v//')"
  if [[ "$running" == "$target" ]]; then
    info "fibre is already on $target"
    return 0
  fi

  step "fibre $running -> $target"
  BINARY="fibre"
  fetch_binary "$target" "$BIN_DIR/fibre.new"
  $SUDO systemctl stop "$FIBRE_SERVICE"
  $SUDO mv "$BIN_DIR/fibre.new" "$BIN_DIR/fibre"
  $SUDO systemctl start "$FIBRE_SERVICE"
  info "running fibre $(fibre_version)"
  info "new config fields are not added automatically — preview with:"
  info "  $NODE_BINARY config sync --fibre-home <fibre home> --dry-run"
}

# ---------------------------------------------------------------- remove

cmd_remove() {
  [[ -f "$FIBRE_STATE" ]] || die "fibre is not installed"
  # shellcheck source=/dev/null
  source "$FIBRE_STATE"
  require_sudo

  step "remove fibre"
  $SUDO systemctl disable --now "$FIBRE_SERVICE" 2>/dev/null || true
  $SUDO rm -f "/etc/systemd/system/$FIBRE_SERVICE.service" "$BIN_DIR/fibre" "$FIBRE_STATE"
  $SUDO systemctl daemon-reload
  info "service and binary removed"
  info "the on-chain host registration stays — update it with set-host if the server moves"

  if [[ "${1:-}" == "--purge" ]]; then
    read -r -p "    type 'fibre' to delete $FIBRE_HOME: " ans
    [[ "$ans" == "fibre" ]] || die "aborted — $FIBRE_HOME kept"
    rm -rf "$FIBRE_HOME"
    info "$FIBRE_HOME deleted"
  else
    info "data kept at $FIBRE_HOME"
  fi
}

case "$CMD" in
  install) cmd_install "$@" ;;
  status)  cmd_status ;;
  upgrade) cmd_upgrade ;;
  remove)  cmd_remove "$@" ;;
  *) usage 1 ;;
esac
