#!/bin/bash
# In-container fetch of the CA bundle (Mozilla's roots, as curl.se extracts them), invoked by
# `make cacert`: /etc/ssl/certs/ca-certificates.crt in the image, which Maison's backend trusts for
# the public services it asks (Tempo, the weather). Pinned by its date; its SHA-256 checked against
# the one curl.se publishes next to it.
# Output: /output/cacert.pem
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

CACERT_DATE="${CACERT_DATE:?CACERT_DATE not set}"
NAME="cacert-${CACERT_DATE}.pem"
fetch "$NAME" "https://curl.se/ca/$NAME"
fetch "$NAME.sha256" "https://curl.se/ca/$NAME.sha256"
(cd /dl && sha256sum -c "$NAME.sha256") || { rm -f "/dl/$NAME" "/dl/$NAME.sha256"; exit 1; }
cp "/dl/$NAME" /output/cacert.pem
echo "CA bundle $CACERT_DATE: $(grep -c 'BEGIN CERTIFICATE' /output/cacert.pem) certificates"
