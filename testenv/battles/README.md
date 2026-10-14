# Battle specs (scenario `battle`, testenv/LuaUI/Widgets/zz_sctest.lua)

One engagement each: `us <unit> <n>` (our Army sub-commander, full autonomy), `them <unit> <n>` (NullAI:
they stand and fight back), `distance <elmos>`, `seconds <limit>`, `# name` first. Mirrors (the same army
on both sides) measure our micro alone. Batches rotate through the specs by game number:

    SCENARIO=battle BATTLES=testenv/battles testenv/force-batch.sh 36    # 6 specs x 6
    go run ./cmd/gamereport -battles testenv/batch/<dir>                 # efficiency per spec

Efficiency = their share of metal lost / our share lost (2 = we traded twice as well).
