# Releasing Explorer

Explorer is distributed directly for macOS 14+, as a universal DMG for Apple Silicon and Intel. The app identity is `io.bquick.explorer`, signed by Binary Quest Software Pty Ltd, team `B5M99337GK`.

Local notarization, R2 hosting, and GitHub signing/notarization/Sparkle secrets are configured. An end-to-end update to the 0.11.0 candidate passed through Explorer's native updater on 14 October 2026. See the [validation report](RELEASE-VALIDATION-0.11.0.md) for evidence and remaining coverage limits. No public release tag or stable feed has been published.

## Hosting

- `explorer.bquick.io`: the separate mini-site repository, deployed on Coolify through Cloudflare Tunnel.
- `downloads.bquick.io`: a custom domain connected directly to the dedicated R2 bucket `macexplorer-releases`.
- `https://downloads.bquick.io/explorer/stable/appcast.xml`: Sparkle update feed.
- `https://downloads.bquick.io/explorer/stable/latest.json`: version, download URL, checksum, and release-notes URL for the website.
- `/explorer/releases/<version>/`: immutable DMG, release notes, checksums, and a snapshot of release metadata.

In R2, create the bucket and connect the custom domain using **Settings → Custom Domains**. Keep signing material out of this public bucket. Downloads must work through ordinary HTTPS GET requests without a login or browser challenge. The download hostname serves R2 directly; the site uses the tunnel.

Configure Cloudflare to **bypass cache for `/explorer/stable/*`**. Versioned files are uploaded with a one-year immutable cache policy; stable metadata uses `no-store`. Do not transform the signed XML or release notes. If the website reads `latest.json` from browser JavaScript, allow GET/HEAD from `https://explorer.bquick.io` in the bucket's CORS configuration.

Create R2 S3 credentials with **Object Read & Write** scoped only to this bucket. Save its S3 endpoint from Cloudflare (including the jurisdiction suffix, if any). No account-wide Cloudflare API token is required for routine releases.

### Current hosting configuration

The production bucket uses Standard storage in APAC, the default jurisdiction, and the custom domain with TLS 1.2 or newer. The development `r2.dev` URL is disabled. The [CORS policy](../Support/Release/r2-cors.json) permits the mini-site to read release metadata. The [cache rules](../Support/Release/cache-rules.json) cache versioned files while respecting their origin TTL in both Cloudflare and browsers, and bypass cache for stable metadata. Merge these rules into any existing zone cache ruleset; do not replace unrelated rules.

The account-owned token **MacExplorer releases** has object read/write access to this bucket only. Its S3 credentials are saved in the maintainer's login Keychain as a generic password with service `io.bquick.explorer.release.r2` and account `macexplorer-releases`. That entry contains a JSON object with `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `R2_ENDPOINT`; read it into a process environment without printing it or writing it into the repository.

GitHub's `release` environment contains `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, and the `R2_ENDPOINT` variable. The environment permits version tags matching `v*`; the workflow additionally verifies that the tagged commit belongs to `main`.

The same environment also contains all six Apple and Sparkle secrets listed below. The encrypted PKCS#12 export contains only the Binary Quest Developer ID Application identity; its export password was randomly generated. The notarization API key was validated with Apple, and the exported Sparkle private key signed the candidate DMG and verified against the existing public key. Temporary key exports were removed after secure upload through `gh secret set` on standard input. The original signing keys remain in the maintainer's Keychain.

