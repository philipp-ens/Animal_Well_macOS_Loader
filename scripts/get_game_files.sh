#!/bin/bash
# Downloads your own copy of the Windows game file "Animal Well.exe" with Valve's command-line tool SteamCMD,
# and tells the loader app where it is.
#     bash get_game_files.sh
# The loader app runs the same script in a Terminal window (as get_game_files.command).
#
# What it does, step by step:
#   1. downloads SteamCMD (Valve's official tool, from Valve's server) into ~/.animalwellloader/steamcmd
#   2. asks for your Steam account name; SteamCMD then asks for your password and Steam Guard code ITSELF -
#      this script never sees them
#   3. downloads one exact build of the game (the one the loader was made for) - only possible for an account
#      that owns Animal Well
#   4. checks the file's fingerprint, moves it to ~/Library/Application Support/Animal Well/ and remembers
#      that place for the loader app
#
# So that the loader app can follow along, the script keeps three small files in ~/.animalwellloader:
#   download.pid      its process number
#   download.status   running / done / failed / cancelled / closed
#   download.cancel   created by the app to say "stop now"

APP_ID=813230                       # Animal Well
DEPOT_ID=813231                     # its Windows files
MANIFEST_ID=8951799273146338346     # the exact build (Steam build 16245418)
WANTED_SHA256=783ce715d09ada0faf116c5130bf768dcb3777624206d42c5ae3e6d115c84346

WORK="$HOME/.animalwellloader"
TARGET="$HOME/Library/Application Support/Animal Well"
STATUS="$WORK/download.status"
CANCEL="$WORK/download.cancel"
mkdir -p "$WORK/steamcmd" "$TARGET"

# Started by the loader app (the file then ends in .command)? Then give the window a title to recognise it by.
FROM_APP=0
case "$0" in *.command) FROM_APP=1 ;; esac
if [ "$FROM_APP" = 1 ]; then printf '\033]0;Animal Well download\007'; fi

say_status() { echo "$1" > "$STATUS"; }

# Close this Terminal window - only when the loader app opened it, and only after the script has ended
# (the request is sent 1.5 seconds later by a detached helper, so Terminal does not ask about running programs).
close_window() {
    [ "$FROM_APP" = 1 ] || return 0
    nohup osascript -e 'delay 1.5' \
        -e 'tell application "Terminal" to close (every window whose name contains "Animal Well download")' \
        >/dev/null 2>&1 </dev/null &
}

rm -f "$CANCEL"
echo $$ > "$WORK/download.pid"
say_status running

# Whatever way the script ends, leave a truthful status behind.
finish() {
    if [ "$(cat "$STATUS" 2>/dev/null)" = running ]; then
        if [ -e "$CANCEL" ]; then say_status cancelled; close_window; else say_status failed; fi
    fi
    if [ -n "$WATCHER" ]; then kill -KILL "$WATCHER" 2>/dev/null; fi
}
trap finish EXIT
trap 'say_status closed; exit 1' HUP        # the window was closed
trap 'exit 1' TERM INT                      # stopped: finish() works out why

# The loader app cancels by creating the file download.cancel. This helper waits for it and then stops
# everything that runs in this window (SteamCMD included).
( trap '' TERM
  while [ ! -e "$CANCEL" ]; do sleep 1; done
  kill -TERM 0
  sleep 3
  kill -KILL 0 ) &
WATCHER=$!

# Remove the folder a download leaves behind. If it is still there the next time, SteamCMD takes the download for
# done and does not fetch the files again - although the game file was moved out of it.
clean_download() {
    case "$WORK" in */.animalwellloader) ;; *) return 0 ;; esac      # only ever delete inside our own folder
    rm -rf "$WORK/steamcmd/steamapps/content/app_$APP_ID"
    return 0
}

cd "$WORK/steamcmd" || exit 1
clean_download                                  # start from a clean state

if [ ! -f steamcmd.sh ]; then
    echo "Downloading SteamCMD from Valve ..."
    if ! curl -sSL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz" | tar zxf -; then
        echo "Could not download SteamCMD."
        exit 1
    fi
fi

read -r -p "Steam account name (the login name, not the profile name): " ACCOUNT

./steamcmd.sh +login "$ACCOUNT" +download_depot $APP_ID $DEPOT_ID $MANIFEST_ID +quit

# Find the downloaded file: look in our work folder and in Steam's download folders, and take the first one with
# the right fingerprint.
FOUND=""
while IFS= read -r candidate; do
    if [ "$(shasum -a 256 "$candidate" | cut -d' ' -f1)" = "$WANTED_SHA256" ]; then
        FOUND="$candidate"
        break
    fi
done < <(find "$WORK" "$HOME/Library/Application Support/Steam/steamapps/content" "$HOME/Steam" \
              -type f -name "Animal Well.exe" 2>/dev/null)

if [ -z "$FOUND" ]; then
    echo
    echo "The download did not produce the expected Animal Well.exe where I looked."
    echo "Scroll up: SteamCMD prints 'Depot download complete' with the folder, or an error."
    echo
    echo "For finding the cause - what is in $WORK:"
    ls -la "$WORK"
    find "$WORK" -iname "*animal*" 2>/dev/null
    exit 1
fi

mv -f "$FOUND" "$TARGET/Animal Well.exe"        # move, not copy: one copy of the game file only
clean_download                                  # and remove the rest of the download folder
defaults write local.animalwellloader ExePath "$TARGET/Animal Well.exe"
say_status "done"
echo
echo "Done: $TARGET/Animal Well.exe"
echo "The loader app will use it without asking."
close_window
exit 0
