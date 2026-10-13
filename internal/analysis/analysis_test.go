package analysis

import (
	"bytes"
	"strings"
	"testing"
)

// a short harness log in the current format (eco / lost / killed lines)
const harnessLog = `[0] t=0s metal 1000/1000 +0.0 energy 1000/1000 +0.0
[891] player: legcom builds leglab at 4528,2208
[1800] t=60s metal 563/1200 +5.7 energy 70/1102 +76.4
[1800]   [1] Economy 1 economy/balanced B2 F1 C0 threats=0 spend=4.6 | legcom:Wind Turbine
[1800]      log: gave up on Radar Tower (couldn't start it)
[1800]      log: Wind Turbine (energy (short))
[1800] eco minute=1 metalIncome=5.7 energyIncome=76 mex=2 generators=3 factories=1 builders=1 army=0 turrets=0 energyStalled=4 metalOverflow=0
[2700] t=90s metal 490/1200 +5.7 energy 238/1153 +125.0
[2700]   [1] Economy 1 economy/balanced B3 F1 C0 threats=0 spend=6.9 | legck:busy
[2700]      log: gave up on Radar Tower (couldn't start it)
[2700]      log: lost Legion Construction Bot
[2900] lost minute=1 kind=constructor name=legck cost=130 x=100 z=200
[2950] lost minute=1 kind=anti-air_turret name=legrhapsis cost=200 x=100 z=200
[3000] killed minute=1 kind=raider name=armflash cost=100 x=10 z=20
[3600] t=120s metal 309/1200 +7.0 energy 929/1254 +169.8
[3600]   [1] Economy 1 economy/balanced B4 F1 C0 threats=0 spend=16.6 | legck:busy
[3600]      log: gave up on Radar Tower (couldn't start it)
[3600] eco minute=2 metalIncome=7.0 energyIncome=170 mex=3 generators=8 factories=1 builders=3 army=340 turrets=0 energyStalled=10 metalOverflow=0
[3700] RESULT LOSS (no units left) t=123s
[3700]   us:    metalProduced=11600 energyProduced=60000 unitsProduced=40 unitsKilled=1 unitsDied=2 damageDealt=500 damageReceived=1000 armyValue=0
[3700] DONE
`

func TestParseGame(t *testing.T) {
	g, err := ParseGame("1", strings.NewReader(harnessLog))
	if err != nil {
		t.Fatal(err)
	}
	if g.Result != "LOSS" || g.Detail != "(no units left)" || g.Seconds != 123 {
		t.Errorf("result %q %q %d", g.Result, g.Detail, g.Seconds)
	}
	if len(g.Eco) != 2 || g.Eco[1].Mex != 3 || g.Eco[1].Army != 340 || g.Eco[1].EnergyStalled != 10 {
		t.Errorf("eco %+v", g.Eco)
	}
	if len(g.Lost) != 2 || g.Lost[1].Kind != "anti-air turret" || len(g.Killed) != 1 || g.Lost[0].Cost != 130 {
		t.Errorf("lost %+v killed %+v", g.Lost, g.Killed)
	}
	if g.Stats["damageDealt"] != 500 || len(g.Player) != 1 {
		t.Errorf("stats %v player %v", g.Stats, g.Player)
	}
	// the same message in consecutive snapshots is one occurrence; it counts again after a gap
	if c := g.Logs["gave up on Radar Tower (couldn't start it)"]; c != 1 {
		t.Errorf("gave up counted %d times, want 1 (logs %v)", c, g.Logs)
	}
}

func TestOlderLogsFallBackToIncome(t *testing.T) {
	old := strings.ReplaceAll(harnessLog, "eco minute", "xeco minute")
	g, _ := ParseGame("old", strings.NewReader(old))
	if len(g.Eco) != 2 || !g.Eco[0].Partial || g.Eco[1].MetalIncome != 7.0 {
		t.Errorf("eco from status lines %+v", g.Eco)
	}
}

const datalog = `{"type":"start","game":"g","map":"Isidis","version":3}
{"type":"eco","team":0,"minute":2,"metalIncome":8,"mex":3,"factories":1,"army":100}
{"type":"eco","team":1,"minute":2,"metalIncome":10,"mex":4,"factories":1,"army":300}
{"type":"fight","team":0}
{"type":"eco","team":0,"minute":1,"metalIncome":4,"mex":2,"factories":1}
`

func TestBenchmarkAndFindings(t *testing.T) {
	rec, err := ParseDatalog("g.jsonl", strings.NewReader(datalog))
	if err != nil {
		t.Fatal(err)
	}
	if rec.Map != "Isidis" || len(rec.Teams[0]) != 2 || rec.Teams[0][0].Minute != 1 {
		t.Errorf("recorded %+v", rec)
	}
	// four copies so every band has enough players
	b := BuildBenchmark("test", []*Recorded{rec, rec, rec, rec})
	band, ok := b.Band(2, "mex")
	if !ok || band.P25 != 3 || band.P75 != 4 || band.N != 8 {
		t.Errorf("band %+v ok=%v", band, ok)
	}
	// findings at 5/8/12/15 min only: shift our game's minute 2 to 5 and the benchmark's too
	b.Minutes["5"] = b.Minutes["2"]
	g, _ := ParseGame("1", strings.NewReader(strings.ReplaceAll(harnessLog, "eco minute=2", "eco minute=5")))
	fs := Findings([]*Game{g}, b)
	text := ""
	for _, f := range fs {
		text += f.Text + "\n"
	}
	for _, want := range []string{"metal income at 5 min: 7, strong players 8-10", "lost 1 of 1 games", "damage dealt / taken 0.50", "330 metal of units and buildings lost before minute 6"} {
		if !strings.Contains(text, want) {
			t.Errorf("findings missing %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "extractors") {
		t.Errorf("extractors at the lower quartile aren't a finding:\n%s", text)
	}
	if strings.Contains(text, "Wind Turbine") || strings.Contains(text, "lost Legion Construction Bot") {
		t.Errorf("routine messages or double-counted losses in findings:\n%s", text)
	}
	var buf bytes.Buffer
	Report(&buf, "test", []*Game{g}, b)
	if !strings.Contains(buf.String(), "| anti-air turret | 1.0 | 200 |") || !strings.Contains(buf.String(), "1.0× gave up on Radar Tower") {
		t.Errorf("report:\n%s", buf.String())
	}
}
