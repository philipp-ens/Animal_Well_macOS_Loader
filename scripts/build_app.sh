#!/bin/bash
# Builds "Animal Well Loader_x86_64.app" from game.c, dxbc2msl.c, main.m, steamcloud.m, mods.c, get_game_files.sh
# and the icon
# (it can be started from any folder):
#     bash scripts/build_app.sh
# The app is put into the folder of the source files.
# The app contains only the loader. It holds nothing of the game - at its first start it asks for your own
# "Animal Well.exe".
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"       # this script's folder; get_game_files.sh is next to it
# The source files are one folder up (in the repository), or next to this script (inside the installer package,
# which holds all files in one folder).
if [ -f "$HERE/game.c" ]; then cd "$HERE"; else cd "$HERE/.."; fi
# The app has two names:
FILE_NAME="Animal Well Loader_x86_64"   # the file's name: what Finder shows, what you double-click
NAME="Animal Well"                          # the running program's name: the menu bar, "Quit ...", Activity Monitor
APP="$FILE_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/get_game_files.sh" "$APP/Contents/Resources/"       # the SteamCMD download, offered at the first start
# The app's icon: icon/icon.icns in the repository, next to the other files inside the installer package.
# Info.plist below names it.
ICON=icon/icon.icns
if [ ! -f "$ICON" ]; then ICON=icon.icns; fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

# steamcloud.m and steamcloud.h are in the folder steamcloud/ in the repository, and next to the other files
# inside the installer package.
CLOUD=steamcloud
if [ ! -f "$CLOUD/steamcloud.m" ]; then CLOUD=.; fi

# The mods (changes to the game itself) are in the folder mods/ - in the repository and inside the installer
# package alike. Every option of the "mods" submenu is one file in mods/options/: all of them are compiled.
MODS=mods

clang -arch x86_64 -O2 -fobjc-arc -I "$CLOUD" -I "$MODS" game.c dxbc2msl.c main.m "$CLOUD/steamcloud.m" \
    "$MODS"/*.c "$MODS"/options/*.c \
    -framework Cocoa -framework Metal -framework MetalKit -framework QuartzCore \
    -framework AudioToolbox -framework GameController \
    -framework Security -framework CoreImage -lz \
    -o "$APP/Contents/MacOS/$NAME"

# CFBundleName is the name macOS puts in the menu bar; it does not have to match the file's name.
# The identifier stays "local.animalwellloader": the app's remembered settings (game file, Steam library) are
# stored under it, and get_game_files.sh writes to it.
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>$NAME</string>
    <key>CFBundleDisplayName</key>          <string>$NAME</string>
    <key>CFBundleIdentifier</key>           <string>local.animalwellloader</string>
    <key>CFBundleExecutable</key>           <string>$NAME</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>0.1</string>
    <key>CFBundleVersion</key>              <string>1</string>
    <key>LSMinimumSystemVersion</key>       <string>11.0</string>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>NSPrincipalClass</key>             <string>NSApplication</string>
</dict>
</plist>
EOF

# For starting it from Steam (a game's Properties -> Launch Options):
#     /bin/bash "<full path>/Animal Well Loader_x86_64.app/Contents/Resources/steam_launch.sh" %command%
# (It lives in Resources, not MacOS: everything in Contents/MacOS counts as program code that must be signed
#  on its own, and an unsigned script there makes codesign refuse the whole app.)
# Steam puts the game's own start command where %command% stands: the path of Animal Well.exe.
printf '%s\n' '#!/bin/bash' "exec \"\$(dirname \"\$0\")/../MacOS/$NAME\" \"\$1\"" > "$APP/Contents/Resources/steam_launch.sh"
chmod +x "$APP/Contents/Resources/steam_launch.sh"

codesign --force --sign - "$APP"        # "ad hoc" signature: enough to run it on this Mac
echo "built \"$APP\" - open it with:  open \"$APP\""
