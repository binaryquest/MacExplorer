# Explorer 0.11.0 validation

Validated and published on 14 October 2026. This records the local candidate test and the subsequent GitHub-hosted release, with public artifact checks on the maintainer's Apple Silicon Mac.

## Published release

[PR #1](https://github.com/binaryquest/MacExplorer/pull/1) was reviewed and merged as `467b97f8cca46d2099faabfb34d4b731c74406c5`, then tagged `v0.11.0`. The [release workflow](https://github.com/binaryquest/MacExplorer/actions/runs/38517672896) passed on its first run, including tests, signing credential import, app and DMG notarization, signed-feed verification, R2 publication, GitHub release creation, and credential cleanup.

The [published DMG](https://downloads.bquick.io/explorer/releases/0.11.0/MacExplorer-0.11.0.dmg) is 3,425,270 bytes with SHA-256:

```text
30f8053de5103f5b56a64047c3667962bd2761374a42158220608e75a48a27c0
```

The hosted runner rebuilt and signed this artifact, so its checksum differs from the earlier local candidate below. Independent checks after publication confirmed:

- All five versioned R2 files match the saved CI artifacts byte for byte. GitHub release asset digests match R2.
- The signed stable appcast and `latest.json` match their versioned snapshots; CORS and metadata cache bypass work over HTTPS.
- The downloaded DMG and contained app pass code-signature, Gatekeeper, and stapled-ticket checks, with the expected Developer ID publisher and Hardened Runtime.
- Both `arm64` and `x86_64` executable slices target macOS 14.0. The DMG contains the Applications shortcut, and the app enables production updates and signed-feed verification.
- Explorer's native **Check for Updates…** accepts the live production feed and reports 0.11.0 as the newest version.

Download notes and checksum files are also available on the [GitHub release](https://github.com/binaryquest/MacExplorer/releases/tag/v0.11.0).

## Signing and GitHub

- Publisher: Binary Quest Software Pty Ltd, Apple team `B5M99337GK`.
- Identity: `io.bquick.explorer`; candidate version 0.11.0, build 25.
- App and DMG: Developer ID signed, notarized by Apple, stapled, and accepted by Gatekeeper.
- GitHub `release` environment: all six Apple/Sparkle signing secrets and both R2 secrets configured. Exported signing material was validated locally before upload; no secret values are in the repository.
- Sparkle export: signed the candidate DMG and verified against the public key already embedded in Explorer. No new update key was generated.

Earlier local candidate DMG SHA-256:

```text
7f05dde46c5ad6b7c6fc1c55ea42a39ec25784252325ae62c10a94a90b977013
```

## Actual update

The disposable baseline used the candidate's executable with version 0.10.99, build 24, and a unique test feed in its `Info.plist`. It was re-signed, separately notarized, stapled, and accepted by Gatekeeper. This baseline tests full update delivery and replacement; it is not a previously published release or a test of migration between different executable implementations.

The target was the exact, unchanged 0.11.0 DMG identified above. Its signed release notes and a re-signed appcast were staged temporarily over HTTPS on the production R2 custom domain under an isolated QA prefix. The stable feed remained absent.

Through Explorer's own interface, **Check for Updates…** offered 0.11.0, **Install Update** downloaded and prepared it, and **Install and Relaunch** replaced the disposable app. Verification confirmed:

- A new Explorer process at the same test installation path.
- **About Explorer** displayed `Version 0.11.0 (25)`.
- The installed executable and `Info.plist` matched the original release candidate byte for byte.
- Strict nested code-signature verification, Gatekeeper assessment, and staple validation passed after installation.
- Existing Explorer preferences, saved tabs, and favorites were preserved, comparing structured session data rather than JSON serialization order.

The original preferences were restored exactly and the regular Explorer app was reopened. The disposable app and temporary preference backup were removed. All three hosted QA objects were deleted, their exact URLs purged, and HTTP 404 verified. The stable appcast and `latest.json` were still unpublished at the end of this isolated pre-release test.

## Coverage limits

The existing macOS CI run passed 96 Swift tests, 12 release tests, the universal app build, and shell validation. Both workflow files passed actionlint. Automated checks cover deferred relaunch while operations/dialogs are active and signed-content integrity; the interactive upgrade used an idle app.

The actual upgrade ran on Apple Silicon. Intel slices and the macOS 14 deployment target were inspected, but Intel hardware and every supported macOS release have not been exercised. No delta update was tested; releases currently use full DMGs.

The isolated native upgrade used the earlier local candidate. The published CI-built artifact was separately verified as described above; the native production-feed check ran from an existing 0.11.0 installation, so it did not perform another replacement.