Public GET/HEAD requests, CORS, uncached metadata, and cached versioned files are checked with harmless temporary objects. The verifier sends an explicit `MacExplorer-ReleaseVerifier` user agent because Cloudflare rejects Python's generic default user agent. Explorer's Sparkle user agent is accepted. A small [hosting check](https://downloads.bquick.io/explorer/health.json) is available independently of releases; the installer and update feed are not published yet.

## Signing and notarization

A Developer ID Application certificate and its private key are required. A Developer ID Installer certificate is **not** needed for DMGs.

For the first local notarization, store a profile interactively:

```sh
xcrun notarytool store-credentials Explorer-Notary \
  --apple-id YOUR_APPLE_ID --team-id B5M99337GK
```

Enter an Apple **app-specific password** at the secure prompt. Alternatively, store an App Store Connect team API key:

```sh
xcrun notarytool store-credentials Explorer-Notary \
  --key /secure/path/AuthKey_KEYID.p8 \
  --key-id YOUR_KEY_ID --issuer YOUR_ISSUER_ID
```

Keep private material outside the repository. The `.gitignore` is a second line of protection, not a place to store credentials. Never paste passwords or private keys into issues, PRs, chat, or shell commands recorded in history.

## Sparkle key

The official public key is embedded in `Support/Info.plist`. Its matching private key was generated in the maintainer's login Keychain under account `io.bquick.explorer`.

After resolving packages, inspect the public key with:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account io.bquick.explorer -p
```

Back up the private key securely. For CI, export it to a private temporary location using `generate_keys --account io.bquick.explorer -x /secure/path/explorer-update-key`, put the file's contents into the `SPARKLE_ED_PRIVATE_KEY` GitHub secret, and remove the temporary export after saving the backup. Do not regenerate the key for each release. Future key rotation requires following Sparkle's migration process.

Forks must use their own publisher, bundle identifier, hosting URLs, and update key.

## GitHub configuration

Create an environment named `release` in `binaryquest/MacExplorer`. Add these **environment secrets** directly in GitHub:

| Secret | Value |
| --- | --- |
| `CODESIGN_P12_BASE64` | Base64 of the exported Developer ID Application certificate **and private key** |
| `CODESIGN_P12_PASSWORD` | Password protecting that `.p12` export |
| `NOTARY_KEY_P8` | Contents of the App Store Connect team API private key |
| `NOTARY_KEY_ID` | That API key's ID |
| `NOTARY_ISSUER_ID` | That team API key's issuer UUID |
| `SPARKLE_ED_PRIVATE_KEY` | Exported Sparkle signing key contents |
| `R2_ACCESS_KEY_ID` | R2 bucket-scoped S3 access key ID |
| `R2_SECRET_ACCESS_KEY` | Matching R2 S3 secret access key |

Add the environment **variable** `R2_ENDPOINT`, e.g. `https://ACCOUNT_ID.r2.cloudflarestorage.com`, using the endpoint Cloudflare provides.

The workflow uses ephemeral GitHub-hosted macOS runners. It imports the certificate into a temporary Keychain, cleans up credentials at the end, and only runs releases on version tags whose commits belong to `main`. Pull requests run tests and development builds without release secrets. The AWS CLI must be available on the release runner.

## Build a local release candidate

Prerequisites: Xcode with Swift 6, Python 3.11+, a valid signing identity, a validated notarization profile, and the Sparkle signing key in Keychain. Quit a running copy before replacing its build output.

```sh
zsh scripts/test.sh
python3 -m unittest discover -s Tests/ReleaseTests -v

export DEVELOPER_ID_APPLICATION='Developer ID Application: Binary Quest Software Pty Ltd (B5M99337GK)'
export NOTARY_PROFILE=Explorer-Notary
zsh scripts/release.sh
```

The script builds both architectures, signs nested helpers and the app with Hardened Runtime and secure timestamps, notarizes and staples the app, creates a DMG with an Applications shortcut, signs/notarizes/staples the DMG, and verifies both Gatekeeper assessment and Sparkle signatures. Results go to `build/releases/<version>/`. This command **does not publish**.

For an existing feed, first run `python3 scripts/release/publish.py prepare build/release-state` with R2 credentials in the AWS CLI environment, and set `PREVIOUS_APPCAST` to `build/release-state/previous-appcast.xml`. CI always does this, preserving previous update entries. A separate credential Keychain can be selected with `NOTARY_KEYCHAIN`.

Regular `zsh scripts/build.sh` builds an ad-hoc signed development app with updates disabled. `--universal` includes both architectures; `--release` enables updates and requires a Developer ID identity. The demo app also keeps updates disabled.

## Publish a release

1. Increase both `CFBundleShortVersionString` and the integer `CFBundleVersion` in `Support/Info.plist`.
2. Add `docs/releases/<version>.md` and merge the tested change to `main`.
3. Create and push the matching tag, for example `v0.11.0` for version `0.11.0`.
4. Watch the **Release Explorer** GitHub Actions workflow.

The job tests, checks version monotonicity against R2, builds and notarizes the DMG, verifies feed/archive signatures against the app's public key, and uploads release artifacts. Every public artifact is downloaded and checksum-verified before the stable metadata is changed. The signed appcast is published last, then a GitHub release is created.

A failure before the stable feed step leaves existing users on the previous release. Existing immutable objects cannot be overwritten with different bytes. Preserve the verified artifact set when retrying a partially uploaded release; rebuilding a signed/notarized DMG can produce different bytes. If the feed was already published but GitHub release creation failed, finish the GitHub release from the saved workflow artifacts instead of rebuilding/re-publishing the same version.

Do not roll back by lowering version or build numbers. Publish a corrected build with a higher version and build number.

## Acceptance checks before the first public release

- Install the notarized DMG through a browser download and confirm Gatekeeper accepts the app.
- Confirm both architecture slices and the macOS 14 minimum; test on Intel hardware before advertising Intel runtime validation.
- Use two notarized test builds and an isolated test feed to verify an actual download, replacement, and relaunch.
- Verify update preferences persist and restarting waits for active file operations.
- Verify preferences, favorites, and tabs migrate from `dev.local.explorer`. Login-item registration is tied to app identity; re-enable it in the new app if needed.
- Test a modified DMG/feed and confirm signature validation rejects it.

No public release should be announced until notarization, the hosted feed, and the actual upgrade test pass.

### Repeating an isolated upgrade check

Use a disposable installed copy with a lower build number, the production bundle identifier and Sparkle public key, and a unique HTTPS test feed. Any changes to its `Info.plist` require signing, notarizing, and stapling that baseline again. Use the exact candidate DMG as the update target. When testing the first release without an older official build, clearly record that the baseline was made from the candidate with a lower version, as in the validation report.

Back up the app's preferences and quit other copies before testing. Put the DMG, release notes, and re-signed appcast under a unique `/explorer/stable/qa/<UUID>/` prefix, which inherits the metadata cache bypass. Verify their HTTPS checksums, then use **Explorer → Check for Updates… → Install Update → Install and Relaunch**. Confirm the new process runs at the same installation path, its version and executable match the candidate, Gatekeeper and the stapled ticket pass, and saved tabs, favorites, and preferences survive.

Afterward, quit the disposable copy, restore the original preferences, remove the temporary objects, purge only their exact URLs, and verify they return HTTP 404. Reopen the regular app. Keep local evidence under `.build/release-evidence/`; never commit preferences or private folder paths. Do not point the stable feed at test builds.

## References

- [Apple Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Sparkle documentation](https://sparkle-project.org/documentation/)
- [Cloudflare R2 custom domains](https://developers.cloudflare.com/r2/buckets/public-buckets/)
- [GitHub signing on macOS runners](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
