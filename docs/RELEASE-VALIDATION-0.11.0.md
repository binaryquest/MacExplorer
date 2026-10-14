# Explorer 0.11.0 candidate validation

Validated on 14 October 2026 on the maintainer's Apple Silicon Mac. This records pre-release checks; it is not a release announcement.

## Signing and GitHub

- Publisher: Binary Quest Software Pty Ltd, Apple team `B5M99337GK`.
- Identity: `io.bquick.explorer`; candidate version 0.11.0, build 25.
- App and DMG: Developer ID signed, notarized by Apple, stapled, and accepted by Gatekeeper.
- GitHub `release` environment: all six Apple/Sparkle signing secrets and both R2 secrets configured. Exported signing material was validated locally before upload; no secret values are in the repository.
- Sparkle export: signed the candidate DMG and verified against the public key already embedded in Explorer. No new update key was generated.

Candidate DMG SHA-256:

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

The original preferences were restored exactly and the regular Explorer app was reopened. The disposable app and temporary preference backup were removed. All three hosted QA objects were deleted, their exact URLs purged, and HTTP 404 verified. The stable appcast and `latest.json` remain unpublished.

## Coverage and remaining release step

The existing macOS CI run passed 96 Swift tests, 12 release tests, the universal app build, and shell validation. Both workflow files passed actionlint. Automated checks cover deferred relaunch while operations/dialogs are active and signed-content integrity; the interactive upgrade used an idle app.

The actual upgrade ran on Apple Silicon. Intel slices and the macOS 14 deployment target were inspected, but Intel hardware and every supported macOS release have not been exercised. No delta update was tested; releases currently use full DMGs.

The tag-triggered GitHub release job has not run with these secrets yet. After review and merge to `main`, the first version tag will exercise signing/notarization on the hosted runner and publish the verified artifacts and stable feed. No tag, public installer, or GitHub release was created during this validation.
