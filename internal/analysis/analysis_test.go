package analysis

import (
	"bytes"
	"os"
	"path/filepath"
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
	if !strings.Contains(buf.String(), "| opening, 0-6 min | 330 | 100 | 0.30 |") || !strings.Contains(buf.String(), "1.0× gave up on Radar Tower") {
		t.Errorf("report:\n%s", buf.String())
	}
	if !strings.Contains(buf.String(), "| anti-air turret | 1.0 | 200 |") {
		t.Errorf("report losses by kind:\n%s", buf.String())
	}
}

func TestPlaybook(t *testing.T) {
	log := datalog + `{"type":"build","team":0,"frame":1900,"chosen":"corak","options":[{"name":"corak","human":"Grunt","kind":"raider","cost":57,"tech":1},{"name":"corthud","human":"Thug","kind":"assault","cost":159,"tech":1}]}
{"type":"turretbuild","team":1,"frame":5500,"chosen":"corllt","options":[{"name":"corllt","human":"Guard","kind":"turret","cost":102,"tech":1}]}
`
	rec, err := ParseDatalog("g.jsonl", strings.NewReader(log))
	if err != nil {
		t.Fatal(err)
	}
	if len(rec.Builds) != 2 || rec.Builds[0].Human != "Grunt" || rec.Builds[0].Minute != 1 || !rec.Builds[1].Turret || rec.Builds[1].Minute != 3 {
		t.Fatalf("builds %+v", rec.Builds)
	}
	recs := []*Recorded{rec, rec, rec, rec}
	var buf bytes.Buffer
	Playbook(&buf, recs, BuildBenchmark("test", recs))
	for _, want := range []string{"Most built: Grunt 100%", "Turrets: Guard 100%", "first turret: minute 3 (4 of 8 players)", "| 2 | 9 (8-10) |"} {
		if !strings.Contains(buf.String(), want) {
			t.Errorf("playbook missing %q:\n%s", want, buf.String())
		}
	}
}

func TestBuildReportAndTimeline(t *testing.T) {
	g, err := ParseGame("1", strings.NewReader(harnessLog))
	if err != nil {
		t.Fatal(err)
	}
	r := BuildReport("test", []*Game{g}, nil)
	if len(r.Games) != 1 || r.Games[0].Result != "LOSS" || r.Games[0].ConstructorsLost != 1 || r.Averages["dealtTaken"] != 0.5 {
		t.Errorf("report %+v", r)
	}
	if len(r.Trades) != 3 || r.Trades[0].Lost != 330 || r.Trades[0].Killed != 100 {
		t.Errorf("trades %+v", r.Trades)
	}
	tl := Timeline(g)
	var m1 *Minute
	for i := range tl {
		if tl[i].Minute == 1 {
			m1 = &tl[i]
		}
	}
	if m1 == nil || m1.Lost["constructor"] != 1 || m1.Killed["raider"] != 1 || m1.LostMetal != 330 || m1.Eco == nil {
		t.Fatalf("minute 1: %+v", m1)
	}
	// the scripted player's action and the "gave up" alarm are in the timeline
	var texts []string
	for _, m := range tl {
		for _, e := range m.Events {
			texts = append(texts, e.Sub+": "+e.Text)
		}
	}
	all := strings.Join(texts, "\n")
	if !strings.Contains(all, "player: legcom builds leglab") || !strings.Contains(all, "Economy 1: gave up on Radar Tower") {
		t.Errorf("events:\n%s", all)
	}
	if !strings.Contains(TimelineText(g), "lost 330 metal (1 anti-air turret, 1 constructor)") {
		t.Errorf("text:\n%s", TimelineText(g))
	}
}

func TestWidgetCrashFinding(t *testing.T) {
	log := harnessLog + "\n[widget-error] [t=00:01:49][f=0040350] Error in GameFrame(): [string \"LuaUI/Widgets/gui_subcommanders.lua\"]:2425: attempt to call global 'addUnit' (a nil value)\n"
	g, err := ParseGame("1.txt", strings.NewReader(log))
	if err != nil {
		t.Fatal(err)
	}
	if len(g.Crashed) != 1 {
		t.Fatalf("crashed %v", g.Crashed)
	}
	f := Findings([]*Game{g}, &Benchmark{})
	if len(f) == 0 || f[0].Area != "crash" || !strings.Contains(f[0].Text, "addUnit") {
		t.Errorf("findings %+v", f)
	}
}

