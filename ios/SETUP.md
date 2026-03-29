# Rawcut iOS - Xcode Project Setup

The Swift source files are ready. To create the Xcode project:

## Option 1: Xcode GUI (quickest)

1. Open Xcode -> File -> New -> Project
2. Choose **iOS -> App**
3. Configure:
   - Product Name: `Rawcut`
   - Organization Identifier: `com.rawcut`
   - Bundle Identifier: `com.rawcut.app`
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Storage: **SwiftData**
4. Save to `/Users/jinho/Projects/rawcut/ios/`
5. Delete the auto-generated Swift files (ContentView.swift, RawcutApp.swift, Item.swift)
6. Drag the existing `Rawcut/` folder into the Xcode project navigator
7. Set deployment target to **iOS 17.0**
8. Add these to Info.plist or target capabilities:
   - **Push Notifications** capability
   - **Background Modes** capability (Background fetch, Background processing)
   - `BGTaskSchedulerPermittedIdentifiers` in Info.plist:
     - `com.rawcut.app.sync`
     - `com.rawcut.app.processing`
   - **Sign in with Apple** capability

## Option 2: xcodegen

Install: `brew install xcodegen`

Create `ios/project.yml`:

```yaml
name: Rawcut
options:
  bundleIdPrefix: com.rawcut
  deploymentTarget:
    iOS: "17.0"
  xcodeVersion: "16.0"
settings:
  SWIFT_VERSION: "6.0"
  SWIFT_STRICT_CONCURRENCY: complete
targets:
  Rawcut:
    type: application
    platform: iOS
    sources:
      - Rawcut
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: com.rawcut.app
      INFOPLIST_VALUES:
        BGTaskSchedulerPermittedIdentifiers:
          - com.rawcut.app.sync
          - com.rawcut.app.processing
    entitlements:
      path: Rawcut/Rawcut.entitlements
      properties:
        com.apple.developer.applesignin:
          - Default
        aps-environment: development
```

Then run: `cd ios && xcodegen generate`

## Option 3: Tuist

Install: `curl -Ls https://install.tuist.io | bash`

This is more involved but better for team projects. See tuist.io docs.
