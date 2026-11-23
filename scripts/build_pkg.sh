#!/bin/bash
# Makes the release: an installer package that BUILDS the app on the user's Mac and puts it into Applications.
#     bash scripts/build_pkg.sh
# Result: "Animal Well Loader_x86_64-<version>.pkg" in the main folder of the repository.
#
# The package contains no finished app. It contains the source files and build_app.sh. When the user presses
# "Install", the package's install script compiles them on that Mac and moves the result to Applications.
# If that Mac has no compiler yet, the script first has macOS download and install Apple's command line tools.
# Nothing of the game is in it.
#
# How a package is made (both tools are part of macOS):
#   pkgbuild      makes a component package. Here it has no files to install ("--nopayload"), only a folder
#                 of scripts; Installer unpacks that folder to a temporary place and runs "postinstall" in it.
#   productbuild  wraps that in the installer people know: title, pages of text, Continue / Install buttons
set -e
trap 'echo "build_pkg.sh STOPPED at line $LINENO - the step just before this message failed. No package was made."' ERR
cd "$(dirname "$0")/.."         # the repository's main folder: the source files are there, the scripts in scripts/

# (the package holds them all in one folder, without "scripts/")
SOURCES="game.c game.h main.m dxbc2msl.c dxbc2msl.h steamcloud/steamcloud.m steamcloud/steamcloud.h icon/icon.icns
         scripts/get_game_files.sh scripts/build_app.sh"
for f in $SOURCES; do
    if [ ! -f "$f" ]; then echo "missing: $f"; exit 1; fi
done

# the app's file name and version are decided in one place: build_app.sh
FILE_NAME=$(sed -n 's/^FILE_NAME="\([^"]*\)".*/\1/p' scripts/build_app.sh)
VERSION=$(sed -n 's/.*CFBundleShortVersionString<\/key>.*<string>\(.*\)<\/string>.*/\1/p' scripts/build_app.sh)
if [ -z "$FILE_NAME" ] || [ -z "$VERSION" ]; then echo "cannot read the name or version from build_app.sh"; exit 1; fi
APP="$FILE_NAME.app"
IDENTIFIER=local.animalwellloader
OUT="$FILE_NAME-$VERSION.pkg"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/scripts/source" "$WORK/resources"
echo "== step 1 of 2: packing the source files"
for f in $SOURCES; do cp "$f" "$WORK/scripts/source/"; done
# the mods keep their folder (mods/ with one file per option in mods/options/)
if [ ! -f mods/mods.c ]; then echo "missing: mods/mods.c"; exit 1; fi
mkdir -p "$WORK/scripts/source/mods/options"
cp mods/*.c mods/*.h "$WORK/scripts/source/mods/"
cp mods/options/*.c mods/options/*.h "$WORK/scripts/source/mods/options/"

# ---- the install script: runs on the user's Mac, as root, when they press "Install" ----
# $3 is the disk being installed on ("/"). What the build prints is kept in a log file.
# (Written with a placeholder for the app's name, so that the script below can be read as it is: no escaping.)
cat > "$WORK/scripts/postinstall.in" <<'EOF'
#!/bin/bash
APP="@APP@"
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${3%/}/Applications"
LOG="/tmp/animal-well-loader-install.log"
: > "$LOG"

# ---- 1. the compiler ----
# The app is built here, on this Mac, and that needs Apple's command line tools (the compiler "clang").
# "xcode-select -p" prints the folder of the developer tools in use, or fails if there are none.
have_compiler() {
    local dir
    dir=$(xcode-select -p 2>/dev/null) || return 1
    [ -x "$dir/usr/bin/clang" ] || [ -x "$dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang" ]
}

# Ask macOS to download and install the command line tools from Apple. They are an ordinary Apple software
# update, but one that is only offered while a certain marker file exists - that file is what
# "xcode-select --install" creates, too. Then: find the update's exact name in the list, and install it.
install_tools() {
    local marker=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress label
    touch "$marker"
    label=$(softwareupdate -l 2>>"$LOG" | grep -B 1 -E 'Command Line Tools' | awk -F'*' '/^ *\*/ {print $2}' |
            sed -e 's/^ *Label: //' -e 's/^ *//' | sort -V | tail -n 1)
    if [ -n "$label" ]; then
        echo "Animal Well Loader: installing \"$label\" from Apple - this can take several minutes"
        softwareupdate -i "$label" >> "$LOG" 2>&1
        xcode-select --switch /Library/Developer/CommandLineTools >> "$LOG" 2>&1
    else
        echo "Animal Well Loader: Apple's software update did not offer the command line tools" | tee -a "$LOG"
    fi
    rm -f "$marker"
}

