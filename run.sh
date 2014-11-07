#!/bin/bash
set -e

USAGE="docker run -e GCS_BUCKET=<YOUR_GCS_BUCKET_NAME> \
[-e GCP_ACCOUNT='<YOUR_EMAIL>' ] \
[-e BOTO_PATH='/.config/gcloud/legacy_credentials/<YOUR_EMAIL>/.boto'] \
[-e GCP_OAUTH2_REFRESH_TOKEN=<refresh token>] \
-p 5000:5000 \
[--volumes-from gcloud-config] google/docker-registry"

if [[ -z "${GCS_BUCKET}" ]]; then
  echo "GCS_BUCKET not defined"
  echo
  echo "Usage: $USAGE"
  exit 1
fi

# If a refresh token is passed in directly, use that.
if [[ -n "$GCP_OAUTH2_REFRESH_TOKEN" ]]; then
  cat >/etc/boto.cfg <<EOF
[Credentials]
gs_oauth2_refresh_token = $GCP_OAUTH2_REFRESH_TOKEN
EOF
  BOTO_PATH=/etc/boto.cfg
  echo "Using credentails specified in GCP_OAUTH2_REFRESH_TOKEN env variable"
fi

# Look to see if something is mounted under the /.config dir
if [[ -z "${BOTO_PATH}" ]]; then
  GCP_ACCOUNT=${GCP_ACCOUNT:-$(echo $(grep account /.config/gcloud/properties | cut -d = -f 2))}
  BOTO_PATH=${BOTO_PATH:-$(find /.config/gcloud/legacy_credentials/$GCP_ACCOUNT/.boto)}
fi

if [[ -n "${BOTO_PATH}" ]]; then
  echo "Using credentials in ${BOTO_PATH}"
else
  # fallback on GCE auth
  curl --silent -H 'Metadata-Flavor: Google' \
    http://metadata.google.internal./computeMetadata/v1/instance/service-accounts/default/scopes \
    | grep devstorage > /dev/null
  GCE_SA=$?

  if [[ $GCE_SA -eq 0 ]]; then
    echo "Using credentials from GCE Service Account"
  else
    echo "Boto credentials not found.  Either:"
    echo " - Set GCP_OAUTH2_REFRESH_TOKEN"
    echo " - Set BOTO_PATH"
    echo " - Mount gcloud credentials under /.config in the container and optionally set GCP_ACCOUNT"
    echo " - Run in GCE with a service account configured for devstorage access"
    echo
    echo "$USAGE"
    exit 1
  fi
fi

if [ -n "${REGISTRY_TLS_VERIFY}" ]; then
  set -x
  if ! ls /ssl/ssl.conf; then
      cat <<EOF > /ssl/ssl.conf
[req]
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_ca]
basicConstraints = CA:TRUE
subjectAltName = @alt_names
[v3_req]
basicConstraints = CA:FALSE
subjectAltName = @alt_names
[alt_names]
DNS.1 = localhost
DNS.1 = boot2docker.local
IP.1 = 192.168.59.103
IP.2 = 127.0.0.1
EOF
  fi
  if ! ls /ssl/ca.{key,crt}; then
      echo 01 > /ssl/ca.srl
      openssl req -subj "/CN=${REGISTRY_COMMON_NAME}" -config /ssl/ssl.conf -extensions v3_ca -new -x509 -days 365 -newkey rsa:2048 -nodes -keyout /ssl/ca.key -out /ssl/ca.crt
      openssl req -subj "/CN=${REGISTRY_COMMON_NAME}" -config /ssl/ssl.conf -reqexts v3_req -new -newkey rsa:2048 -nodes -keyout /ssl/server.key -out /ssl/server.csr
      openssl x509 -req -extfile /ssl/ssl.conf -extensions v3_req -days 365 -in /ssl/server.csr -CA /ssl/ca.crt -CAkey /ssl/ca.key -out /ssl/server.cert
      mkdir -p /certs.d/${REGISTRY_COMMON_NAME}
      cp /ssl/ca.crt /certs.d/${REGISTRY_COMMON_NAME}/
  fi
  SSL_VERSION=$(python -c 'import ssl; print ssl.PROTOCOL_TLSv1')
  : ${GUNICORN_OPTS:="['--certfile','/ssl/server.cert','--keyfile','/ssl/server.key','--ca-certs','/ssl/ca.crt','--ssl-version','$SSL_VERSION','--log-level','debug']"}
fi

export GCS_BUCKET BOTO_PATH GUNICORN_OPTS
exec "$@"
