<div align="center">

# 🍎 ZoneMinder Mobile · Apple

### Native Apple client for [ZoneMinder](https://zoneminder.com) — a shared Swift core powering iPhone and Apple TV (SwiftUI).

<p>
  <img alt="iOS" src="https://img.shields.io/badge/iOS-000000?style=for-the-badge&logo=apple&logoColor=white">
  <img alt="tvOS" src="https://img.shields.io/badge/tvOS-000000?style=for-the-badge&logo=apple&logoColor=white">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-F05138?style=for-the-badge&logo=swift&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-0071E3?style=for-the-badge&logo=swift&logoColor=white">
  <img alt="SwiftPM" src="https://img.shields.io/badge/SwiftPM-FA7343?style=for-the-badge&logo=swift&logoColor=white">
</p>
<p>
  <a href="LICENSE"><img alt="License: AGPL-3.0" src="https://img.shields.io/badge/License-AGPL%20v3-blue.svg?style=flat-square"></a>
  <img alt="Last commit" src="https://img.shields.io/github/last-commit/SteveGilvarry/zoneminder-mobile-apple?style=flat-square&logo=git&logoColor=white&color=F05138">
  <img alt="Top language" src="https://img.shields.io/github/languages/top/SteveGilvarry/zoneminder-mobile-apple?style=flat-square&color=F05138">
  <img alt="Code size" src="https://img.shields.io/github/languages/code-size/SteveGilvarry/zoneminder-mobile-apple?style=flat-square">
  <img alt="Stars" src="https://img.shields.io/github/stars/SteveGilvarry/zoneminder-mobile-apple?style=flat-square&logo=github&color=yellow">
  <img alt="Issues" src="https://img.shields.io/github/issues/SteveGilvarry/zoneminder-mobile-apple?style=flat-square">
</p>

</div>

---

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

## License

Licensed under the **GNU Affero General Public License v3.0 or later** (AGPL-3.0-or-later), matching `zm_api` / ZoneMinder. See [LICENSE](LICENSE).
