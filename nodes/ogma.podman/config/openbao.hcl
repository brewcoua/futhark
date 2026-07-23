# Server config only — no secrets. TLS cert/key paths are host-mounted by
# ansible/roles/openbao (key material itself is never git-synced).
storage "raft" {
  path    = "/openbao/data"
  node_id = "ogma"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/openbao/tls/openbao.crt"
  tls_key_file  = "/openbao/tls/openbao.key"
}

api_addr      = "https://ogma:8200"
cluster_addr  = "https://ogma:8201"
disable_mlock = true
