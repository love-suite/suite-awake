# Awake

Keeps your Mac awake, part of Love Suite: until you stop it, for a while (15 minutes to 5 hours) or until
a time you choose. Click its cup in the menu bar to start, click again for the time left, Stop and the
options. Optionally the Mac stays awake with its lid closed and no external display ("Lid Closed": on
power only, a few hours at most, never when it is hot), or the screen turns off after a minute or two
without use while the Mac keeps working ("Screen Off, Mac On"). It stops by itself on low battery, in Low
Power Mode and when the Mac gets too hot. Nothing changes until you turn it on.

Install: `brew install --cask love-suite/tap/awake` (once the first release is out).

Development: `swift build`, `swift test`, `scripts/make-app.sh` (Swift 6.4.2, macOS 13 or later).