if ! have_compiler; then
    echo "Animal Well Loader: Apple's command line tools are missing"
    install_tools
    if ! have_compiler; then
        echo "Animal Well Loader: COULD NOT INSTALL APPLE'S COMMAND LINE TOOLS (no internet connection?)." | tee -a "$LOG"
        echo "Open Terminal, run  xcode-select --install  and open this package again." | tee -a "$LOG"
        exit 1
    fi
fi

# ---- 2. build ----
BUILD=$(mktemp -d /tmp/animal-well-loader.XXXXXX) || exit 1
cp -R "$HERE/source/"* "$BUILD/" || exit 1
cd "$BUILD" || exit 1

echo "Animal Well Loader: building the app in $BUILD"
if ! bash build_app.sh >> "$LOG" 2>&1 || [ ! -d "$APP" ]; then
    echo "Animal Well Loader: THE BUILD FAILED. What happened:"
    cat "$LOG"
    exit 1
fi

# ---- 3. into Applications ----
rm -rf "$DEST/$APP"                                 # replace an older installation
ditto "$APP" "$DEST/$APP" || exit 1

# Installer runs as "root", so the app would belong to root. Hand it to the person who is installing - the
# same as if they had dragged it into Applications.
OWNER=$(stat -f%Su /dev/console 2>/dev/null)
if [ -n "$OWNER" ] && [ "$OWNER" != root ]; then chown -R "$OWNER" "$DEST/$APP"; fi

cd /
rm -rf "$BUILD"
echo "Animal Well Loader: installed $DEST/$APP"

# ---- 4. start it ----
# Open the app for the person who is installing. This script runs as root, and an app must not be started as
# root: "launchctl asuser" puts the command into that person's login session, "sudo -u" makes it run as them,
# and "open" starts the app the normal way, as a double-click would.
# Not when the package is installed from the command line (then nobody may be looking at the screen).
if [ -z "$COMMAND_LINE_INSTALL" ] && [ -n "$OWNER" ] && [ "$OWNER" != root ]; then
    OWNER_ID=$(id -u "$OWNER" 2>/dev/null)
    if [ -n "$OWNER_ID" ]; then
        launchctl asuser "$OWNER_ID" sudo -u "$OWNER" open "$DEST/$APP" >> "$LOG" 2>&1 ||
            echo "Animal Well Loader: could not start the app (see $LOG) - open it from Applications"
    fi
fi
exit 0
EOF
sed "s/@APP@/$APP/" "$WORK/scripts/postinstall.in" > "$WORK/scripts/postinstall"
rm "$WORK/scripts/postinstall.in"
chmod +x "$WORK/scripts/postinstall"

pkgbuild --nopayload --scripts "$WORK/scripts" --identifier "$IDENTIFIER" --version "$VERSION" "$WORK/app.pkg"

# ---- the pages the user clicks through (plain text, plain characters only) ----
cat > "$WORK/resources/welcome.txt" <<EOF
This installs "$FILE_NAME", a program that runs the Windows version of ANIMAL WELL on a Mac.

This is not the full application, only a Loader. You need to own ANIMAL WELL on Steam or already have a copy of the game.

