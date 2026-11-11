# A2B Race

Point-to-point races for BeamMP. The host picks a start (A) and a finish (B), invites players into a party and presses Start. Every racer is teleported to A, repaired, and held for a 10-second countdown (engines can rev, cars can't move). Then it's GO: take any route you like. The first car to reach B wins, with light beams, strobes, confetti and a fanfare. Everyone else blows up, one at a time, from 2nd place to last.

**One life.** During a race, pressing R (reset), Insert (rewind), Home, the repair option or Ctrl+R, teleporting on the map, or switching to another car puts you back at A, repaired. You have to drive the whole way.

Works with any stock or modded vehicle. The grid is spaced for the biggest car in the party.

## Install

**BeamMP server:** unzip `A2BRace-Server-<version>.zip` into the server folder so that you get:

```text
Resources/Client/a2brace_d3k1d.zip
Resources/Server/A2BRace/main.lua
Resources/Server/A2BRace/lib/core.lua
```

Then restart the server. Players download the client mod automatically when they join.

**Single-player (practice):** put `a2brace_d3k1d.zip` in your BeamNG `mods` folder. You can host a party of one and race solo to B.

## How to race

1. Add the **A2B Race** app to your HUD: Esc → UI Apps → Add app → *A2B Race*. Click the 🏁 bar to open the race window.
2. Click **Host a race**.
3. Set **A** and **B**:
   - **My spot:** where you are standing or driving right now. A faces the way you're facing.
   - **Map pin:** open the big map (M), click a spot so a route appears, close the map, then press *Map pin*. If you pick A this way, the grid faces towards B.
4. **Invite** players from the list. They get a message and an Accept button in their A2B Race window.
5. Click **START RACE**.

The host can remove a point (and its marker) with the ✕ next to it. Anyone can hide the A/B markers for themselves with **Show the A / B markers**.

When someone wins, every player on the server sees the celebration: a light pillar and searchlight beams hundreds of metres into the sky, fireworks bursting overhead, and confetti.

You stay in your party after the race, so the host can set up the next one right away. Leave with **Leave party**, or accept someone else's invite. If the host leaves, the next player becomes host. The host can also stop a race in progress.

If you're walking when the race starts, you're put into the last car you drove.

## Rules in detail

| Situation | What happens |
| --- | --- |
| Countdown | Brakes held and gearbox disconnected, so you can rev but not move. Creeping more than 3 m off your grid spot puts you back. |
| Reset / repair / rewind / reload | Teleported back to your grid spot at A, repaired. The race goes on. |
| Teleport (big map, etc.) | Same: back to A. |
| Switch to another car of yours | Put back in your race car at A. |
| Get out and walk | Allowed. Only your race car can finish. |
| Finish | Your race car within 12 m of B. First finish wins and ends the race. |
| Losers | Ranked by distance to B when the winner finished. 2nd blows up 2.5 s later, then one more every 1.5 s. |
| Race car deleted | You're out of that race. |

## Files

| Path | What it is |
| --- | --- |
| `mod/lua/ge/extensions/a2brace/core.lua` | The rules: parties, invites, grid, countdown, winner, explosion order. Pure Lua; the server and single-player both run this file. |
| `mod/lua/ge/extensions/a2brace/main.lua` | In-game side: teleport, freeze, one-life rule, finish detection, effects, A/B markers. |
| `mod/ui/modules/apps/A2BRace/` | HUD app: party window, countdown and result overlay. |
| `beammp-server/A2BRace/main.lua` | BeamMP server plugin (loads `lib/core.lua`). |
| `build.ps1` | Builds `dist/a2brace_d3k1d.zip` and the server pack. |

## Network messages

There is one BeamMP event each way, `a2b`, carrying JSON `{"e": "<event>", ...}`. Events are listed at the top of `core.lua`. Messages are small (a few hundred bytes), and the server escapes the text `Zp` to stay clear of the BeamMP launcher bug with large events.

## Status

Version 0.1.0 works in single-player (solo race tested in game). The rules also pass a simulated 4-player race offline. **Multiplayer has not been tested yet.** These parts need checking on a BeamMP server:

- The server plugin loading `lib/core.lua`.
- Invites, the shared countdown and GO.
- The reset rule with BeamMP's own reset handling.
- Explosions and celebrations on other players' cars.
