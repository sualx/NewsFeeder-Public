# NewsFeeder

NewsFeeder is a Windows desktop application for reading selected news feeds and watching web pages for visible text changes. It is built with PowerShell 7 and Windows Forms.

## Windows only

NewsFeeder depends on Windows Forms, Windows Script Host, the Windows registry, and Windows desktop APIs. It is not intended for macOS or Linux.

## Download

NewsFeeder is currently distributed as a source version for people who already have PowerShell 7. The download always contains the latest version from the public `main` branch.

[Download NewsFeeder](https://github.com/sualx/NewsFeeder-Public/archive/refs/heads/main.zip)

Source-version requirements:

- Windows
- [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)
- Internet access for feeds and watched pages
- A writable extracted folder so NewsFeeder can create its local `data` directory

## Features

- 20 built-in RSS or Atom sources: 12 Security, 4 Good News, and 4 Science
- Any non-empty combination of the three modes can be active
- Individual feeds can be enabled or disabled in Settings
- Downloaded news history with live local search by source, title, or category
- User-defined HTTP or HTTPS pages watched for visible text changes
- Configurable feed and page-check intervals, with polite minimum intervals
- Top-right desktop notifications with optional sound
- Notification sound is suppressed while Windows is locked or the screen saver is running
- Tray operation, optional minimized startup, and optional launch at Windows sign-in
- Local JSON state with feed-item deduplication

## Run the source version

1. Download or clone the repository into a normal writable folder.
2. Confirm that PowerShell 7 is installed by opening **Start** and searching for **PowerShell 7**.
3. Double-click `NewsFeeder.vbs` for a silent launch.
4. Use **Settings** to select individual sources, configure watched pages, and choose startup and notification options.
5. Use the Security, Good News, and Science checkboxes in the main window to choose which modes are fetched and displayed.

`NewsFeeder.cmd` is included as a fallback launcher, but it may briefly show a console window.

## Local data and privacy

The installed version stores settings, downloaded history, seen-item identifiers, watched-page state, and error logs in `%LOCALAPPDATA%\NewsFeeder`. Uninstalling the program leaves this user data in place. The source version creates a `data` folder beside the application files; that folder is excluded from Git by `.gitignore`.

The application has no analytics or telemetry. Network requests go only to the configured feed URLs and user-added watched pages. Feed and page content is treated as untrusted input: XML DTD processing is prohibited, displayed content is converted to plain text, and only HTTP or HTTPS links are opened.

## Behavior to know

- Feed checks have a minimum interval of 15 minutes.
- Watched-page checks have a minimum interval of 5 minutes.
- Notifications appear on the primary screen and remain for four minutes unless dismissed.
- A web publisher may temporarily reject requests or change or remove its feed. NewsFeeder reports source failures and retries on a later check.
- Page-change detection compares normalized visible text. Dynamic page text can therefore produce frequent changes.

## Files in the source version

- `NewsFeeder.ps1` - application
- `NewsFeeder.vbs` - preferred silent launcher
- `NewsFeeder.cmd` - fallback launcher
- `feeds.json` - built-in feed catalog
- `.gitignore` - excludes local application data
- `README.md` and `LICENSE` - documentation and license

## Build the release files

Maintainers need PowerShell 7 and Inno Setup 6. Run `./installer/Build-Release.ps1` to create `NewsFeeder-Setup.exe` and `NewsFeeder-Source.zip` under `artifacts`. The build downloads the pinned Microsoft PowerShell runtime and verifies its published SHA-256 hash before packaging it.

## License

NewsFeeder is available under the [MIT License](LICENSE).
