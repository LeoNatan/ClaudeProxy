# ClaudeProxy — notes for agents

Two independent macOS menu bar apps (AppKit, Swift 6, macOS 15+, Apple silicon):

- `ClaudeProxyHost/` — runs on the Mac that holds Claude Code's configuration and credentials (the *host*; called "server" before 2.0).
- `ClaudeProxyClient/` — runs on other Macs and points their Claude Code at the host.

The host connects **out** to clients, never the other way round, so it works on a managed Mac that can't advertise over Bonjour (`NoMulticastAdvertisements`) or accept incoming connections. Each client advertises `_claudeproxy-client._tcp` and listens on its network port (default 41822). The host browses for clients (or uses addresses added by hand) and keeps a pool of idle connections open to each. When Claude Code on the client connects to `127.0.0.1` (default 41821), the client pairs that connection with one idle host connection and splices the bytes; the host serves the HTTP on it exactly as before (credential swap, redaction, streaming, `/_claudeproxy/info` handshake).

Each host connection starts with a one-line handshake (protocol v3): the host sends `CLAUDEPROXY-HOST <host id> <host name>`, and the client answers `CLAUDEPROXY-OK` or `CLAUDEPROXY-OTHER-HOST`, then HTTP follows. A client uses exactly one host (the first it sees, or the one picked in its menu) and turns other hosts away; a turned-away host retries every 10 s. The host ID is a UUID kept in the host's defaults. The host only connects to clients once its settings are loaded.

Each folder has its own `.xcodeproj` (folder-synchronized groups). `Constants.swift`, `ProcessRunner.swift`, `MenuText.swift` and `Updater.swift` exist in both apps as copies: change them in both.

Menu item titles, including disabled informational lines and section headers, use Title Case ("Client Enabled", "Available Once a Host Has Connected"), as in Apple's Human Interface Guidelines. Interpolated values (host names, paths, error messages) stay as they are.

