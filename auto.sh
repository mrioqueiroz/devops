#!/usr/bin/env bash

set -o errexit
# set -o nounset
set -o pipefail
# set -o xtrace

if [ $# -eq 0 ]; then
    cat << EOF

USAGE:

  $0 generate_config
  $0 init_and_unseal
  $0 inspect_traffic

EOF
fi

NAME="vault"
REPLICAS=3

function generate_config() {
  sudo find ./vault -mindepth 1 ! -regex '.*policies.*' -delete
  mkdir -p vault/policies
  for server in $(seq 1 $REPLICAS); do
    mkdir -p vault/"$server"/{config,data,logs}
    cat << EOF
  $NAME-$server:
    container_name: $NAME-$server
    image: "vault:\${VAULT_VERSION}"
    ports:
      - ${server}8200:8200
    volumes:
      - ./vault/$server:/vault
    environment:
      VAULT_ADDR: "\${VAULT_ADDR}"
    command: server
    cap_add:
      - IPC_LOCK
    networks:
      vault-network:
        ipv4_address: 172.21.0.1$server
        aliases:
          - $NAME-$server
EOF

    cat << EOF > vault/"$server"/config/config.hcl
cluster_name = "local"
api_addr = "http://$NAME-$server:8200"
cluster_addr = "http://$NAME-$server:8201"
listener "tcp" {
  address = "0.0.0.0:8200"
  tls_disable = 1
  # tls_cert_file = "/vault/config/tls/certs/server.pem"
  # tls_key_file = "/vault/config/tls/private/server-key.pem"
  # tls_min_version = "tls12"
}
ui = true
performance_multiplier = 5
disable_mlock = true
storage "raft" {
  path = "/vault/data"
  node_id = "$NAME-$server"
}
EOF

    for retry in $(seq 1 $REPLICAS); do
      if [ "$retry" -ne "$server" ]; then
      cat << EOF >> vault/"$server"/config/config.hcl
retry_join {
  leader_api_addr = "http://$NAME-$retry:8200"
  auto_join_scheme = "http"
  auto_join_port = 8200
}
EOF
      fi
    done

    sudo chmod 777 vault/"$server"/{config,data,logs}
    sudo chmod 664 vault/"$server"/config/config.hcl
  done
}

function wait_for() {
  com=$1
  ATTEMPTS=10
  for _ in $(seq 1 $ATTEMPTS); do
    if eval "$com"; then
      return
    fi
    sleep 1
  done
}

function init_and_unseal() {
  THRESHOLD=3
  docker exec -it "${NAME}-1" vault operator init -key-threshold="$THRESHOLD" | tee keys.txt
  for replica in $(seq 1 "$REPLICAS"); do
    if [ "$replica" -gt 1 ]; then
        wait_for "docker exec -it ${NAME}-1 vault status | grep active"
        docker exec -it "${NAME}-$replica" vault operator raft join "http://${NAME}-1:8200"
    fi
    for key in $(seq 1 "$THRESHOLD"); do
      unseal_key=$(ansifilter keys.txt | grep "Key $key" | cut -d ":" -f 2 | xargs)
      docker exec -it "${NAME}-$replica" vault operator unseal "$unseal_key"
    done
  done
  declare VAULT_TOKEN
  VAULT_TOKEN=$(ansifilter keys.txt | grep "Root Token" | cut -d ":" -f 2 | xargs)
  docker exec --env VAULT_TOKEN="$VAULT_TOKEN" -it "${NAME}-1" vault operator raft list-peers
}

function inspect_traffic() {
  sudo tcpdump -i lo -nnSX port 18200
}

$1
