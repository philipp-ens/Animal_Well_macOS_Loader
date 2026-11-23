# Animal Well Loader
[Status](#status) | [Requirements](#requirements) | [Installation](#installation) | [Build](#build) | [App-Start](#app-start) | [Save Files](#save-files) | [Steam Cloud](#steam-cloud) | [Steam](#steam) | [Files](#files) | [Disclaimer](#disclaimer)

Runs the Windows version of **ANIMAL WELL** on a Mac, using your own copy of the game.

This is an unofficial fan project. It is not affiliated with or endorsed by the game's developer or publisher.
**This is not the full application. You need to own ANIMAL WELL on Steam or already have a copy of the game.**

The app loads the game's program code from the exe and supplies the parts the game normally gets from Windows:
graphics (Metal), sound, input, save files and Steam. It can also keep your save in the Steam Cloud, which the
Steam app itself does not do for this game on a Mac.

## Status

Playable from start to finish in my testing: picture, sound, keyboard, controller, saving, Steam Cloud saves,
Steam achievements and the Steam overlay.

|               |                                                                                                 |
|---------------|-------------------------------------------------------------------------------------------------|
| Tested on     | Apple Silicon Mac (through Rosetta 2)                                                           |
| Not tested on | Intel Macs. The app is built for Intel processors, so it should run there, but nobody has tried |
| Game Version  | Steam build 16245418 (depot 813231, manifest 8951799273146338346)                               |


| Limitations                                                                                      |
|--------------------------------------------------------------------------------------------------|
| Controller rumble, and the controller speaker and haptics the game uses on some pads do not work |
| Any version of the exe other than the supported one does not work                                |
| Starting from the game's own Steam library entry does not work                                   |

## Requirements

- A Mac with macOS 11 or later. On Apple Silicon, Rosetta 2 must be installed:
  `softwareupdate --install-rosetta --agree-to-license`
- Apple's command line tools, to build the app: `xcode-select --install`
- A Steam account that owns ANIMAL WELL or an already existing copy of the game.

## Installation

With this command:
```bash
curl -fsSL https://raw.githubusercontent.com/philipp-ens/Animal_Well_macOS_Loader/main/scripts/install.sh | bash
```
Or with the package provided in the release. The problem is, it is not trusted by Apple and I am not willing to pay them 99$ so it will be.
You'll have to run it and then go to Settings -> Privacy & Security, scroll down and allow it to open anyway.

## Build

Clone the project into a folder. From this folder, run:

```bash
bash scripts/build_app.sh
```

This creates `Animal Well x86.app` in the same folder.

## App-Start

The app needs the file `Animal Well.exe` from the Windows version of the game. If it does not know one yet, it
asks how you want to provide it:

- **Choose a File…** – if you already have the file on this Mac, for example copied from a Windows PC
  (`…\Steam\steamapps\common\Animal Well\Animal Well.exe`).
- **Download with SteamCMD** – SteamCMD is Valve's own command-line download tool. A Terminal window opens,
  downloads SteamCMD from Valve and asks for your Steam account name, password and Steam Guard code. You type them
  into SteamCMD; the app never sees them. The Terminal window closes by itself when the download is done.
- **Download with the Steam App** – the app opens the console of your running Steam app and copies a download
  command to the clipboard. You paste it into the console and press Return.

Both downloads fetch 30 MB and only work for an account that owns the game. They can take several minutes, because
Steam sometimes picks a slow server and shows no progress while it waits.

The file is kept in `~/Library/Application Support/Animal Well/`. From the second start on, the app goes straight
into the game. To pick a different file later, use **Choose Another Game File…** in the app's menu.


## Save files

The save is `~/Library/Application Support/Animal Well/AnimalWell.sav`. **Show Save Folder** in the app's menu
opens the folder.

The file has the same format as on Windows, so you can bring your progress along. On Windows the save is at

```
%USERPROFILE%\AppData\LocalLow\Billy Basso\Animal Well\AnimalWell.sav
```

Copy it into the folder above before starting the app. The first time the game saves, the app keeps the previous
file as `AnimalWell.sav.bak`.

You do not have to copy it by hand: the app can keep the save in line with the Steam Cloud, see the next section.

## Steam Cloud

I needed to write my own version of this, the Steam app on a Mac does not sync, because
the game has no Mac version.

In the game's main menu choose **mods**, then **steam cloud**, and sign in to Steam, once:

- **With a QR code** – scan it with the Steam mobile app (Steam Guard tab, "Scan a QR code") and approve. The loader
  never sees your password.
- **With your account name and password** – if you do not use the Steam mobile app. The password is sent to Steam
  only, encrypted with Steam's own key, and is not kept. If your account has Steam Guard, the loader asks for the
  code.

## Steam

Steam is optional. If the Steam app is running and logged in when you start Animal Well x86:

- achievements you earn count for the real game on your Steam account,
- Steam shows you as playing ANIMAL WELL,
- the Steam overlay works (Shift+Tab).

The window title reads `ANIMAL WELL - Steam connected` when the connection is up.

### The game cannot be started from its entry in your Steam library. Steam offers no Play button on a Mac for a game without a Mac version

If you really want to turn the Steam overlay off:
```bash
defaults write local.animalwellloader NoOverlay -bool YES
```

## Files

| Location | Contents |
|---|---|
| `~/Library/Application Support/Animal Well/` | the game file, the save and its backups, `AnimalWell.sav.cloudsync` (what the Steam Cloud sync remembers), `loader.log` |
| `~/.animalwellloader/` | SteamCMD and temporary files of the SteamCMD download. Safe to delete at any time |
| settings `local.animalwellloader` | the remembered game file and Steam library |
| Keychain entry `local.animalwellloader.steam` | the Steam sign-in for the Steam Cloud sync |


## Disclaimer

ANIMAL WELL is the work of Billy Basso (Shared Memory) and is published by Bigmode. All rights to the game belong
to them. This project is not connected to them, includes no part of the game, and is useless without a copy of the
game that you own. If you like the game, buy it. (It is so fucking worth it)
