#!/bin/bash
# Installs "Animal Well Loader" from the source files in this repository, with one command in Terminal:
#     curl -fsSL https://raw.githubusercontent.com/philipp-ens/Animal_Well_macOS_Loader/main/scripts/install.sh | bash
#
# What it does:
#   1. if Apple's command line tools (the compiler "clang") are missing, it installs them
#   2. downloads the source files of this repository into a temporary folder
#   3. builds the app there with scripts/build_app.sh
#   4. moves the app into Applications and starts it
# Nothing of the game is downloaded.
#
# Everything is inside main(), which is called on the last line: bash runs a piped script while it is still
# arriving, and this way nothing runs if the download breaks off halfway.

SOURCE_URL="https://github.com/philipp-ens/Animal_Well_macOS_Loader/archive/refs/heads/main.tar.gz"

# "xcode-select -p" prints the folder of the developer tools in use, or fails if there are none.
have_compiler() {
    local dir
    dir=$(xcode-select -p 2>/dev/null) || return 1
    [ -x "$dir/usr/bin/clang" ] || [ -x "$dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang" ]
}

# Install one Apple software update ($1 = its name), and show what is happening meanwhile.
# "softwareupdate" itself prints nothing while it downloads and installs, which looks like a hang. So it runs in
# the background here, and this loop writes a status line every few seconds. What the line says is read from
# macOS' own install log, which the software update service writes to while it works:
#     "starting download of <id> (Command Line Tools ..."   the update's id
#     "<id>: Starting download of X.pkg (Size:<bytes>"      one line per part: together, the size of the download
#     "destination path: <folder>/X.pkg"                    the folder the parts are downloaded into
#     "... for key <id> from "downloading" to "waiting to install""    the download is complete
#     "... url=file:///Library/Updates/<id>/X.pkg>"                    one line per part the installation has to do
#     "PackageKit: Extracting file:///Library/Updates/<id>/X.pkg"      the installation unpacks one more part
#     "PackageKit: Shoving ..."                                        it moves the unpacked files to their place
#     "PackageKit: Executing script "postinstall" ..."                 it runs the update's own finishing script
# The downloaded bytes are the size of that folder (only root may look into it, hence "sudo -n", which never
# asks for a password) plus /Library/Updates/<id>, where finished parts are put. If any of this cannot be read,
# the line shows the step and the time only. There is no percentage for the installation: macOS reports none,
# so the line says which of those three things it is doing (they take a minute or two together).
install_update() {
    local label=$1 log=/var/log/install.log out first pid status=0 began=$SECONDS
    local new id="" total=0 parts=0 dir="" have unpacked step text shown="" tick=0
    out=$(mktemp /tmp/animal-well-loader-tools.XXXXXX)
    first=$(( $(wc -l < "$log" 2>/dev/null || echo 0) + 1 ))        # only lines the log gets from now on count
    sudo softwareupdate --verbose -i "$label" > "$out" 2>&1 &
    pid=$!
    TOOLS_PID=$pid
    while ps -p "$pid" > /dev/null 2>&1; do
        sleep 3
        tick=$((tick + 1))
        new=$(tail -n "+$first" "$log" 2>/dev/null || true)
        if [ -z "$id" ]; then
            id=$(echo "$new" | sed -n 's/.*starting download of \([^ ]*\) (Command Line Tools.*/\1/p' | tail -n 1)
        fi
        step="preparing"
        text="preparing"
        if [ -n "$id" ] && echo "$new" | grep -q -E "for key $id from .* to \"(waiting to install|installing)\""; then
            step="installing"
            text="installing: preparing"
            # how many parts there are: the installation lists them all when it begins. (Not the number of
            # downloads: parts that an earlier, broken-off run already downloaded are not downloaded again.)
            parts=$(echo "$new" | grep -c "url=file:///Library/Updates/$id/" || true)
            unpacked=$(echo "$new" | grep -c "PackageKit: Extracting file:///Library/Updates/$id/" || true)
            if [ "$unpacked" -gt "$parts" ]; then parts=$unpacked; fi
            if [ "$unpacked" -gt 0 ]; then text="installing: unpacking part $unpacked of $parts"; fi
            if [ "$unpacked" -gt 0 ] && [ "$unpacked" = "$parts" ]; then
                # the lines after the last unpacked part
                new=$(echo "$new" | sed -n "/PackageKit: Extracting file:\/\/\/Library\/Updates\/$id\//h;//!H;\${x;p;}")
                if echo "$new" | grep -q "PackageKit: Shoving"; then text="installing: moving the files into place"; fi
                if echo "$new" | grep -q 'PackageKit: Executing script "postinstall"'; then text="installing: finishing"; fi
            fi
            if [ $((tick % 20)) = 0 ]; then sudo -n -v 2>/dev/null || true; fi    # keep the password valid
        elif [ -n "$id" ]; then
            step="downloading"
            text="downloading"
            if [ "$total" = 0 ]; then
                total=$(echo "$new" | sed -n "s/.*: $id: Starting download of .*(Size:\([0-9]*\).*/\1/p" |
                        awk '{sum += $1} END {printf "%d", sum / 1048576}')
                dir=$(echo "$new" | sed -n "s|.*destination path: \(/.*/$id-.*\)/[^/]*\$|\1|p" | head -n 1)
            fi
            have=$({ du -sk "/Library/Updates/$id" 2>/dev/null; if [ -n "$dir" ]; then sudo -n du -sk "$dir" 2>/dev/null; fi; } |
                   awk '{sum += $1} END {printf "%d", sum / 1024}')
            if [ "$total" -gt 0 ] && [ "$have" -gt 0 ]; then
                if [ "$have" -gt "$total" ]; then have=$total; fi
                text="downloading: $have of $total MB ($((have * 100 / total))%)"
            elif [ "$total" -gt 0 ]; then
                text="downloading $total MB"
            fi
        fi
        if [ -t 1 ]; then                       # in a Terminal window: rewrite the same line
            printf '\r\033[K    %s  -  %d:%02d' "$text" $(((SECONDS - began) / 60)) $(((SECONDS - began) % 60))
        elif [ "$step" != "$shown" ]; then      # written to a file: one line per step
            echo "    $text"
            shown=$step
        fi
    done
    wait "$pid" || status=$?
    TOOLS_PID=""
    if [ -t 1 ]; then printf '\r\033[K'; fi
    # softwareupdate also ends "successfully" when it installed nothing (for example when the update of that
    # name is not offered any more). So what counts is whether the compiler is there now.
    if [ "$status" = 0 ] && [ ! -x /Library/Developer/CommandLineTools/usr/bin/clang ]; then status=1; fi
    if [ "$status" = 0 ]; then
        echo "    done after $(((SECONDS - began) / 60)) min $(((SECONDS - began) % 60)) s"
    else
        echo "    the software update did not install the tools. What it said:"
        cat "$out"
        # a download that broke off (the internet connection dropped for a moment) is worth another try
        if grep -q "Error downloading" "$out"; then DOWNLOAD_BROKE=1; fi
    fi
    rm -f "$out"
    return "$status"
}

