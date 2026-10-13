package decider

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// a fight as the data logger writes it (Lua encodes an empty kinds table as [])
const loggedFight = `{"type":"fight","own":{"air":0,"health":100,"value":4330,"count":17,"kinds":{"artillery":2,"heavy":8,"skirmisher":2,"assault":5}},
"ownTurrets":{"air":0,"health":100,"value":102,"count":1,"kinds":{"turret":1}},"enemy":{"air":0,"health":100,"value":1155,"count":6,"kinds":{"assault":6}},
"enemyTurrets":{"air":0,"health":0,"value":0,"count":0,"kinds":[]},"heightDiff":-19,"ownStart":2680,"enemyStart":3930,"ownLost":0,"enemyLost":0}`

func TestFightState(t *testing.T) {
	state, qs, err := Render(TaskFight, json.RawMessage(loggedFight))
	if err != nil {
		t.Fatal(err)
	}
	want := `Beyond All Reason RTS, a fight from our side, 0 minutes into the game.
Our group: 17 units worth 4330 metal (8 heavy, 5 assault, 2 artillery, 2 skirmisher), health 100%, firepower 0 damage per second, 0 hit points, typical range 0.
Our turrets nearby: 1 units worth 102 metal (1 turret), health 100%, firepower 0 damage per second, 0 hit points, typical range 0.
Enemy units: 6 units worth 1155 metal (6 assault), health 100%, firepower 0 damage per second, 0 hit points, typical range 0.
Enemy turrets: none.
Ground is level.
Distance from our start: 2680 elmos; from the enemy start: 3930 elmos.`
	if state != want {
		t.Errorf("state:\n%s\nwant:\n%s", state, want)
	}
	if qs["ahead"].Type != "noul" || qs["outcome"].Type != "score" {
		t.Errorf("questions %+v", qs)
	}
}

func TestFightOutcome(t *testing.T) {
	for _, c := range []struct {
		own, enemy int
		ahead      bool
		level      int
		ok         bool
	}{
		{0, 0, false, 0, false},
		{100, 0, false, 0, true},
		{100, 60, false, 1, true},
		{100, 110, true, 2, true},
		{50, 150, true, 3, true},
		{0, 300, true, 4, true},
	} {
		ahead, level, ok := FightOutcome(c.own, c.enemy)
		if ahead != c.ahead || level != c.level || ok != c.ok {
			t.Errorf("FightOutcome(%d, %d) = %v %d %v, want %v %d %v", c.own, c.enemy, ahead, level, ok, c.ahead, c.level, c.ok)
		}
	}
}

func TestValueRendering(t *testing.T) {
	f := `{"situation":{"own":{"kinds":{"assault":3},"value":400,"health":90,"count":3},"enemy":{"kinds":[],"value":0,"health":0,"count":0},"metalIncome":12.5},
"place":{"turretsNear":2,"ownStart":800,"enemyStart":5000,"nearestEnemy":-1},
"candidates":[{"name":"leglht","human":"Light Laser","kind":"turret","cost":90,"health":700,"range":430,"speed":0,"dps":40},
{"name":"legaa","human":"Nettle","kind":"anti-air turret","cost":150,"health":900,"range":800,"dps":60,"aaOnly":true}]}`
	state, qs, err := Render(TaskTurret, json.RawMessage(f))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(state, "choosing a turret") || !strings.Contains(state, "nearest enemy more than 3000 elmos away") || !strings.Contains(state, "The enemy's army and turrets: none.") {
		t.Errorf("state:\n%s", state)
	}
	if len(qs) != 2 || !strings.Contains(qs["legaa"].Instructions, "shoots aircraft only") || !strings.Contains(qs["leglht"].Instructions, "turret built here") {
		t.Errorf("questions %+v", qs)
	}
	if _, _, err := Render(TaskUnit, json.RawMessage(`{"situation":{}}`)); err == nil {
		t.Error("no candidates should fail")
	}
}

func TestChoiceRendering(t *testing.T) {
	f := `{"situation":{"own":{"kinds":{"assault":3},"value":400,"health":90,"count":3},"metalIncome":12.5},
"candidates":[{"name":"corak","human":"A.K.","kind":"raider","cost":45},{"name":"corthud","human":"Thud","kind":"assault","cost":150}]}`
	state, qs, err := Render(TaskProduce, json.RawMessage(f))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(state, "factory is choosing a unit") {
		t.Errorf("state:\n%s", state)
	}
	q := qs["pick"]
	crit, _ := q.Criteria.(map[string]string)
	if len(qs) != 1 || q.Type != "choice" || len(crit) != 2 || !strings.Contains(crit["corthud"], "Thud") {
		t.Errorf("questions %+v", qs)
	}
	if _, _, err := Render(TaskTurretPick, json.RawMessage(`{"candidates":[{"name":"a"}]}`)); err == nil {
		t.Error("one candidate should fail")
	}
}

func TestRouterRoutesTasks(t *testing.T) {
	var gotState string
	fight := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in struct{ State string }
		json.NewDecoder(r.Body).Decode(&in)
		gotState = in.State
		w.Write([]byte(`{"answers":{"ahead":{"type":"noul","noul":0.8}}}`))
	}))
	defer fight.Close()
	routes, err := ParseRoutes("fight="+fight.URL, "m")
	if err != nil {
		t.Fatal(err)
	}
	r := &Router{Tasks: routes}
	var features map[string]any
	json.Unmarshal([]byte(loggedFight), &features)
	answers, err := r.Decide(context.Background(), map[string]any{"task": "fight", "features": features})
	if err != nil || !strings.Contains(string(answers), "0.8") || !strings.HasPrefix(gotState, "Beyond All Reason RTS, a fight") {
		t.Fatalf("answers %s err %v state %q", answers, err, gotState)
	}
	if _, err := r.Decide(context.Background(), map[string]any{"task": "unit", "features": map[string]any{}}); err == nil {
		t.Error("unit task without a route or default should fail")
	}
	if _, err := ParseRoutes("fight", "m"); err == nil {
		t.Error("bad route should fail")
	}
}
