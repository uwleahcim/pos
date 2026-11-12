# Setting up a Mac for development

What a fresh Mac needs to build and run everything in this repository: the terminal app on the Mac itself,
on an iPad, an iPhone and a Galaxy tablet; the backend and its tests; and the hub and the PBX over SSH. The
steps are in the order to do them, each with its check. About two hours in all, most of it downloads: start
the Xcode download first and do the rest while it comes.

Every version here comes from the repository, so the new Mac builds what CI builds:

| What | Version | Where it is pinned |
| --- | --- | --- |
| Xcode | The current one (27 at the time of writing) | The app builds for iOS 15 and macOS 12 or later (`apps/pos_app/ios`, `apps/pos_app/macos`) |
| Flutter | The stable channel (3.47 at the time of writing), with Dart 3.13.7 or later | `apps/pos_app/pubspec.yaml` (`sdk: ^3.13.7`), `pubspec.lock` (`flutter: ">=3.44.0"`); CI installs stable 3.47.x: Flutter 3.50 (2026-11-11) deprecates `package:flutter/material.dart` for `package:material_ui`, which builds and runs but fails CI's `flutter analyze` until the app's imports move |
| Android Studio | The current one, for the Android SDK and its own Java (17 or later) | `android/settings.gradle.kts` (Android Gradle plugin 9.1.0, Kotlin 2.4.0), `gradle-wrapper.properties` (Gradle 9.3.1), `app/build.gradle.kts` (Java 17); CI builds with Temurin 17 |
| Python | 3.12, with uv for the environment | `backend/pyproject.toml` (`requires-python >= 3.12`); CI and the hub image run 3.12 |
| ruff, pytest, Hypothesis | Current, from the `dev` extra | `backend/pyproject.toml`; CI runs `ruff check .` and `pytest` |
| Docker Desktop, shellcheck | Optional | Only to build the hub's image or lint the hub scripts the way CI's `hub` job does |

Not needed: CocoaPods (the iOS and macOS projects use Swift packages; there is no Podfile), a Java
installation of your own (Android Studio brings one), Chrome (`flutter doctor` lists it for web builds, which
the app does not make), and PostgreSQL (the backend and its tests run in memory without it).

## 0. What to copy from the old Mac, and what not to

Per-machine things that cannot be reinstalled, only copied. AirDrop or a USB stick between the two Macs.

- **`~/.ssh`**: the key GitHub, the hub and the PBX know, and `known_hosts`. Copy the whole folder, then
  `chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_*`. With it, nothing changes on GitHub, the hub or the PBX. To
  give the new Mac a key of its own instead, see step 9.
- **The Apple push key** `AuthKey_<KEYID>.p8` from `docs/push-relay.md`: Apple lets it be downloaded once,
  so copy it from wherever the old Mac keeps it (never into the repository). The hub already has it; the
  second hub will need it for `hubctl push apple`.
- **Xcode signing**: nothing to copy. Xcode makes this Mac its own Apple Development certificate the first
  time it signs the app for the team (the team, N46M58VZD4, is in `ios/Runner.xcodeproj` already). To keep
  one certificate across both Macs, export it from the old one instead: Xcode, Settings, Accounts, the
  Apple ID, then "Export Apple ID and Code Signing Assets", and import the file on the new Mac.
- **Not** the `~/pos` checkout: clone it fresh (step 5); the old checkouts drifted apart more than once.
  Not the Flutter SDK, Android Studio or `DerivedData` either; install them fresh.

Apple's Migration Assistant copies all of the above at once, Xcode and Homebrew included, if the old Mac is
at hand; afterwards do steps 3 (`flutter doctor`), 5 (a fresh clone) and 6, and skip the rest. The steps
below are for a Mac set up from nothing.

## 1. Xcode

1. App Store, **Xcode** (about 15 GB installed; the longest download of the day). Open it once and let it
   install its components.
2. Point the command-line tools at it and accept the license:

   ```
   sudo sh -c 'xcode-select -s /Applications/Xcode.app/Contents/Developer && xcodebuild -runFirstLaunch'
   sudo xcodebuild -license accept
   ```

3. The iOS platform and Simulator (needed only to run on the Simulator; harmless otherwise):

   ```
   xcodebuild -downloadPlatform iOS
   ```

   Xcode 27 calls the Simulator app Device Hub (`open -a DeviceHub`); earlier Xcodes, `open -a Simulator`.
