# AltStore — automatic 7-day renewal

The app is signed by a free Personal Team, so Apple issues a profile valid for
**7 days**. Until now that meant re-installing from this Mac by cable every
week. AltStore replaces that: it re-signs the installed app in the background
over Wi-Fi, so the clock restarts without anyone touching a cable.

**What it does not do is remove the 7-day limit.** It just renews it for you,
and only while the conditions below hold. Read "When it will not refresh"
before trusting it.

## What is already done

`AltServer.app` 1.7.2 is installed in `/Applications` — downloaded from the
link on altstore.io, Developer ID–signed by `Yvette Testut (6XVY5G3U44)` and
accepted by Gatekeeper as notarized. Nothing else on the Mac has been changed.

## One-time setup, on this Mac

1. Launch **AltServer**. It has no window — it lives in the menu bar (a
   small diamond icon near the clock).
2. Add it to **System Settings → General → Login Items → Open at Login**.
   AltStore can only refresh while AltServer is running.

## One-time setup, per phone

Do all of this once per phone. A phone that has already been installed to by
`devicectl` is paired with the Mac and has Developer Mode on already, so steps
3 and 5 may already be true for it.

1. **Cable the phone to the Mac** and unlock it. Cable is required for this
   part; only the later refreshes are wireless.
2. In **Finder**, select the phone in the sidebar and tick
   **"Show this iPhone when on Wi-Fi"**. Without this, AltServer cannot reach
   the phone once the cable is gone, and refresh silently never happens.
3. On the phone: **Settings → Privacy & Security → Developer Mode** → on.
4. Menu bar → **AltServer → Install AltStore → <phone>**. It asks for an
   Apple ID; use **the same one the phone is already signed with**, so the app
   keeps the App ID it has today — a different Apple ID installs a second copy
   beside it. Expect a two-factor code prompt. If macOS asks to
   enable a **Mail plug-in**, follow its instructions — that is AltServer's
   documented install path, not a compromise.
5. On the phone: **Settings → General → VPN & Device Management** → tap the
   Apple ID entry → **Trust**.
6. Open **AltStore** on the phone once and let it finish signing in.

## Installing the app, and every update after

```bash
./Scripts/package-ipa.sh          # -> build/RemoteControl.ipa
```

Then, on each phone:

1. **AirDrop** `build/RemoteControl.ipa` to the phone → **Save to Files**.
2. **AltStore → My Apps → `+`** (top left) → pick `RemoteControl.ipa`.

AltStore re-signs it with the Personal Team and installs it. Because the
bundle id (`com.example.RemoteControl`) and the team are unchanged, this
replaces the copy `devicectl` installed rather than sitting beside it.

Two things to expect on that first replace:

- **Local Network permission is asked again.** Allow it, or discovery finds
  nothing at all.
- **The stored TV pairing may be lost.** This has been seen once across a
  re-install and the cause was never found (see HANDOFF, "Open known
  issues"). If the TV is gone from the list, pair again — it takes a minute.

## How the refresh works

AltStore tries to refresh throughout the week. A refresh needs **all** of:

- AltServer running on this Mac,
- the Mac **awake** — a closed lid or a sleeping Mac is not reachable,
- the Mac and the phone on the **same Wi-Fi**.

It only has to succeed **once per 7 days**, so an M1 laptop opened at home
most days is normally enough. The safety net is manual: open AltStore →
**My Apps → Refresh All** while both are on the network.

## When it will not refresh

Any of these means the 7 days runs out and the app stops launching, exactly
as before:

- The Mac stayed shut, or off the home Wi-Fi, for a whole week.
- AltServer was not running (check the menu bar icon after a restart —
  this is what Login Items is for).
- "Show this iPhone when on Wi-Fi" was never ticked for that phone.
- The phone was off the network for the week. Each phone has its own 7-day
  clock, so a second, less-used phone is the easier one to forget.

Recovering costs nothing: re-run `Scripts/package-ipa.sh`, AirDrop, install
from AltStore again. Installed app data survives; the pairing caveat above
applies.

## Limits worth knowing

- **Three sideloaded apps at a time** on a free Apple ID. AltStore itself
  occupies one, RemoteControl the second. One slot is left.
- Refreshing reuses the App ID that already exists, so Apple's weekly
  App-ID quota is not consumed by renewals.

## The cable path still works

Nothing was removed. `xcrun devicectl device install app …` (HANDOFF, "How to
run") still installs the `.app` directly, and remains the fastest way to test
a build without going through Files.

## If you would rather not run any of this

A paid Apple Developer account ($99/yr) issues **1-year** profiles. No
AltServer, no Login Item, no weekly window to miss, and the plain `devicectl`
install becomes an annual chore instead of a weekly one.

## Sources

- [AltStore Classic — AltServer](https://faq.altstore.io/altstore-classic/altserver)
- [AltStore Classic — how to install (macOS)](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos)
- [AltStore Classic — Your AltStore](https://faq.altstore.io/altstore-classic/your-altstore) (the three-app limit)
