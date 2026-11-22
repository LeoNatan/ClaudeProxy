# ClaudeProxy — notes for agents

Two independent macOS menu bar apps (AppKit, Swift 6, macOS 15+, Apple silicon):

- `ClaudeProxyServer/` — runs on the Mac that holds Claude Code's configuration and credentials.
- `ClaudeProxyClient/` — runs on other Macs and points their Claude Code at the server.

Each folder has its own `.xcodeproj` (folder-synchronized groups). `Constants.swift` and `ProcessRunner.swift` exist in both apps as copies: change them in both.

## Release process

Releases are GitHub releases on `LeoNatan/ClaudeProxy`, tagged `vX.Y.Z` from `main`, with both apps attached as separate, Developer ID–signed zips.

### 1. Bump the version (both projects)

In `ClaudeProxyServer/ClaudeProxyServer.xcodeproj/project.pbxproj` and `ClaudeProxyClient/ClaudeProxyClient.xcodeproj/project.pbxproj`, in both the Debug and Release target configurations:

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
for APP in ClaudeProxyServer ClaudeProxyClient; do
	xcodebuild -project $APP/$APP.xcodeproj -scheme $APP -configuration Release -allowProvisioningUpdates clean build
	PRODUCTS=$(xcodebuild -project $APP/$APP.xcodeproj -scheme $APP -configuration Release -showBuildSettings | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')
	ditto "$PRODUCTS/$APP.app" "$STAGE/$APP.app"

	# The projects sign with Apple Development; downloads must be Developer ID–signed.
	codesign --force --options runtime --timestamp -s "Developer ID Application: Leo Natan (S9QFG2VH2E)" "$STAGE/$APP.app"
	codesign --verify --strict "$STAGE/$APP.app"
	/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$STAGE/$APP.app/Contents/Info.plist"   # must equal $VERSION

	(cd "$STAGE" && ditto -c -k --keepParent "$APP.app" "$APP-$VERSION.zip")
done
```

- Zip names include the version: `ClaudeProxyServer-<version>.zip`, `ClaudeProxyClient-<version>.zip`. (v1.0–v1.0.2 predate this and keep unversioned names; don't rename them.)
- Use `ditto -c -k --keepParent`, not `zip`, so the bundle's structure and signature survive.

### 4. Publish

```sh
gh release create v$VERSION "$STAGE/ClaudeProxyServer-$VERSION.zip" "$STAGE/ClaudeProxyClient-$VERSION.zip" \
	--target main --title "ClaudeProxy $VERSION" --notes "…"
```

Release notes: a short bullet list of user-visible changes, then this footer:

> Requires macOS 15 or later on Apple silicon. Signed with Developer ID but not notarized: after downloading, run `xattr -dr com.apple.quarantine <app>` before opening.

Check the result with `gh release view v$VERSION --json assets`.

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
- The server can be tested locally against a fake upstream by launching it with a scratch config directory: `open --env CLAUDE_CONFIG_DIR=<scratch> ClaudeProxyServer.app`. Never put test settings in the real `~/.claude` or in `/Library/Application Support/ClaudeCode/`.
