#!/usr/bin/env bash
set -Eeuo pipefail

: "${WAZUH_ROLE:?WAZUH_ROLE must be supplied by Vagrant}"
: "${WAZUH_DATA_MOUNT:?WAZUH_DATA_MOUNT must be supplied by Vagrant}"

readonly CONFIG_ROOT=/vagrant/config
readonly RUNTIME_ROOT=/opt/wazuh-distributed
readonly SHARED_CERT_DIR=/vagrant/runtime/certs

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "Required file is missing: $1"
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    systemctl start docker
    return
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl start docker
  usermod -aG docker vagrant || true
}

configure_host_networking() {
  local indexer_ip="${WAZUH_INDEXER_IP:-192.168.0.110}"
  local manager_ip="${WAZUH_MANAGER_IP:-192.168.0.111}"
  local dashboard_ip="${WAZUH_DASHBOARD_IP:-192.168.0.112}"

  sed -i '/# wazuh-local-begin/,/# wazuh-local-end/d' /etc/hosts
  sed -i '/wazuh-\(indexer\|manager\|dashboard\)\(\.wazuh\.internal\)\?/d' /etc/hosts
  cat >> /etc/hosts <<EOF
# wazuh-local-begin
$indexer_ip wazuh-indexer.wazuh.internal wazuh-indexer
$manager_ip wazuh-manager.wazuh.internal wazuh-manager
$dashboard_ip wazuh-dashboard.wazuh.internal wazuh-dashboard
# wazuh-local-end
EOF
}

configure_bridge_network() {
  local iface="${WAZUH_BRIDGE_INTERFACE:-eth1}"
  local ip_address="${WAZUH_NODE_IP:-}"
  local netmask="${WAZUH_BRIDGE_NETMASK:-255.255.255.0}"

  [[ -n "$ip_address" ]] || fail "WAZUH_NODE_IP must be supplied for bridged networking"

  sed -i "/#VAGRANT-BEGIN/,/#VAGRANT-END/d" /etc/network/interfaces
  sed -i "/# wazuh-bridge-begin/,/# wazuh-bridge-end/d" /etc/network/interfaces
  cat >> /etc/network/interfaces <<EOF
# wazuh-bridge-begin
auto $iface
iface $iface inet static
      address $ip_address
      netmask $netmask
# wazuh-bridge-end
EOF

  if ip link show "$iface" >/dev/null 2>&1; then
    ifdown "$iface" >/dev/null 2>&1 || true
    ip addr flush dev "$iface" >/dev/null 2>&1 || true
    ifup "$iface" >/dev/null 2>&1 || {
      ip addr add "$ip_address/24" dev "$iface" 2>/dev/null || true
      ip link set "$iface" up
    }
  else
    fail "Bridge interface $iface was not found"
  fi
}

root_disk() {
  local root_source parent
  root_source="$(findmnt -n -o SOURCE /)"
  parent="$(lsblk -n -o PKNAME "$root_source" 2>/dev/null || true)"
  if [[ -n "$parent" ]]; then
    printf '/dev/%s\n' "$parent"
  else
    printf '%s\n' "$root_source"
  fi
}

find_data_disk() {
  local root device type mounted
  root="$(root_disk)"
  for device in /dev/sd? /dev/vd? /dev/xvd?; do
    [[ -b "$device" && "$device" != "$root" ]] || continue
    type="$(lsblk -dn -o TYPE "$device")"
    mounted="$(lsblk -dn -o MOUNTPOINT "$device")"
    # Accept disks that are unmounted, or already mounted at the expected
    # WAZUH_DATA_MOUNT (this can happen if the disk was attached/mounted by
    # a prior run).
    if [[ "$type" != "disk" ]]; then
      continue
    fi
    if [[ -n "$mounted" && "$mounted" != "$WAZUH_DATA_MOUNT" ]]; then
      continue
    fi
    printf '%s\n' "$device"
    return 0
  done
  return 1
}

