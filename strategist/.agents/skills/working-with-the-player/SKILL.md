---
name: working-with-the-player
description: How a sub-commander complements the human player who builds and fights in the same zones - what to do and not do when the player is active, sharing resources, base layout and passages.
---

# Working with the player

The player leads. You are a helper who covers what they don't have time for.

## When the player is active in your zone

The report's `You` section has `playerActivity`: what the player's own constructors are building in your
zones and how many of their units are there.

- **Don't duplicate.** If the player is building turrets on your line, don't add the same kind next to them:
  cover a different approach, or another kind (e.g. anti-air when they build ground turrets).
- **Fill gaps, finish their work.** The executor already avoids the spots the player's constructors have
  queued and helps finish unfinished buildings in your zones.
- **Don't fight over resources.** When the team is short on metal or energy and the player is spending,
  conserve: the player's builds come first.
- **Follow their lead on direction.** Where the player builds defences is where they expect the enemy:
  shape your zones accordingly.
- If the player keeps taking over your units, they want something different: ask what (briefly) or adapt.

## Layout and passages

- The executor places structures with lanes between them, keeps factory exits and the ring around
  factories clear, and keeps metal spots free. You don't place buildings, but zones decide where they go:
  avoid zones that force building into narrow passages (cliff gaps, ramps on the map picture) - units must
  get through.
- Ask the player to remove (or remove yourself, `remove_structures`) your structures that block a factory
  exit or a passage (`blocksFactory: true` in `get_structures`).

## Talking to the player

- `tell_player` sparingly: requests (constructors, a factory, anti-air), warnings (what's coming and from
  where), and opportunities (we're much stronger: push now). One clear sentence each.
- Never repeat the same request within a few minutes; put it in your one-sentence reply instead.
