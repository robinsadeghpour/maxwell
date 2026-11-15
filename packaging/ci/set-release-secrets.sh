#!/bin/zsh
# Gives GitHub Actions what release.yml needs to sign and notarize, as secrets of the "release"
# environment. Nothing is printed or left on disk.
#   packaging/ci/set-release-secrets.sh cert             the Developer ID certificate from this Mac's
#                                                        keychain (macOS asks once to allow the export)
#   packaging/ci/set-release-secrets.sh notary <profile> the App Store Connect API key of that asc
#                                                        profile, which notarizes
# Run it again whenever the certificate or the key is replaced.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO=${MAXWELL_REPO:-robinsadeghpour/maxwell}
secret() { gh secret set "$1" --env release -R "$REPO"; }   # reads the value from stdin

case ${1:-} in
  cert)
    dir=$(mktemp -d)
    swiftc -O -o "$dir/export-identity" packaging/ci/export-identity.swift
    export P12_PASSWORD=$(openssl rand -base64 24)
    "$dir/export-identity" | secret MAXWELL_CERT_P12
    printf %s "$P12_PASSWORD" | secret MAXWELL_CERT_PASSWORD
    rm -rf "$dir"
    echo "Set MAXWELL_CERT_P12 and MAXWELL_CERT_PASSWORD on $REPO (environment: release)."
    ;;
  notary)
    profile=${2:?usage: set-release-secrets.sh notary <asc profile>}
    key_id=$(asc auth status --output json | PROFILE=$profile python3 -c \
      'import json,os,sys; print(next(c["keyId"] for c in json.load(sys.stdin)["credentials"] if c["name"]==os.environ["PROFILE"]))')
    p8=${MAXWELL_NOTARY_P8:-$HOME/.appstoreconnect/AuthKey_$key_id.p8}
    [[ -f $p8 ]] || { echo "No $p8: set MAXWELL_NOTARY_P8 to the key's .p8 file."; exit 1; }
    secret MAXWELL_NOTARY_KEY < "$p8"
    printf %s "$key_id" | secret MAXWELL_NOTARY_KEY_ID
    asc --profile "$profile" auth issuer-id | tr -d '\n' | secret MAXWELL_NOTARY_ISSUER
    echo "Set MAXWELL_NOTARY_KEY, MAXWELL_NOTARY_KEY_ID and MAXWELL_NOTARY_ISSUER on $REPO (environment: release)."
    ;;
  *) sed -n '2,8p' "$0"; exit 1 ;;
esac