4. Xcode, Settings, Accounts, **+**: the Apple ID of team N46M58VZD4 (the paid Apple Developer Program, which
   push needs). Automatic signing does the rest in step 6.

Check: `xcodebuild -version` prints Xcode 27 or newer.

## 2. Rosetta, Homebrew, git

```
sudo softwareupdate --install-rosetta --agree-to-license
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Flutter's own install guide still asks for Rosetta 2 on Apple silicon, for a few of its tools. Homebrew
prints two lines at the end that put it on the PATH (`eval "$(/opt/homebrew/bin/brew shellenv)"` in
`~/.zprofile`): run them, then open a new terminal window.

```
brew install gh uv
git config --global user.name "Michael Wu"
git config --global user.email "<the address on your GitHub account>"
```

The identity matters: commits made on the second Mac without it carry `michaelwu@Michaels-MBP-2.localdomain`
as their author, which GitHub cannot tie to you. The same goes for anything else that commits from this Mac
(the Gemini edits came from the second Mac that way).

Check: `brew doctor` says ready to brew; `git config --global --list` shows both lines.

## 3. Flutter

```
brew install --cask flutter
flutter --version
flutter doctor
```

The cask installs the stable channel, as the second Mac has it and as CI builds; `flutter upgrade` keeps it
current from then on. The zip from https://docs.flutter.dev/get-started/install/macos/mobile-ios unpacked
into `~/development/flutter` (and `export PATH=$HOME/development/flutter/bin:$PATH` in `~/.zshenv`) does the
same.

`flutter --version` must say Flutter 3.47 or newer on channel stable and Dart 3.13.7 or newer, which is what
`pubspec.yaml` asks for. Until step 4 the doctor's Android lines are still red; the two lines it keeps are
fine:

- `CocoaPods not installed` under Xcode: not used. Flutter has used Swift packages by default since 3.44 and
  the two Xcode projects were migrated (no `Podfile`, a `FlutterGeneratedPluginSwiftPackage` dependency in
  each). Only a new plugin that offers no Swift package would bring CocoaPods back (`brew install cocoapods`).
- `Chrome` missing: the app has no web build.

## 4. Android Studio, for the Galaxy tablet

```
brew install --cask android-studio
```

Open Android Studio once and take the standard setup, which downloads the SDK and the platform tools. Then in
its SDK Manager (**More Actions** on the welcome screen, or Settings, Languages & Frameworks, Android SDK):

- **SDK Platforms**: the newest Android. Gradle fetches any other platform or NDK the Flutter plugin asks for
  once the licenses are accepted.
- **SDK Tools**: Android SDK Command-line Tools (latest), Android SDK Platform-Tools, Android SDK
  Build-Tools, Android Emulator (optional).

Then accept the licenses and look again:

```
flutter doctor --android-licenses
flutter doctor
```

No Java of your own: Flutter builds with the Java inside Android Studio (`flutter doctor -v` names it), and
anything from 17 up suits Gradle 9.3.1 and the Android Gradle plugin 9.1.0; CI uses Temurin 17. Android
Studio's Flutter and Dart plugins are optional (Settings, Plugins); the command line is enough.

The tablet itself: Developer options (tap Build number seven times), USB debugging, and Samsung's Auto
Blocker off, as the "Android tablets and phones" section of `apps/pos_app/README.md` describes.

Check: `flutter doctor` is green on Flutter, Android toolchain, Xcode (the CocoaPods line aside) and Android
Studio.

## 5. GitHub and the clone

The repository is private, so git needs your GitHub login first. `gh` stores it for git over HTTPS:

```
gh auth login --hostname github.com --git-protocol https --web
gh repo clone uwleahcim/pos ~/pos
```

With the SSH key copied in step 0, `git clone git@github.com:uwleahcim/pos.git ~/pos` works as well, and
`gh auth login` is still worth doing for `gh pr list`, `gh run download` (the CI APK) and the like.

Keep `~/pos` as the path: the other Macs use it, and the notes in the project refer to it. Flutter and Xcode
rewrite some files for the machine they run on (`build/`, `.dart_tool/`, every `ephemeral/` folder,
`android/local.properties`); they are ignored. If a `git pull` is ever refused over one of them, run
`git checkout -- <the paths it lists>` from the repository root and pull again (`apps/pos_app/README.md`).

Check: `cd ~/pos && git log --oneline -3` shows the latest commits on `main`.

## 6. The app

```
cd ~/pos/apps/pos_app
flutter pub get
flutter run -d macos --release
```

The first build downloads the WebRTC framework for the phone (a few minutes); macOS asks for the camera and
the microphone the first time the app uses them. On its first start the app asks for a device name and the
backend addresses: a new name, letters and digits (`mac3`, since `mac1` and `mac2` are the other two Macs),
and `http://172.19.1.179:8000` for the hub, which answers only from the restaurant's network. Sign in with a
PIN (Mike 9999 among the demo staff).

