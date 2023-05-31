#!/bin/bash

# $1: IP or domain address of the server

# Need sudo to set permissions
sudo -v

# Check if Docker is installed
docker -v
if [ $? -ne 0 ]; then
    echo "Install Docker first!"
    exit 0
fi

if [ -z "$1" ]; then
    echo "Please provide the external IP address of the server."
    exit 0
fi

# Variables
DOCKER_TLS_CERT_PATH="/etc/docker/tls"
DOCKER_CONFIG_PATH="/etc/systemd/system/docker.service.d"
CA_PASSPHRASE_FILE="ca_passphrase.txt"
SERVER_PASSPHRASE_FILE="server_passphrase.txt"
CLIENT_PASSPHRASE_FILE="client_passphrase.txt"
CERT_SUBJECT="/C=SE/ST=County/L=City/O=Org/OU=IT/CN=${1}"
CERT_ALTNAME="IP:${1},IP:127.0.0.1"

# Create directory for TLS certs
sudo mkdir -p $DOCKER_TLS_CERT_PATH
cd $DOCKER_TLS_CERT_PATH

# Generate passphrases
openssl rand -hex 20 > $DOCKER_TLS_CERT_PATH/$CA_PASSPHRASE_FILE
openssl rand -hex 20 > $DOCKER_TLS_CERT_PATH/$SERVER_PASSPHRASE_FILE
openssl rand -hex 20 > $DOCKER_TLS_CERT_PATH/$CLIENT_PASSPHRASE_FILE

# Generate CA key
echo 01 | sudo tee ca.srl
sudo openssl genrsa -des3 -out ca-key.pem -passout pass:$(cat $DOCKER_TLS_CERT_PATH/$CA_PASSPHRASE_FILE)

# Generate CA certificate
sudo openssl req -new -x509 -days 3650 -key ca-key.pem -out ca.pem -passin pass:$(cat $DOCKER_TLS_CERT_PATH/$CA_PASSPHRASE_FILE) -subj "${CERT_SUBJECT}"

# Generate server key
sudo openssl genrsa -des3 -out server-key.pem -passout pass:$(cat $DOCKER_TLS_CERT_PATH/$SERVER_PASSPHRASE_FILE)

# Generate server certificate signing request
sudo openssl req -new -key server-key.pem -out server.csr -passin pass:$(cat $DOCKER_TLS_CERT_PATH/$SERVER_PASSPHRASE_FILE) -subj "${CERT_SUBJECT}"

# Create configuration file for subject alt name
echo "subjectAltName = ${CERT_ALTNAME}" > extfile.cnf

# Generate server certificate
sudo openssl x509 -req -days 3650 -in server.csr -CA ca.pem \
-CAkey ca-key.pem -out server-cert.pem -extfile extfile.cnf -passin pass:$(cat $DOCKER_TLS_CERT_PATH/$CA_PASSPHRASE_FILE)

# Remove passphrase from server key
sudo openssl rsa -in server-key.pem -out server-key.pem -passin pass:$(cat $DOCKER_TLS_CERT_PATH/$SERVER_PASSPHRASE_FILE)

# Generate client key
sudo openssl genrsa -des3 -out client-key.pem -passout pass:$(cat $DOCKER_TLS_CERT_PATH/$CLIENT_PASSPHRASE_FILE)

# Generate client certificate signing request
sudo openssl req -new -key client-key.pem -out client.csr -passin pass:$(cat $DOCKER_TLS_CERT_PATH/$CLIENT_PASSPHRASE_FILE) -subj "${CERT_SUBJECT}"

# Add extended SSL attributes to client certificate
echo "extendedKeyUsage = clientAuth" >> extfile.cnf

# Generate client certificate
sudo openssl x509 -req -days 3650 -in client.csr -CA ca.pem \
-CAkey ca-key.pem -out client-cert.pem -extfile extfile.cnf -passin pass:$(cat $DOCKER_TLS_CERT_PATH/$CA_PASSPHRASE_FILE)

# Remove passphrase from client key
sudo openssl rsa -in client-key.pem -out client-key.pem -passin pass:$(cat $DOCKER_TLS_CERT_PATH/$CLIENT_PASSPHRASE_FILE)

# Set file permissions
sudo chmod 0600 $DOCKER_TLS_CERT_PATH/server-cert.pem $DOCKER_TLS_CERT_PATH/ca.pem

# Create Docker service directory
sudo mkdir $DOCKER_CONFIG_PATH

# Create configuration file for TLS
echo "[Service]" >> $DOCKER_CONFIG_PATH/override.conf
echo "ExecStart=" >> $DOCKER_CONFIG_PATH/override.conf
echo "ExecStart=/usr/bin/dockerd -H tcp://0.0.0.0:2376 -H fd:// --containerd=/run/containerd/containerd.sock --tlsverify --tlscacert=/etc/docker/tls/ca.pem --tlscert=/etc/docker/tls/server-cert.pem --tlskey=/etc/docker/tls/server-key.pem" >> $DOCKER_CONFIG_PATH/override.conf

# Restart Docker
sudo systemctl --system daemon-reload
sudo systemctl restart docker.service
