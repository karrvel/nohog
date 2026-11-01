# nohog

Keeps Spotlight from indexing dev junk (`node_modules`, `target`, `Pods`, `venv`, …), so `mds_stores` stops eating CPU, without turning Spotlight off. Install once and it keeps itself up to date: new clones, new `npm install`s, plugged-in drives, macOS updates.

No sudo, no Full Disk Access. macOS 13 or later, Apple Silicon or Intel.

## Install

**Homebrew** (recommended; builds from source, and the agent keeps running across upgrades):

```
brew tap rohiitgit/nohog https://github.com/rohiitgit/nohog
brew install nohog
brew services start nohog
```

**Prebuilt binary** (universal, Apple Silicon + Intel):

```
curl -fsSL https://github.com/rohiitgit/nohog/releases/latest/download/nohog-macos.zip -o /tmp/nohog.zip
unzip -o /tmp/nohog.zip -d /tmp && /tmp/nohog install    # copies itself to ~/.local/bin, starts the agent
```

Releases are built by GitHub Actions and ad-hoc signed, not notarized (no paid Apple account).
`curl` downloads run fine. If you download the zip **in a browser** instead, macOS blocks it until you
clear the quarantine flag: `xattr -d com.apple.quarantine nohog`.

**From source** (Command Line Tools with Swift 6 is enough):

```
git clone https://github.com/rohiitgit/nohog && cd nohog
swift build -c release && .build/release/nohog install
```

Before it starts anything, `install` runs a selftest that excludes a probe folder and checks that Spotlight really skips it. If your macOS doesn't honor exclusions, it refuses to install.

If macOS asks whether nohog may access a removable volume (for code on an external drive), click **Allow**. Because builds are ad-hoc signed, macOS may ask again after an upgrade.

## How it decides what to exclude

1. **It walks your dev folders**, up to 8 levels deep. It doesn't follow symlinks or enter app bundles. Default folders, where they exist:
   - `~/Developer`, `~/Projects`, `~/Code`, `~/src`, `~/dev`, `~/git`, `~/repos`, `~/workspace`, `~/GitHub`
   - `/Volumes/*/Developer` on any drive
2. **A folder is junk only if its name and a sibling file both match.** A `target` folder with no `Cargo.toml` or `pom.xml` next to it stays searchable:

   | folder | needs a sibling |
   |---|---|
   | `node_modules` | `package.json` |
   | `bower_components` | `bower.json` |
   | `target` | `Cargo.toml` or `pom.xml` |
   | `venv` | `pyproject.toml`, `requirements.txt`, `setup.py` or `Pipfile` |
   | `Pods` / `Carthage` | `Podfile` / `Cartfile` |
   | `build` | `build.gradle*`, `settings.gradle*`, `CMakeLists.txt` or `pubspec.yaml` |
   | `vendor` | `composer.json` or `go.mod` |
   | `_build`, `deps` | `mix.exs` |
   | `bin`, `obj` | `*.csproj` or `*.fsproj` |
   | `dist-newstyle` | `cabal.project` or `*.cabal` |
   | `elm-stuff` | `elm.json` |
   | `zig-out`, `zig-cache` | `build.zig` |
   | `Library` (Unity) | a `ProjectSettings` folder |

3. **It adds tool caches outside projects:** `~/Library/Developer/Xcode/DerivedData` and `~/go/pkg/mod`.
4. **It skips what Spotlight already ignores:** folders starting with `.` (`.venv`, `.next`, `.gradle`, `~/.m2`, `~/.npm`) and `*.noindex`.

Something that hogs Spotlight but isn't on this list? Run `sudo nohog top` to find it, then add it to the config (below).

## How it stays up to date

- **The exclusion list:** nohog writes to the same **Search Privacy** list as System Settings, using the private `_MDSetExclusion` / `_MDCopyExclusionList` calls in Metadata.framework.
  - Changes apply immediately, and content that was already indexed is purged.
  - On current macOS, editing `VolumeConfiguration.plist` and `.metadata_never_index` files have no effect.
- **The background agent reconciles:**
  - at login, which covers the reboot after a macOS update;
  - within ~3 s of a junk folder appearing (FSEvents);
  - when a drive mounts;
  - hourly.
- **After every macOS update** it re-runs the selftest. If exclusions ever stop working, it notifies you and pauses itself instead of guessing.

## Safety

- **Your own exclusions are never touched.** nohog only removes what it added (`~/Library/Application Support/nohog/state.json`). That record is derived from what Spotlight reports after each change, not from what nohog requested.
- **It only prunes what it actually looked at.** An unplugged drive, a denied permission or an unreadable folder never causes an un-exclude.
- **Every change is verified.** mds drops requests while it is busy purging a big folder, so missing changes are re-sent with backoff.

## Commands

```
nohog install / uninstall              start the agent / stop it and remove every exclusion nohog added
nohog status                           exclusions marked [nohog] or [yours], and whether the agent runs
nohog scan [--count] [root...]         list junk folders (with file counts)
nohog reconcile [--dry-run]            apply now / preview
nohog selftest                         prove exclusions work on this macOS (10-35 s)
sudo nohog top [seconds] [--depth N]   which folders Spotlight is reading right now
nohog --version
```

Log: `~/Library/Logs/nohog.log`, one line per change.

Homebrew users stop with `brew services stop nohog && nohog uninstall`.

## Config (optional): `~/.config/nohog/config.json`

Re-read on every reconcile, so there's no restart needed. Every field is optional.

```json
{
  "roots": ["~/Developer", "~/Documents/GitHub", "/Volumes/*/Developer"],
  "extraPaths": ["~/Developer/myapp/data/cache"],
  "extraRules": [{ "name": "dist", "sentinels": ["package.json"] }],
  "skipPaths": ["~/Developer/keep-searchable"],
  "maxDepth": 8
}
```

- `roots` replaces the defaults.
- `extraRules` adds to the built-in rules.
- `~/Documents` is not a default root because macOS protects it. If you add it, approve the prompt once.

## Limits

- **It relies on a private API.** The selftest gates install and re-checks after every macOS update. So far it is verified on macOS 27.2 only; reports from other versions are welcome (`nohog selftest`).
- **A brand-new `node_modules` is indexed for its first ~3 seconds** before it gets excluded.

## Development

```
swift test -Xswiftc -warnings-as-errors
./scripts/release.sh     # universal zip in dist/; see the script header for signing and notarization
```

The tests use an in-memory exclusion store, so they never touch your Spotlight settings. Running the tests needs Xcode (Command Line Tools ships no test frameworks). Building does not.

Releasing:

1. Bump `version` in `Sources/nohog/main.swift`, commit, then tag and push: `git tag vX.Y.Z && git push --tags`.
2. The `release` workflow runs the tests, builds the universal zip and publishes the GitHub release.
3. Update `url` and `sha256` in `Formula/nohog.rb` (`shasum -a 256` of the tag's `.tar.gz`).

`scripts/release.sh` also accepts `NOHOG_SIGN_IDENTITY` / `NOHOG_NOTARY_PROFILE` if you ever get a Developer ID.

## License

MIT, see [LICENSE](LICENSE).
