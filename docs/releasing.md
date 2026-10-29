# Releasing Curl Safari

## Local release builds

From the repository root, build and package a universal macOS plugin:

```sh
scripts/build-release.sh 0.1.0
scripts/package-release.sh 0.1.0
```

The version must match the base version in `.codex-plugin/plugin.json`.
The build stages the plugin under `.build/release/stage/curl-safari/`, and the
packaging script writes a ZIP and `SHA256SUMS.txt` to `dist/`.

The archive contains the plugin manifest, skill, assets, a universal
`curl-safari` CLI, and a universal `CurlSafariServer.app`, with both Apple
silicon and Intel binaries. It does not include the repository's local
marketplace metadata. The installation steps in the README apply to a source
checkout; installation from the release archive needs a separate marketplace
setup.

When `.signing-team` exists, the local release app uses Apple Development
signing. Without it, the app uses ad hoc signing. These local builds do not
perform Developer ID signing or notarization.

## GitHub Actions releases

The [release workflow](../.github/workflows/release.yml) runs on version tags
such as `v0.1.0`. It tests the project, builds the universal plugin, signs and
notarizes the runtime, then publishes a GitHub release with the ZIP and checksum.

Configure these repository secrets before creating a release tag:

| Secret | Value |
| --- | --- |
| `APPLE_DEVELOPER_ID_APPLICATION_P12` | Base64-encoded Developer ID Application certificate and private key |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the exported certificate |
| `APPLE_DEVELOPER_ID_APPLICATION` | Full signing identity, such as `Developer ID Application: Example Name (ABCDE12345)` |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarization |
| `APPLE_TEAM_ID` | 10-character Apple developer team ID |

The workflow imports the certificate into a temporary keychain and invokes
`scripts/sign-release.sh`. That script signs the CLI and app, submits them to
Apple's notary service, staples the app's ticket, and verifies the resulting
signatures before packaging.

Before sharing a release, verify installation and the Full Disk Access setup
on a clean Mac using the actual release archive.