What CI runs on every push, to run before pushing:

```
dart format -l 120 --set-exit-if-changed lib test
flutter analyze
flutter test
```

**iPhone and iPad.** Plug the device in, unlock it, tap Trust, then:

```
flutter devices
flutter run -d <the device's id> --release
```

The first run on a device from this Mac takes a minute of Xcode's signing: the project carries the team, and
Xcode makes this Mac's development certificate and the provisioning profile on its own (a "codesign wants
to access key" dialog: your Mac password, **Always Allow**). On an iPhone that has never run a build from
this Mac, iOS asks to turn on Developer Mode (Settings, Privacy & Security; it restarts the phone), and
if it answers "Untrusted Developer" on launch, Settings, General, VPN & Device Management, trust the team.
A release build stays installed when the cable comes out; a debug build runs only while `flutter run` is
attached. Xcode may edit `ios/Runner/Info.plist` when the workspace is opened; `git checkout -- ios/Runner/Info.plist`
puts it back.

**Galaxy.** With USB debugging on, `flutter run -d <its id> --release`; or install the APK that CI builds, as
the app README describes.

Check: an order placed from the Mac app shows up on the other terminals and prints when fired.

## 7. The backend

```
cd ~/pos/backend
uv venv --python 3.12 .venv && uv pip install -e '.[dev]'
.venv/bin/ruff check .
.venv/bin/pytest
.venv/bin/python -m pos.sync.simulate --replicas 4 --rounds 300 --drop 0.3
```

`uv` downloads Python 3.12 itself if the Mac has none. The tests run in memory; the one PostgreSQL test
(`tests/test_pgstore.py`, and a few in the face and menu tests) skip themselves unless `POS_TEST_DATABASE_URL`
is set, and CI runs them. Kitchen
tickets are rendered with a font that covers Chinese, and the renderer finds the Mac's own PingFang, so
nothing to install.

A backend on the Mac itself, for a build of the app with no hub in reach (in memory, with the restaurant's
menu from the bundled export and the demo staff):

```
.venv/bin/uvicorn pos.api.app:app --reload
```

and `http://127.0.0.1:8000` as the address in the app. The printers on the restaurant's network can be
driven from the Mac too: `.venv/bin/python -m pos.printing --printer 172.19.1.162 demo` prints the demo
ticket (`spikes/printing/README.md`).

Check: `ruff check .` is clean and `pytest` ends with every test passed and about twenty skipped (the
PostgreSQL ones, with no database).

## 8. Docker Desktop and shellcheck (optional)

CI's `hub` job builds the backend image and lints the hub scripts; to do the same on the Mac before a change
to `backend/Dockerfile` or `infra/hub`:

```
brew install --cask docker     # Docker Desktop; open it once
brew install shellcheck
cd ~/pos
docker build -t pos-backend:local backend          # the first build downloads the two face models, about 290 MB
POSTGRES_PASSWORD=x docker compose -f infra/hub/docker-compose.yml config -q
shellcheck infra/hub/bootstrap.sh infra/hub/hubctl
```

Docker also gives the PostgreSQL that the skipped test wants:

```
docker run -d --name pos-pg -e POSTGRES_USER=pos -e POSTGRES_PASSWORD=pos -e POSTGRES_DB=pos -p 5432:5432 postgres:16-alpine
cd backend && POS_TEST_DATABASE_URL=postgresql://pos:pos@localhost:5432/pos .venv/bin/pytest
```

## 9. The hub and the PBX over SSH

The hub (`pos-hub1`, 172.19.1.179) takes SSH and API calls from the restaurant's network only (its firewall,
`infra/hub/README.md`), so the Mac must be on that Wi-Fi or a cable there; nothing reaches it from home.
`hubctl` runs on the hub, not on the Mac.

```
curl http://172.19.1.179:8000/health
ssh <your user on the hub>@172.19.1.179        # or pos-hub1.local
hubctl status
```

