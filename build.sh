#!/bin/bash

echo -e "[*] Build android and linux for release"
flutter clean && flutter pub get && flutter build apk --release && flutter build linux --release

echo -e "[*] Clean old AppImage"
rm AppImage/RedCourier-x86_64.AppImage

echo -e "[*] Replace old binary for AppImage build"
rm -rf  AppImage/RedCourier/AppDir/usr/bin/*
cp -R build/linux/x64/release/bundle/* AppImage/RedCourier/AppDir/usr/bin/

echo -e "[*] Build AppImage"
cd AppImage
./appimagetool-x86_64.AppImage RedCourier/AppDir
