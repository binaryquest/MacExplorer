#!/bin/zsh
set -euo pipefail
set +x
[[ "${GITHUB_ACTIONS:-}" == true ]] || { print -u2 'This helper is only for ephemeral GitHub-hosted runners'; exit 1; }
: "${RUNNER_TEMP:?}" "${CODESIGN_P12_BASE64:?}" "${CODESIGN_P12_PASSWORD:?}"
: "${NOTARY_KEY_P8:?}" "${NOTARY_KEY_ID:?}" "${NOTARY_ISSUER_ID:?}"
KEYCHAIN_PATH="$RUNNER_TEMP/explorer-signing.keychain-db"
KEYCHAIN_PASSWORD=$(openssl rand -hex 32)
export KEYCHAIN_PATH
python3 - <<'PY'
import base64, os
from pathlib import Path
root=Path(os.environ['RUNNER_TEMP'])
for name, content in [('explorer-signing.p12',base64.b64decode(os.environ['CODESIGN_P12_BASE64'],validate=True)),
                      ('explorer-notary.p8',os.environ['NOTARY_KEY_P8'].encode())]:
    path=root/name
    fd=os.open(path, os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
    with os.fdopen(fd,'wb') as output: output.write(content)
PY
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$RUNNER_TEMP/explorer-signing.p12" -P "$CODESIGN_P12_PASSWORD" -t cert -f pkcs12 -k "$KEYCHAIN_PATH" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" > /dev/null
security list-keychains -d user -s "$KEYCHAIN_PATH" "$HOME/Library/Keychains/login.keychain-db"
xcrun notarytool store-credentials explorer-ci --key "$RUNNER_TEMP/explorer-notary.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --keychain "$KEYCHAIN_PATH" > /dev/null
rm -f "$RUNNER_TEMP/explorer-signing.p12" "$RUNNER_TEMP/explorer-notary.p8"