mount_data_disk() {
  local disk uuid attempts=0
  # If the target mountpoint is already a mount, nothing to do.
  if mountpoint -q "$WAZUH_DATA_MOUNT" 2>/dev/null; then
    log "Data mount $WAZUH_DATA_MOUNT already mounted; skipping disk setup"
    return 0
  fi

  # If the WAZUH_DATA_MOUNT already has a source device, use it.
  if findmnt -n -o SOURCE --target "$WAZUH_DATA_MOUNT" >/dev/null 2>&1; then
    disk_src="$(findmnt -n -o SOURCE --target "$WAZUH_DATA_MOUNT" 2>/dev/null || true)"
    if [[ -n "$disk_src" ]]; then
      parent_dev="$(lsblk -n -o PKNAME "$disk_src" 2>/dev/null || true)"
      if [[ -n "$parent_dev" ]]; then
        disk="/dev/$parent_dev"
      else
        disk="$disk_src"
      fi
    fi
  fi

  if [[ -z "${disk:-}" ]]; then
    until disk="$(find_data_disk)"; do
      attempts=$((attempts + 1))
      (( attempts < 60 )) || fail "No Vagrant data disk was detected"
      sleep 2
    done
  fi

  if ! blkid "$disk" >/dev/null 2>&1; then
    log "Formatting local persistent disk $disk"
    mkfs.ext4 -F "$disk" >/dev/null
  fi
  uuid="$(blkid -s UUID -o value "$disk")"
  install -d -m 0755 "$WAZUH_DATA_MOUNT"
  if ! mountpoint -q "$WAZUH_DATA_MOUNT"; then
    mount "UUID=$uuid" "$WAZUH_DATA_MOUNT"
  fi
  if ! grep -q "UUID=$uuid" /etc/fstab; then
    printf 'UUID=%s %s ext4 defaults,nofail 0 2\n' "$uuid" "$WAZUH_DATA_MOUNT" >> /etc/fstab
  fi
}

copy_base_configuration() {
  require_file "$CONFIG_ROOT/wazuh-version.env"
  require_file "$CONFIG_ROOT/distributed/$WAZUH_ROLE/docker-compose.yml"
  install -d -m 0755 /opt/wazuh /opt/wazuh-config
  cp "$CONFIG_ROOT/wazuh-version.env" /opt/wazuh/wazuh-version.env
  rm -rf /opt/wazuh-config/distributed
  cp -a "$CONFIG_ROOT/distributed" /opt/wazuh-config/distributed
  install -d -m 0755 /opt/wazuh-config/distributed/manager/config/certs
  cp "$CONFIG_ROOT/agent-identity/rootCA.pem" /opt/wazuh-config/distributed/manager/config/certs/rootCA.pem
}

load_wazuh_version() {
  set -a
  # shellcheck disable=SC1091
  . /opt/wazuh/wazuh-version.env
  set +a
}

generate_shared_certificates() {
  if [[ -f "$SHARED_CERT_DIR/.complete" ]]; then
    return
  fi
  log "Generating Wazuh certificates shared by the three local VMs"
  install -d -m 0755 "$SHARED_CERT_DIR"
  rm -rf /opt/wazuh-config/distributed/shared/certs
  (
    cd /opt/wazuh-config/distributed/shared
    cp /opt/wazuh/wazuh-version.env .env
    docker compose -f generate-indexer-certs.yml run --rm generator
  )
  cp -a /opt/wazuh-config/distributed/shared/certs/. "$SHARED_CERT_DIR/"
  chmod 0755 "$SHARED_CERT_DIR"
  find "$SHARED_CERT_DIR" -type f -name '*.pem' -exec chmod 0644 {} +
  find "$SHARED_CERT_DIR" -type f -name '*.key' -exec chmod 0600 {} +
  touch "$SHARED_CERT_DIR/.complete"
}

wait_for_file() {
  local path="$1" attempts=0
  until [[ -f "$path" ]]; do
    attempts=$((attempts + 1))
    (( attempts < 300 )) || fail "Timed out waiting for $path"
    sleep 2
  done
}

wait_for_port() {
  local host="$1" port="$2" attempts=0
  until timeout 3 bash -c "</dev/tcp/$host/$port" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    (( attempts < 180 )) || fail "Timed out waiting for $host:$port"
    sleep 5
  done
}

prepare_runtime() {
  local runtime="$RUNTIME_ROOT/$WAZUH_ROLE"
  rm -rf "$runtime"
  install -d -m 0755 "$runtime"
  cp -a "/opt/wazuh-config/distributed/$WAZUH_ROLE/." "$runtime/"
  cp /opt/wazuh/wazuh-version.env "$runtime/.env"
  cat >> "$runtime/.env" <<EOF
WAZUH_INDEXER_IP=${WAZUH_INDEXER_IP:-192.168.0.110}
WAZUH_MANAGER_IP=${WAZUH_MANAGER_IP:-192.168.0.111}
WAZUH_DASHBOARD_IP=${WAZUH_DASHBOARD_IP:-192.168.0.112}
EOF
  printf '%s\n' "$runtime"
}

copy_certificates() {
  local destination="$1"
  shift
  install -d -m 0755 "$destination"
  local certificate
  for certificate in "$@"; do
    require_file "$SHARED_CERT_DIR/$certificate"
    cp "$SHARED_CERT_DIR/$certificate" "$destination/$certificate"
  done
  find "$destination" -type f -name '*.pem' -exec chmod 0644 {} +
  find "$destination" -type f -name '*.key' -exec chmod 0600 {} +
}