This is an unofficial fan project. It is not affiliated with or endorsed by the game's developer or publisher.
EOF

cat > "$WORK/resources/readme.txt" <<EOF
INSTALLATION

This package does not contain a finished app. It contains the program's source code and builds the app on your Mac when you press Install.
The finished app, "$FILE_NAME", is put into your Applications folder.

Building needs Apple's command line tools (the compiler). If your Mac does not have them yet, the installer downloads and installs them from Apple before it builds the app, which can take a few minutes.


REQUIREMENTS

- macOS 11 or later.
- An internet connection, if Apple's command line tools have to be installed (see above).
- On a Mac with Apple Silicon: Rosetta 2. If it is missing, macOS offers to install it the first time you open the app.
- A Steam account that owns ANIMAL WELL.


STEAM

If the Steam app is running when you start the game, achievements count for your Steam account and the Steam overlay works.


SAVE FILE

Your save is kept in  ~/Library/Application Support/Animal Well/  and has the same format as on Windows.
EOF

cat > "$WORK/resources/conclusion.txt" <<EOF
"$FILE_NAME" was built, is now in your Applications folder and has been started. Its first window asks for your copy of the game.

Next time, open it from Applications, from Launchpad or with Spotlight.
EOF

# ---- the installer ----
# hostArchitectures names both kinds of Mac: without "arm64" the installer itself would ask for Rosetta.
# enable_localSystem alone = install for this Mac, without a "where?" page.
# installation-check runs before the first page: it looks for the compiler in its two usual places. If it is
# in neither, it tells the user what the installation is going to add (a notice the user can accept or cancel).
# The macOS version is checked there too, and not with a "volume-check": that one makes Installer examine
# every connected disk, and for an external disk macOS then asks the user for permission.
cat > "$WORK/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Animal Well Loader</title>
    <welcome file="welcome.txt" mime-type="text/plain"/>
    <readme file="readme.txt" mime-type="text/plain"/>
    <conclusion file="conclusion.txt" mime-type="text/plain"/>
    <options customize="never" require-scripts="false" hostArchitectures="x86_64,arm64"/>
    <domains enable_localSystem="true"/>
    <installation-check script="check_tools()"/>
    <script><![CDATA[
function check_tools() {
    if (system.compareVersions(system.version.ProductVersion, '11.0') < 0) {
        my.result.title = 'macOS 11 or later is needed';
        my.result.message = 'This program needs macOS 11 (Big Sur) or later.';
        my.result.type = 'Fatal';
        return false;
    }
    if (system.files.fileExistsAtPath('/Library/Developer/CommandLineTools/usr/bin/clang')) return true;
    if (system.files.fileExistsAtPath('/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild')) return true;
    my.result.title = 'Apple command line tools will be installed too';
    my.result.message = 'This package builds the app on your Mac and needs the command line tools from Apple for that. ' +
                        'They were not found, so the installation will download and install them from Apple first. ' +
                        'This file is 1-2 GB large so it could take a few minutes to install';
    my.result.type = 'Warn';
    return false;
}
    ]]></script>
    <choices-outline>
        <line choice="app"/>
    </choices-outline>
    <choice id="app" title="$FILE_NAME">
        <pkg-ref id="$IDENTIFIER"/>
    </choice>
    <pkg-ref id="$IDENTIFIER" version="$VERSION" onConclusion="none">app.pkg</pkg-ref>
</installer-gui-script>
EOF

echo "== step 2 of 2: making the installer"
rm -f "$OUT"
productbuild --distribution "$WORK/distribution.xml" --resources "$WORK/resources" --package-path "$WORK" \
             "$OUT"
if [ ! -f "$OUT" ]; then echo "the package was NOT created"; exit 1; fi

echo
echo "built \"$OUT\" ($(du -h "$OUT" | cut -f1 | tr -d ' ')) in $(pwd)"
open -R "$OUT" 2>/dev/null || true              # show the package in a Finder window
