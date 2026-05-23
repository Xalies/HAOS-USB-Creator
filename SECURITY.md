# Security Policy

HAOS AIO USB Creator is a disk imaging tool. Bugs in disk detection, confirmation, image verification, or write protection can cause data loss.

## Reporting Issues

Please report security or destructive-write issues through GitHub Issues, or privately if the issue could put users' data at immediate risk.

When reporting, include:

- the app version or commit
- Windows version
- whether the issue happened in the Windows app or Linux installer
- the exact drive layout if relevant
- logs if available

Avoid posting logs publicly if they contain information you do not want to share, such as disk serial numbers, usernames, or local paths.

## Safety-Sensitive Areas

Issues in these areas should be treated as high priority:

- writing to the wrong disk
- allowing the installer USB to be selected as a target disk
- skipping confirmation before destructive writes
- using an unverified Home Assistant OS image when a verified image is required
- unattended install loop protection failures
- failures that leave a disk partially written without a clear error