Both apps update themselves with [Sparkle](https://sparkle-project.org) (Swift package). Each app's `SUFeedURL` points at an appcast attached to the latest GitHub release: `https://github.com/LeoNatan/ClaudeProxy/releases/latest/download/appcast-host.xml` and `…/appcast-client.xml`. Updates are not EdDSA-signed (no `SUPublicEDKey`): Sparkle accepts them because the update and the installed app carry the same Developer ID signature. Sparkle logs that this mode is deprecated; if a future Sparkle drops it, add a key with `generate_keys`.

## Release process

Releases are GitHub releases on `LeoNatan/ClaudeProxy`, tagged `vX.Y.Z` from `main`, with both apps attached as separate, Developer ID–signed zips.

### 1. Bump the version (both projects)

In `ClaudeProxyHost/ClaudeProxyHost.xcodeproj/project.pbxproj` and `ClaudeProxyClient/ClaudeProxyClient.xcodeproj/project.pbxproj`, in both the Debug and Release target configurations:

- `MARKETING_VERSION` → the new version (`1.0.3`).
- `CURRENT_PROJECT_VERSION` → increment by one.

Both apps always share the same version.

### 2. Commit and push

Commit the release changes on `main` and push. The release tag is created from `main` by `gh release create --target main`.

### 3. Build, sign, zip

Build with the default DerivedData location (no `-derivedDataPath`) and stage the products in a temporary directory, never inside the repo.

```sh
VERSION=1.0.3
STAGE=$(mktemp -d)
for APP in ClaudeProxyHost ClaudeProxyClient; do
	xcodebuild -project $APP/$APP.xcodeproj -scheme $APP -configuration Release -allowProvisioningUpdates clean build
	PRODUCTS=$(xcodebuild -project $APP/$APP.xcodeproj -scheme $APP -configuration Release -showBuildSettings | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')
	ditto "$PRODUCTS/$APP.app" "$STAGE/$APP.app"

	# The projects sign with Apple Development; downloads must be Developer ID–signed.
	# Sparkle's nested helpers first (inside out), then the app. Don't use --deep.
	ID="Developer ID Application: Leo Natan (S9QFG2VH2E)"
	SPARKLE="$STAGE/$APP.app/Contents/Frameworks/Sparkle.framework"
	codesign -f -s "$ID" -o runtime --timestamp "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
	codesign -f -s "$ID" -o runtime --timestamp --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
	codesign -f -s "$ID" -o runtime --timestamp "$SPARKLE/Versions/B/Autoupdate"
	codesign -f -s "$ID" -o runtime --timestamp "$SPARKLE/Versions/B/Updater.app"
	codesign -f -s "$ID" -o runtime --timestamp "$SPARKLE"
	codesign -f -s "$ID" -o runtime --timestamp "$STAGE/$APP.app"
	codesign --verify --deep --strict "$STAGE/$APP.app"
	/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$STAGE/$APP.app/Contents/Info.plist"   # must equal $VERSION

	(cd "$STAGE" && ditto -c -k --keepParent "$APP.app" "$APP-$VERSION.zip")
done
```

- Zip names include the version: `ClaudeProxyHost-<version>.zip`, `ClaudeProxyClient-<version>.zip`. (v1.0–v1.0.2 predate this and keep their unversioned `ClaudeProxyServer.zip`/`ClaudeProxyClient.zip` names; don't rename them.)
- Use `ditto -c -k --keepParent`, not `zip`, so the bundle's structure and signature survive.

### 4. Appcasts

Every release must carry both appcasts: the apps read them from *the latest release*, so a release without them breaks update checks. `generate_appcast` ships in the Sparkle package (resolved into DerivedData). Write the release notes as Markdown next to each zip with the same base name; `generate_appcast` puts them in the appcast for Sparkle's update window.

```sh
GENERATE_APPCAST=$(ls -d ~/Library/Developer/Xcode/DerivedData/ClaudeProxyHost-*/SourcePackages/artifacts/sparkle/Sparkle/bin | head -1)/generate_appcast
for APP in ClaudeProxyHost ClaudeProxyClient; do
	FEED=$([ $APP = ClaudeProxyHost ] && echo appcast-host.xml || echo appcast-client.xml)
	mkdir "$STAGE/$APP-feed"
	cp "$STAGE/$APP-$VERSION.zip" "$STAGE/$APP-feed/"
	cp release-notes.md "$STAGE/$APP-feed/$APP-$VERSION.md"   # user-visible changes for this release
	"$GENERATE_APPCAST" --embed-release-notes --download-url-prefix "https://github.com/LeoNatan/ClaudeProxy/releases/download/v$VERSION/" -o "$STAGE/$FEED" "$STAGE/$APP-feed"
done
```

- Pass `-o` an absolute path: a relative one is written to the current directory (the repo).
- Keep `--embed-release-notes`: without it the appcast links to a separate `.md` file that isn't uploaded.
- "Private key for account ed25519 not found in the Keychain" is expected (no EdDSA key, see above).
- Each appcast holds only the new version; that's all Sparkle needs.

### 5. Publish

```sh
gh release create v$VERSION "$STAGE/ClaudeProxyHost-$VERSION.zip" "$STAGE/ClaudeProxyClient-$VERSION.zip" "$STAGE/appcast-host.xml" "$STAGE/appcast-client.xml" \
	--target main --title "ClaudeProxy $VERSION" --notes "…"
```

Release notes: a short bullet list of user-visible changes, then this footer:

> Requires macOS 15 or later on Apple silicon. Signed with Developer ID but not notarized: after downloading, run `xattr -dr com.apple.quarantine <app>` before opening.

Check the result with `gh release view v$VERSION --json assets` (four assets), and that `curl -sL https://github.com/LeoNatan/ClaudeProxy/releases/latest/download/appcast-host.xml` returns the new version. Never publish a release as a pre-release or draft: `latest` skips those, so clients would keep getting the previous appcast.

### Notarization

Not done yet: no `notarytool` credentials are stored on the release Mac. Once `xcrun notarytool store-credentials notary` has been run, add after signing:

```sh
ditto -c -k --keepParent "$STAGE/$APP.app" "$STAGE/$APP-notarize.zip"
xcrun notarytool submit "$STAGE/$APP-notarize.zip" --keychain-profile notary --wait
xcrun stapler staple "$STAGE/$APP.app"
```

Zip *after* stapling, and drop the `xattr` line from the notes footer.

## Testing constraints

- Never run `ClaudeProxyClient` on the developer's main Mac: installing it rewrites `~/.claude/settings.json`. Test the client in a VM or on another Mac.
- The host can be tested locally against a fake upstream by launching it with a scratch config directory: `open --env CLAUDE_CONFIG_DIR=<scratch> ClaudeProxyHost.app`. A stand-in client can be simulated with `dns-sd -R <name> _claudeproxy-client._tcp local 41822` plus a TCP listener on that port. Never put test settings in the real `~/.claude` or in `/Library/Application Support/ClaudeCode/`.