# Ask macOS to download and install the command line tools from Apple. They are an ordinary Apple software
# update, but one that is only offered while a certain marker file exists - that file is what
# "xcode-select --install" creates, too. Then: find the update's exact name in the list, and install it.
# Installing a software update needs the Mac password ("sudo").
install_tools() {
    local marker=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress label
    # Ctrl+C: stop here. Without this, bash carries on with the next line when Ctrl+C is pressed at the password
    # prompt, and the software update would keep running in the background.
    TOOLS_PID=""
    trap 'echo; echo "stopped"; if [ -n "$TOOLS_PID" ]; then sudo -n kill "$TOOLS_PID" 2>/dev/null; fi; rm -f "$marker"; exit 130' INT
    touch "$marker"
    echo "looking for the command line tools in Apple's software update (this takes a moment)"
    label=$(softwareupdate -l 2>/dev/null | grep -B 1 -E 'Command Line Tools' | awk -F'*' '/^ *\*/ {print $2}' |
            sed -e 's/^ *Label: //' -e 's/^ *//' | sort -V | tail -n 1)
    if [ -n "$label" ]; then
        echo "installing \"$label\" from Apple - this can take several minutes"
        # the marker again: the installation looks through the updates a second time, a while after the first
        # (the password is typed in between), and without the marker the tools are not among them
        local try
        for try in 1 2 3; do
            DOWNLOAD_BROKE=0
            sudo -v && touch "$marker" && install_update "$label" && sudo xcode-select --switch /Library/Developer/CommandLineTools
            if have_compiler || [ "$DOWNLOAD_BROKE" = 0 ] || [ "$try" = 3 ]; then break; fi
            echo "the download broke off - is the internet connection working? Trying again in 10 seconds"
            sleep 10
        done
    fi
    rm -f "$marker"
    if have_compiler; then trap - INT; return 0; fi

    # The software update did not offer them or failed: fall back to Apple's own install window, and wait for it.
    echo "could not install the tools from here. A window opens instead: click \"Install\" in it."
    xcode-select --install 2>/dev/null || true
    echo "waiting until the installation has finished (stop waiting with Ctrl+C)"
    until have_compiler; do sleep 5; done
    trap - INT
}

main() {
    set -e
    if [ "$(uname)" != Darwin ]; then echo "this installs a Mac app - it only works on macOS"; exit 1; fi

    echo "== 1 of 4 =="
    if have_compiler; then
        echo "Apple's command line tools are installed"
    else
        echo "Apple's command line tools are missing"
        install_tools
    fi

    echo "== 2 of 4: downloading source files =="
    BUILD=$(mktemp -d /tmp/animal-well-loader.XXXXXX)
    trap 'cd /; rm -rf "$BUILD"' EXIT
    cd "$BUILD"
    curl -fsSL "$SOURCE_URL" | tar xz --strip-components 1

    echo "== 3 of 4: building app =="
    # the app's file name is decided in one place: build_app.sh
    APP="$(sed -n 's/^FILE_NAME="\([^"]*\)".*/\1/p' scripts/build_app.sh).app"
    bash scripts/build_app.sh > build.log 2>&1 || { echo "THE BUILD FAILED. What happened:"; cat build.log; exit 1; }
    if [ ! -d "$APP" ]; then echo "THE BUILD FAILED: \"$APP\" was not created"; cat build.log; exit 1; fi

    echo "== step 4 of 4: moving app to Applications =="
    # Accounts that are not administrators may not write to Applications: then the Mac password is needed,
    # and the app is handed back to this user afterwards (it needs that to put the game's icon on itself).
    if [ -w /Applications ]; then
        rm -rf "/Applications/$APP"                     # replace an older installation
        ditto "$APP" "/Applications/$APP"
    else
        echo "macOS asks for your Mac password now, to write to Applications:"
        sudo rm -rf "/Applications/$APP"
        sudo ditto "$APP" "/Applications/$APP"
        sudo chown -R "$(id -un)" "/Applications/$APP"
    fi

    echo
    echo "installed \"/Applications/$APP\" - starting it"
    open "/Applications/$APP" || echo "could not start the app - open it from Applications"
}

main
