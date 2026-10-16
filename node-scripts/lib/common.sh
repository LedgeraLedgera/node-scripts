#!/usr/bin/env bash
# Shared helpers for Ledgera node scripts.
# Sourced by install.sh and tools/*.sh — not meant to be run directly.

set -Eeuo pipefail

LEDGERA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="/etc/ledgera-node"
BIN_DIR="/usr/local/bin"

# ---------------------------------------------------------------- output

if [[ -t 1 ]]; then
  C_DIM=$'\e[2m'; C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_RST=$'\e[0m'
else
  C_DIM=""; C_RED=""; C_GRN=""; C_YLW=""; C_RST=""
fi

step() { printf '\n%s==>%s %s\n' "$C_GRN" "$C_RST" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

trap 'die "line $LINENO: \"$BASH_COMMAND\" exited with $?"' ERR

# ---------------------------------------------------------------- privileges

# Run as the operator user (not root) when possible; sudo is used for
# system paths. Running as root also works — the node then runs as root.
if [[ $EUID -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi
RUN_USER="$(id -un)"

require_sudo() {
  [[ -z "$SUDO" ]] && return 0
  command -v sudo >/dev/null || die "sudo is required when not running as root"
  sudo -v || die "sudo authentication failed"
}

# ---------------------------------------------------------------- network config

# Loads networks/<name>.env into the current shell.
load_network() {
  local name="$1" file="$LEDGERA_ROOT/networks/$1.env"
  [[ -f "$file" ]] || die "unknown network '$name' — available: $(list_networks)"
  # shellcheck source=/dev/null
  source "$file"
  NETWORK="$name"
}

list_networks() {
  local f out=()
  for f in "$LEDGERA_ROOT"/networks/*.env; do out+=("$(basename "$f" .env)"); done
  echo "${out[*]}"
}

# Per-install state (ports, home) so tools/ can find the node later.
save_state() {
  $SUDO mkdir -p "$STATE_DIR"
  $SUDO tee "$STATE_DIR/$NETWORK.conf" >/dev/null <<EOF
NETWORK=$NETWORK
SERVICE=$SERVICE
NODE_HOME=$NODE_HOME
PORT_PREFIX=$PORT_PREFIX
RUN_USER=$RUN_USER
INSTALLED_VERSION=$VERSION
EOF
}

load_state() {
  local file="$STATE_DIR/$NETWORK.conf"
  [[ -f "$file" ]] || die "$NETWORK is not installed by these scripts ($file missing)"
  # shellcheck source=/dev/null
  source "$file"
}

# ---------------------------------------------------------------- host checks

detect_arch() {
  [[ "$(uname -s)" == "Linux" ]] || die "Linux only"
  case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) die "unsupported CPU architecture: $(uname -m)" ;;
  esac
}

check_host() {
  detect_arch

  if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" ]] \
      || warn "tested on Ubuntu 24.04 / Debian 12 — detected ${PRETTY_NAME:-unknown}"
  fi

  local cpus mem_gb disk_gb
  cpus=$(nproc)
  mem_gb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
  disk_gb=$(( $(df -Pk "$HOME" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
  info "host: ${cpus} vCPU · ${mem_gb} GB RAM · ${disk_gb} GB free · $ARCH"

  (( cpus    >= MIN_CPU  )) || warn "recommended at least $MIN_CPU vCPU for $NAME"
  (( mem_gb  >= MIN_RAM_GB - 1 )) || warn "recommended at least $MIN_RAM_GB GB RAM for $NAME"
  (( disk_gb >= MIN_DISK_GB )) || warn "recommended at least $MIN_DISK_GB GB free disk for $NAME"
}

install_deps() {
  local pkgs=(curl jq tar lz4 zstd ca-certificates)
  local missing=() p
  for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if (( ${#missing[@]} )); then
    info "installing: ${missing[*]}"
    $SUDO apt-get update -qq
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
  fi
}

# ---------------------------------------------------------------- RPC helpers

# First RPC from RPC_SERVERS that answers /status for the right chain.
pick_rpc() {
  local rpc net
  for rpc in "${RPC_SERVERS[@]}"; do
    net=$(curl -fsS -m 10 "$rpc/status" 2>/dev/null | jq -r '.result.node_info.network' 2>/dev/null) || continue
    if [[ "$net" == "$CHAIN_ID" ]]; then echo "$rpc"; return 0; fi
  done
  return 1
}

# Version the network is running right now, as a release tag (v1.2.3).
network_version() {
  local rpc ver
  rpc=$(pick_rpc) || return 1
  ver=$(curl -fsS -m 10 "$rpc/abci_info" | jq -r '.result.response.version // empty')
  [[ -n "$ver" && "$ver" != "unknown" ]] || return 1
  echo "v${ver#v}"
}

# ---------------------------------------------------------------- binary

# Downloads the official release asset for $VERSION, verifies its sha256
# against the release checksum file when one is published, and installs
# $BINARY into /usr/local/bin. Uses asset_name / checksum_name from the env file.
fetch_binary() {
  local tag="$1" dest="$2"
  local asset sums url tmp
  asset=$(asset_name "$tag")
  sums=$(checksum_name "$tag")
  url="https://github.com/$GH_REPO/releases/download/$tag"
  tmp=$(mktemp -d)

  info "downloading $asset ($tag)"
  curl -fL --retry 3 -o "$tmp/$asset" "$url/$asset" \
    || die "release asset not found: $url/$asset"

  if [[ -n "$sums" ]] && curl -fsSL -o "$tmp/sums.txt" "$url/$sums" 2>/dev/null; then
    local expected actual
    expected=$(awk -v f="$asset" '$2 == f || $2 == "*"f || $2 ~ "/"f"$" {print $1; exit}' "$tmp/sums.txt")
    actual=$(sha256sum "$tmp/$asset" | awk '{print $1}')
    [[ -n "$expected" ]] || die "$asset is not listed in $sums"
    [[ "$expected" == "$actual" ]] || die "sha256 mismatch for $asset"
    info "sha256 verified"
  else
    if [[ "${STRICT:-0}" == "1" ]]; then die "--strict: no checksum file published for $tag"; fi
    warn "no checksum file published for $tag — binary not verified"
  fi

  local found
  case "$asset" in
    *.tar.gz|*.tgz)
      tar -xzf "$tmp/$asset" -C "$tmp"
      found=$(find "$tmp" -type f -name "$BINARY" -print -quit)
      [[ -n "$found" ]] || die "$BINARY not found inside $asset"
      ;;
    *) found="$tmp/$asset" ;;
  esac

  chmod +x "$found"
  "$found" version >/dev/null 2>&1 || {
    ldd "$found" 2>/dev/null | grep "not found" >&2 || true
    die "$BINARY from $asset does not run on this host"
  }
  $SUDO install -m 0755 "$found" "$dest"
  rm -rf "$tmp"
}

# ---------------------------------------------------------------- config

toml_set() {  # toml_set <file> <key> <value-as-written>  (first match only)
  local file="$1" key="$2" val="$3"
  sed -i -E "0,/^[[:space:]]*${key}[[:space:]]*=.*/s||${key} = ${val}|" "$file"
}

# Moves every default port to <prefix>xxx (26656 -> 27656 for prefix 27).
apply_ports() {
  local p="$PORT_PREFIX" cfg="$NODE_HOME/config"
  sed -i -E \
    -e "s%:26656\"%:${p}656\"%; s%:26657\"%:${p}657\"%; s%:26658\"%:${p}658\"%" \
    -e "s%:26660\"%:${p}660\"%; s%:6060\"%:${p}060\"%" \
    "$cfg/config.toml"
  sed -i -E \
    -e "s%:1317\"%:${p}317\"%; s%:9090\"%:${p}090\"%; s%:9091\"%:${p}091\"%" \
    -e "s%:8545\"%:${p}545\"%; s%:8546\"%:${p}546\"%; s%:6065\"%:${p}065\"%" \
    "$cfg/app.toml"
  if [[ -f "$cfg/client.toml" ]]; then
    sed -i -E "s%^node *=.*%node = \"tcp://localhost:${p}657\"%" "$cfg/client.toml"
  fi
}

configure_node() {
  local cfg="$NODE_HOME/config"

  info "genesis: $GENESIS_URL"
  curl -fsSL --retry 3 -o "$cfg/genesis.json" "$GENESIS_URL"
  jq -e --arg id "$CHAIN_ID" '.chain_id == $id' "$cfg/genesis.json" >/dev/null \
    || die "genesis chain_id does not match $CHAIN_ID"

  toml_set "$cfg/config.toml" seeds "\"$SEEDS\""
  toml_set "$cfg/config.toml" persistent_peers "\"$PEERS\""
  toml_set "$cfg/config.toml" moniker "\"$MONIKER\""
  toml_set "$cfg/config.toml" prometheus "true"
  if [[ "$INDEXER" == "null" ]]; then toml_set "$cfg/config.toml" indexer "\"null\""; fi

  toml_set "$cfg/app.toml" minimum-gas-prices "\"$MIN_GAS_PRICE\""
  toml_set "$cfg/app.toml" pruning "\"custom\""
  toml_set "$cfg/app.toml" pruning-keep-recent "\"100\""
  toml_set "$cfg/app.toml" pruning-interval "\"19\""

  apply_ports
}

# Points CometBFT state sync at two public RPCs, trusting a block ~2000 back.
configure_statesync() {
  local cfg="$NODE_HOME/config/config.toml" rpc latest height hash servers=()
  local r
  for r in "${RPC_SERVERS[@]}"; do
    curl -fsS -m 10 "$r/status" >/dev/null 2>&1 || continue
    if [[ ! "$r" =~ :[0-9]+$ ]]; then
      if [[ "$r" == https://* ]]; then r="$r:443"; else r="$r:80"; fi
    fi
    servers+=("$r")
  done
  (( ${#servers[@]} >= 2 )) || die "state sync needs 2 reachable RPCs — use --snapshot <url> instead"

  rpc="${servers[0]}"
  latest=$(curl -fsS "$rpc/block" | jq -r '.result.block.header.height')
  height=$(( latest - 2000 ))
  hash=$(curl -fsS "$rpc/block?height=$height" | jq -r '.result.block_id.hash')
  [[ "$hash" =~ ^[0-9A-F]{64}$ ]] || die "could not read trust hash from $rpc"

  local list
  list=$(IFS=,; echo "${servers[*]:0:2}")
  sed -i -E "/^\[statesync\]/,/^\[/{
    s|^enable *=.*|enable = true|
    s|^rpc_servers *=.*|rpc_servers = \"$list\"|
    s|^trust_height *=.*|trust_height = $height|
    s|^trust_hash *=.*|trust_hash = \"$hash\"|
  }" "$cfg"
  info "state sync from $list at height $height"
}

# Restores a pruned data snapshot (.tar.lz4 / .tar.zst / .tar.gz) into $NODE_HOME.
restore_snapshot() {
  local url="$1" state="$NODE_HOME/data/priv_validator_state.json" keep=""
  if [[ -f "$state" ]]; then keep=$(mktemp); cp "$state" "$keep"; fi
  rm -rf "$NODE_HOME/data"
  info "streaming $url"
  case "$url" in
    *.lz4) curl -fL "$url" | lz4 -dc - | tar -xf - -C "$NODE_HOME" ;;
    *.zst) curl -fL "$url" | zstd -dc - | tar -xf - -C "$NODE_HOME" ;;
    *.gz)  curl -fL "$url" | tar -xzf - -C "$NODE_HOME" ;;
    *) die "unsupported snapshot format: $url" ;;
  esac
  [[ -d "$NODE_HOME/data" ]] || die "snapshot did not contain a data/ directory"
  if [[ -n "$keep" ]]; then mv "$keep" "$state"; fi
}

# ---------------------------------------------------------------- systemd

write_service() {
  $SUDO tee "/etc/systemd/system/$SERVICE.service" >/dev/null <<EOF
[Unit]
Description=$NAME node ($CHAIN_ID)
After=network-online.target
Wants=network-online.target

[Service]
User=$RUN_USER
ExecStart=$BIN_DIR/$BINARY start --home $NODE_HOME ${START_FLAGS:-}
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable "$SERVICE" >/dev/null 2>&1
}

# Hook defaults — a network env file may override these.
prepare_host() { :; }