After a merge, on the hub: `hubctl update`, then `hubctl menu import --apply` when the merge changed the
bundled menu files (`infra/hub/README.md`, "Day to day"). The push key goes to the hub with
`scp AuthKey_XXXX.p8 <your user>@172.19.1.179:` and `hubctl push apple` (`docs/push-relay.md`, step 5);
hub 1 has it already.

The hub's `authorized_keys` holds the keys GitHub had for `uwleahcim` when Ubuntu was installed, and the PBX's
root account holds the old Mac's key, so the copied `~/.ssh` opens both at once. For a key of this Mac's own:

```
ssh-keygen -t ed25519 -C mac3
gh ssh-key add ~/.ssh/id_ed25519.pub --title mac3        # GitHub, so clones and pushes work
```

then on the hub, from the old Mac or its console, `ssh-import-id gh:uwleahcim` (part of Ubuntu Server;
`sudo apt install ssh-import-id` if it is missing) pulls every key on your GitHub account into
`authorized_keys`; and for the PBX, from the old Mac:

```
ssh root@freepbx.chinasky.org 'echo "<the new public key, one line>" >> ~/.ssh/authorized_keys'
```

The PBX's firewall answers SSH from the restaurant's address (its Trusted zone, `spikes/softphone/README.md`,
step 6); from elsewhere it drops the connection.

Check: `ssh root@freepbx.chinasky.org 'asterisk -rx "core show version"'` prints the Asterisk version, and
`hubctl status` on the hub shows the services up.

## Before the first pull request from this Mac

Every piece of work starts on a fresh branch from `main`, and CI must be green before a merge: the app's
format, analysis and tests (step 6), the backend's lint, tests and sync simulations (step 7), and the hub
image (step 8, or leave it to CI). After the merge: `hubctl update` on the hub, then the app rebuilt on each
device with `flutter run --release`.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `flutter doctor`: `CocoaPods not installed` | Expected: the projects use Swift packages | Nothing; see step 3 |
| `flutter doctor`: `Android sdkmanager not found` or `Some Android licenses not accepted` | The command-line tools are missing, or the licenses | SDK Manager, SDK Tools, Android SDK Command-line Tools; then `flutter doctor --android-licenses` |
| `flutter doctor`: `Unable to find bundled Java version` or a Gradle error about the Java version | Flutter found no Java, or one older than 17 | Install Android Studio (step 4); or `flutter config --jdk-dir "/Applications/Android Studio.app/Contents/jbr/Contents/Home"` |
| `flutter --version` prints a Dart older than 3.13.7 and `pub get` refuses the SDK constraint | An old Flutter | `flutter channel stable && flutter upgrade` |
| `git clone` asks for a password, or `Permission denied (publickey)` | No GitHub login on this Mac | Step 5: `gh auth login`, or the key from step 0 or 9 added to GitHub |
| `git pull` refused: local changes would be overwritten | Flutter rewrote a generated file that an old commit tracked | `git checkout -- <the paths it lists>` from the repository root, then pull |
| Xcode: "No signing certificate" or "No profiles for org.chinasky.posApp" | The team's Apple ID is not signed in to Xcode | Step 1, point 4; then open `apps/pos_app/ios/Runner.xcworkspace`, Runner, Signing & Capabilities, and let it fix the problem |
| `flutter devices` lists no iPhone | Locked, not trusted, or still on a wireless connection | Unlock, Trust, a cable; `flutter run --device-timeout 60 -d <id>` |
| The iPhone says "Untrusted Developer" | This Mac's new development certificate is not trusted on the phone | Settings, General, VPN & Device Management, trust it |
| The Galaxy is not listed, or the install fails | USB debugging off, the prompt on the tablet not accepted, or Auto Blocker on | `apps/pos_app/README.md`, "Android tablets and phones" |
| `curl http://172.19.1.179:8000/health` hangs or `ssh` times out | The Mac is not on the restaurant's network | Join it; the hub's firewall takes nothing from outside |
| `ssh root@freepbx.chinasky.org` times out | The PBX's firewall does not know the address you are at | Connect from the restaurant's network, or add the address under Connectivity, Firewall, Networks there |
| `pytest`: about twenty `skipped` | The PostgreSQL tests with no database | Expected; step 8 runs them |
| The app build fails on `flutter_webrtc` or `camera` with a CocoaPods message | A plugin update without a Swift package made Flutter fall back to CocoaPods | `brew install cocoapods`, then build again |