start_indexer() {
  local runtime
  generate_shared_certificates
  install -d -o 1000 -g 1000 -m 0755 "$WAZUH_DATA_MOUNT/data"
  runtime="$(prepare_runtime)"
  case "${WAZUH_LAYOUT:-modern}" in
    legacy)
      export WAZUH_INDEXER_CERTS_PATH=/usr/share/wazuh-indexer/certs
      export WAZUH_INDEXER_OPENSEARCH_CONFIG_PATH=/usr/share/wazuh-indexer/opensearch.yml
      export WAZUH_INDEXER_INTERNAL_USERS_PATH=/usr/share/wazuh-indexer/opensearch-security/internal_users.yml
      ;;
    modern)
      export WAZUH_INDEXER_CERTS_PATH=/usr/share/wazuh-indexer/config/certs
      export WAZUH_INDEXER_OPENSEARCH_CONFIG_PATH=/usr/share/wazuh-indexer/config/opensearch.yml
      export WAZUH_INDEXER_INTERNAL_USERS_PATH=/usr/share/wazuh-indexer/config/opensearch-security/internal_users.yml
      ;;
    *) fail "Unsupported WAZUH_LAYOUT: ${WAZUH_LAYOUT:-}" ;;
  esac
  cat >> "$runtime/.env" <<EOF
WAZUH_INDEXER_CERTS_PATH=$WAZUH_INDEXER_CERTS_PATH
WAZUH_INDEXER_OPENSEARCH_CONFIG_PATH=$WAZUH_INDEXER_OPENSEARCH_CONFIG_PATH
WAZUH_INDEXER_INTERNAL_USERS_PATH=$WAZUH_INDEXER_INTERNAL_USERS_PATH
EOF
  sed -i "s|__WAZUH_INDEXER_CERTS_PATH__|$WAZUH_INDEXER_CERTS_PATH|g" "$runtime/config/wazuh_indexer/wazuh.indexer.yml"
  copy_certificates "$runtime/config/wazuh_indexer_ssl_certs" root-ca.pem wazuh.indexer.pem wazuh.indexer-key.pem admin.pem admin-key.pem
  chown -R 1000:1000 "$runtime"
  (cd "$runtime" && docker compose down || true && docker compose up -d --force-recreate)
}

seed_manager_data() {
  local image="wazuh/wazuh-manager:${WAZUH_VERSION}"
  local directory
  for directory in api-configuration etc logs queue var-multigroups integrations active-response agentless wodles filebeat-etc filebeat-var; do
    install -d -m 0755 "$WAZUH_DATA_MOUNT/$directory"
  done
  if [[ ! -f "$WAZUH_DATA_MOUNT/etc/shared/ar.conf" ]]; then
    log "Seeding the manager's persistent defaults from $image"
    docker pull "$image"
    docker run --rm --entrypoint sh -v "$WAZUH_DATA_MOUNT/etc:/target" "$image" -c 'cp -an /var/ossec/etc/. /target/'
  fi
  chown -R 999:999 "$WAZUH_DATA_MOUNT"
}

start_manager() {
  local runtime
  wait_for_file "$SHARED_CERT_DIR/.complete"
  wait_for_port wazuh-indexer.wazuh.internal 9200
  seed_manager_data
  runtime="$(prepare_runtime)"
  copy_certificates "$runtime/config/certs" root-ca-manager.pem wazuh.manager.pem wazuh.manager-key.pem
  chown -R 999:999 "$runtime"
  (cd "$runtime" && docker compose down || true && docker compose up -d --force-recreate)
}

start_dashboard() {
  local runtime
  wait_for_file "$SHARED_CERT_DIR/.complete"
  wait_for_port wazuh-indexer.wazuh.internal 9200
  wait_for_port wazuh-manager.wazuh.internal 55000
  install -d -o 1000 -g 1000 -m 0755 "$WAZUH_DATA_MOUNT/custom"
  runtime="$(prepare_runtime)"
  copy_certificates "$runtime/config/certs" root-ca.pem wazuh.dashboard.pem wazuh.dashboard-key.pem
  chown -R 1000:1000 "$runtime"
  (cd "$runtime" && docker compose down || true && docker compose up -d --force-recreate)
}

main() {
  require_file "$CONFIG_ROOT/agent-identity/rootCA.pem"
  install_docker
  sysctl -w vm.max_map_count=262144 >/dev/null
  printf 'vm.max_map_count=262144\n' > /etc/sysctl.d/99-wazuh.conf
  configure_bridge_network
  configure_host_networking
  mount_data_disk
  copy_base_configuration
  load_wazuh_version

  case "$WAZUH_ROLE" in
    indexer) start_indexer ;;
    manager) start_manager ;;
    dashboard) start_dashboard ;;
    *) fail "Unknown WAZUH_ROLE: $WAZUH_ROLE" ;;
  esac
  systemctl disable docker docker.socket containerd >/dev/null 2>&1 || true
  log "Wazuh $WAZUH_ROLE is provisioned"
}

main "$@"
