#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) release: dist/nohog-macos.zip + .sha256
# (stable name, so https://github.com/rohiitgit/nohog/releases/latest/download/nohog-macos.zip always works)
#
# Optional, for a public release (needs an Apple Developer account):
#   NOHOG_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"   sign with hardened runtime
#   NOHOG_NOTARY_PROFILE=<profile>   notarize; create once with `xcrun notarytool store-credentials`
# Without them the binary is ad-hoc signed. That runs fine when fetched with curl or built by
# Homebrew (no quarantine flag); only browser downloads need `xattr -d com.apple.quarantine`.
set -euo pipefail
cd "${0:A:h}/.."

version=$(sed -n 's/^let version = "\(.*\)"$/\1/p' Sources/nohog/main.swift)
[[ -n "$version" ]] || { echo "could not read version from Sources/nohog/main.swift" >&2; exit 1; }
strict=(-Xswiftc -warnings-as-errors)

swift test "${strict[@]}"
swift build -c release --arch arm64 --arch x86_64 "${strict[@]}"
bin="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/nohog"
[[ "$(lipo -archs "$bin")" == *x86_64*arm64* || "$(lipo -archs "$bin")" == *arm64*x86_64* ]] || { echo "not a universal binary" >&2; exit 1; }

rm -rf dist && mkdir dist
cp "$bin" dist/nohog
# A stable identifier keeps macOS permission grants (e.g. removable volumes) across signed releases.
if [[ -n "${NOHOG_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --identifier dev.nohog --sign "$NOHOG_SIGN_IDENTITY" dist/nohog
else
  codesign --force --identifier dev.nohog --sign - dist/nohog
  echo "note: ad-hoc signed (no NOHOG_SIGN_IDENTITY)" >&2
fi
codesign --verify --strict dist/nohog
[[ "$(dist/nohog --version)" == "$version" ]] || { echo "version mismatch" >&2; exit 1; }

zip="dist/nohog-macos.zip"
(cd dist && ditto -c -k nohog "${zip:t}")
if [[ -n "${NOHOG_NOTARY_PROFILE:-}" ]]; then
  [[ -n "${NOHOG_SIGN_IDENTITY:-}" ]] || { echo "notarizing needs NOHOG_SIGN_IDENTITY" >&2; exit 1; }
  # A bare executable cannot be stapled; Gatekeeper fetches the ticket online on first launch.
  xcrun notarytool submit "$zip" --keychain-profile "$NOHOG_NOTARY_PROFILE" --wait
fi
(cd dist && shasum -a 256 "${zip:t}" | tee "${zip:t}.sha256")
echo "built $zip ($(lipo -archs dist/nohog))"
