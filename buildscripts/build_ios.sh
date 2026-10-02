name: Build iOS

on:
  workflow_dispatch:

jobs:
  build-ios:
    runs-on: macos-26

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Build dependency stack
        shell: bash
        run: |
          set -Eeuo pipefail
          bash ./buildscripts/build_ios.sh

      - name: Package device IPA
        shell: bash
        run: |
          set -Eeuo pipefail
          bash ./buildscripts/package_ipa.sh device

      - name: Upload IPA
        uses: actions/upload-artifact@v4
        with:
          name: OpenMW-ipa
          path: OpenMW.ipa
          if-no-files-found: error
