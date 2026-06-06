# zm-mobile-apple

Native Apple implementation for ZoneMinder: shared Swift core plus iPhone and tvOS SwiftUI app scaffolds.

## Current implementation

- `ZmMobileCore` Swift package with URLSession API facade, auth refresh model, Keychain storage, HLS auth resource-loader scaffold, and stream coordinator.
- iOS SwiftUI app source scaffold under `Apps/ZoneMinderMobile`.
- tvOS SwiftUI app source scaffold under `Apps/ZoneMinderTV`.
- OpenAPI spec snapshot in `api/openapi/zoneminder.openapi.json`.
- `project.yml` for XcodeGen. Install `xcodegen` to generate the workspace/project.

## Generate Xcode project

```bash
brew install xcodegen
xcodegen generate
open ZoneMinderApple.xcodeproj
```

The Swift package can be checked independently:

```bash
swift test
```

## Backend

Default API base URL is `http://zoneminder.local:8080`. Development ATS exceptions are declared in `project.yml`.
