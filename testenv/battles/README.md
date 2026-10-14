# Battle specs (scenario `battle`, testenv/LuaUI/Widgets/zz_sctest.lua)

One engagement each: `us <unit> <n>` (our Army sub-commander, full autonomy), `them <unit> <n>` (NullAI:
they stand and fight back), `distance <elmos>`, `seconds <limit>`, `attack 1` (their units fight-move at ours, so we defend),
`# name` first. Mirrors (the same army
on both sides) measure our micro alone. Batches rotate through the specs by game number:

    SCENARIO=battle BATTLES=testenv/battles testenv/force-batch.sh 72    # 9 specs x 8
    go run ./cmd/gamereport -battles testenv/batch/<dir>                 # efficiency per spec

Efficiency = their share of metal lost / our share lost (2 = we traded twice as well).

Without `attack`, NullAI's units stand still: a cautious army that holds scores well against them (it
was how "send the whole army in" read worse). The `*-defend` specs have them attack, so a batch measures
both. Use batches that are a multiple of the number of specs (9: 54, 72).