func TestMicro(t *testing.T) {
	var log strings.Builder
	for i := 0; i < 60; i++ {
		// skirmishers: fire from ~0.9 of their range, back off at ~0.5 from short-range enemies
		log.WriteString(`{"type":"micro","kind":"skirmisher","range":600,"dist":540,"eRange":200,"approach":0,"hp":1,"firing":true,"ahead":-50,"group":4}` + "\n")
		log.WriteString(`{"type":"micro","kind":"skirmisher","range":600,"dist":300,"eRange":200,"approach":-0.8,"hp":0.9,"firing":true,"ahead":-50,"group":4}` + "\n")
		// heavies: close in, ahead of the group
		log.WriteString(`{"type":"micro","kind":"heavy","range":300,"dist":150,"eRange":600,"approach":0.8,"hp":0.7,"firing":true,"ahead":150,"group":4}` + "\n")
		log.WriteString(`{"type":"micro","kind":"hover heavy","range":300,"dist":250,"eRange":200,"approach":0.1,"hp":0.4,"firing":false,"ahead":150,"group":4}` + "\n")
	}
	s, err := parseMicro(strings.NewReader(log.String() + `{"type":"fight"}` + "\n"))
	if err != nil || len(s) != 240 {
		t.Fatal(err, len(s))
	}
	kinds := MicroByKind(s, 50)
	if len(kinds) != 2 {
		t.Fatalf("kinds %+v", kinds)
	}
	by := map[string]MicroKind{}
	for _, k := range kinds {
		by[k.Kind] = k
	}
	sk, hv := by["skirmisher"], by["heavy"]
	if sk.Hold != 0.9 || sk.Kite < 0.99 || sk.KiteAt != 0.5 {
		t.Errorf("skirmisher %+v", sk)
	}
	if hv.Close < 0.99 || hv.Ahead != 150 || hv.Samples != 120 {
		t.Errorf("heavy %+v", hv)
	}
	doc := MicroDoctrine(kinds)
	if !strings.Contains(doc, `["skirmisher"] = { hold = 0.90, kite = 0.50`) || !strings.Contains(doc, `["heavy"] = { hold = 0.50, kite = false, front = true`) {
		t.Errorf("doctrine:\n%s", doc)
	}
}

func TestRoles(t *testing.T) {
	dir := t.TempDir()
	lines := []string{
		`{"type":"teams","teams":[{"team":0,"ally":0,"side":"Cortex"},{"team":1,"ally":0,"side":"Armada"},{"team":2,"ally":1,"side":"Cortex"},{"team":3,"ally":1,"side":"Cortex"}]}`,
		`{"type":"build","frame":18000,"team":0,"chosen":"corfig","options":[{"name":"corfig","kind":"fighter","cost":1200,"air":true}]}`,
		`{"type":"build","frame":3000,"team":1,"chosen":"armpw","options":[{"name":"armpw","kind":"raider","cost":1500}]}`,
		`{"type":"turretbuild","frame":3000,"team":2,"chosen":"corllt","options":[{"name":"corllt","kind":"turret","cost":900}]}`,
		`{"type":"build","frame":3000,"team":2,"chosen":"corak","options":[{"name":"corak","kind":"raider","cost":800}]}`,
		`{"type":"build","frame":3000,"team":3,"chosen":"corak","options":[{"name":"corak","kind":"raider","cost":600}]}`,
		`{"type":"eco","team":3,"mex":20}`,
		`{"type":"eco","team":2,"mex":8}`,
	}
	if err := os.WriteFile(filepath.Join(dir, "g.jsonl"), []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	players, err := ReadRoles(dir)
	if err != nil || len(players) != 4 {
		t.Fatal(err, players)
	}
	got := map[int]string{}
	for _, p := range players {
		got[p.Team] = p.Role
	}
	if got[0] != "air" || got[1] != "ground" || got[2] != "defense" || got[3] != "eco" {
		t.Errorf("roles %v", got)
	}
	if txt := RolesText(players); !strings.Contains(txt, "| 2 | 4 |") || !strings.Contains(txt, "| 50% | 10.0 |") {
		t.Errorf("text:\n%s", txt)
	}
}

func TestVerdicts(t *testing.T) {
	mk := func(result string, lostMid int) *Game {
		return &Game{Result: result, Seconds: 3600, Stats: map[string]float64{"damageDealt": 1, "damageReceived": 1},
			Lost: []Death{{Minute: 15, Cost: lostMid}}}
	}
	var a, b []*Game
	for i := range 12 {
		a = append(a, mk("LOSS", 1000+i))
		b = append(b, mk("TIMEOUT", 200+i))
	}
	vs := Verdicts([]Arm{{Label: "base", Games: a}, {Label: "new", Games: b}})["new"]
	got := map[string]string{}
	for _, r := range vs {
		got[r.Metric] = r.Verdict
	}
	if got["mid: metal lost"] != "better" || !strings.HasPrefix(got["score (win 1+, alive 0.5, loss by time; trades)"], "better") {
		t.Errorf("verdicts %v", got)
	}
	if got["opening: metal lost"] != "can't tell" {
		t.Errorf("no difference in the opening: %v", got["opening: metal lost"])
	}
}

func TestBattles(t *testing.T) {
	log := "[45] battle: us 3535 metal\n[885] BATTLE spec=armada-mirror result=WIN seconds=28 us_start=2000 us_left=1500 them_start=2000 them_left=0\n[885] RESULT WIN t=28s\n"
	g, err := ParseGame("1.txt", strings.NewReader(log))
	if err != nil || g.Battle == nil || g.Battle.Spec != "armada-mirror" {
		t.Fatalf("%v %+v", err, g.Battle)
	}
	if e := g.Battle.Efficiency(); e != 4 {
		t.Errorf("efficiency %v: their 100%% lost over our 25%%", e)
	}
	var b bytes.Buffer
	BattlesText(&b, []*Game{g})
	if !strings.Contains(b.String(), "| armada-mirror | 1 | 1 / 0 / 0 | 4.00 |") {
		t.Errorf("table:\n%s", b.String())
	}
}
