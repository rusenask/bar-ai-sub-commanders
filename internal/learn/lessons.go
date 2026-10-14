package learn

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"
)

// Lessons: the strategist's own knowledge of a matchup, in words (learn/lessons/<matchup>.json, rendered
// to .md for people). After each game a debrief (strategist/debrief.go) edits the book with operations
// (create, update, merge, confirm, contradict, drop), so lessons consolidate instead of piling up: at
// most MaxLessons, each tagged with the stage of the game it is about, how often later games confirmed
// or contradicted it, and which games it came from. Reports carry the strongest lessons for the stage
// the game is in. (After TencentDB Agent Memory's capped scene blocks with heat and LLM merges; unlike
// it, a lesson's standing comes from game results: contradicted more than confirmed and it goes.)

// MaxLessons is the book's cap: the debrief must merge or drop to add beyond it.
const MaxLessons = 15

// Lesson is one piece of what the team learned about a matchup.
type Lesson struct {
	ID           int       `json:"id"`
	Stage        string    `json:"stage"` // opening, mid, late or all
	Text         string    `json:"text"`
	Confirmed    int       `json:"confirmed"`    // games that bore it out (including the one it came from)
	Contradicted int       `json:"contradicted"` // games that went against it
	Games        []string  `json:"games"`        // where it came from and was tested (provenance)
	Updated      time.Time `json:"updated"`
}

// Heat ranks lessons: evidence for minus evidence against.
func (l Lesson) Heat() int { return l.Confirmed - l.Contradicted }

// Book is a matchup's lessons.
type Book struct {
	Matchup string   `json:"matchup"`
	NextID  int      `json:"nextId"`
	Lessons []Lesson `json:"lessons"`
}

// Op is one edit the debrief asks for.
type Op struct {
	Op    string `json:"op"`              // create, update, merge, confirm, contradict, drop
	ID    int    `json:"id,omitempty"`    // the lesson (update, confirm, contradict, drop)
	IDs   []int  `json:"ids,omitempty"`   // merge: the lessons that become one
	Stage string `json:"stage,omitempty"` // create, update, merge
	Text  string `json:"text,omitempty"`  // create, update, merge
}

func bookPath(dir, matchup string) string { return filepath.Join(dir, "lessons", matchup+".json") }

// LoadBook reads a matchup's lessons (an empty book when none).
func LoadBook(dir, matchup string) *Book {
	b := &Book{Matchup: matchup, NextID: 1}
	if data, err := os.ReadFile(bookPath(dir, matchup)); err == nil {
		_ = json.Unmarshal(data, b)
	}
	return b
}

// Save writes the book and its markdown rendering; the previous book is kept as .bak (a failed debrief
// can't lose what was learned).
func (b *Book) Save(dir string) error {
	path := bookPath(dir, b.Matchup)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	if old, err := os.ReadFile(path); err == nil {
		_ = os.WriteFile(path+".bak", old, 0o644)
	}
	data, err := json.MarshalIndent(b, "", " ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return err
	}
	return os.WriteFile(strings.TrimSuffix(path, ".json")+".md", []byte(b.Markdown()), 0o644)
}

func validStage(s string) string {
	if slices.Contains(Stages, s) {
		return s
	}
	return "all"
}

func (b *Book) find(id int) int {
	return slices.IndexFunc(b.Lessons, func(l Lesson) bool { return l.ID == id })
}

// Apply runs the debrief's edits for one game; unknown ids are skipped, and the book is trimmed to
// MaxLessons (coldest first), and lessons contradicted more than confirmed (twice or more) are dropped.
func (b *Book) Apply(ops []Op, game string) []string {
	var done []string
	now := time.Now()
	touch := func(i int) {
		b.Lessons[i].Updated = now
		if !slices.Contains(b.Lessons[i].Games, game) {
			b.Lessons[i].Games = append(b.Lessons[i].Games, game)
		}
	}
	for _, op := range ops {
		switch op.Op {
		case "create":
			if strings.TrimSpace(op.Text) == "" {
				continue
			}
			b.Lessons = append(b.Lessons, Lesson{ID: b.NextID, Stage: validStage(op.Stage), Text: strings.TrimSpace(op.Text),
				Confirmed: 1, Games: []string{game}, Updated: now})
			done = append(done, fmt.Sprintf("created #%d", b.NextID))
			b.NextID++
		case "update", "confirm", "contradict", "drop":
			i := b.find(op.ID)
			if i < 0 {
				continue
			}
			switch op.Op {
			case "update":
				if t := strings.TrimSpace(op.Text); t != "" {
					b.Lessons[i].Text = t
				}
				if op.Stage != "" {
					b.Lessons[i].Stage = validStage(op.Stage)
				}
				touch(i)
			case "confirm":
				b.Lessons[i].Confirmed++
				touch(i)
			case "contradict":
				b.Lessons[i].Contradicted++
				touch(i)
			case "drop":
				b.Lessons = slices.Delete(b.Lessons, i, i+1)
			}
			done = append(done, fmt.Sprintf("%s #%d", op.Op, op.ID))
		case "merge":
			var merged Lesson
			var idx []int
			for _, id := range op.IDs {
				if i := b.find(id); i >= 0 {
					idx = append(idx, i)
					l := b.Lessons[i]
					merged.Confirmed += l.Confirmed
					merged.Contradicted += l.Contradicted
					merged.Games = append(merged.Games, l.Games...)
				}
			}
			if len(idx) < 2 || strings.TrimSpace(op.Text) == "" {
				continue
			}
			slices.Sort(idx)
			for k := len(idx) - 1; k >= 0; k-- {
				b.Lessons = slices.Delete(b.Lessons, idx[k], idx[k]+1)
			}
			merged.ID, merged.Stage, merged.Text, merged.Updated = b.NextID, validStage(op.Stage), strings.TrimSpace(op.Text), now
			b.NextID++
			b.Lessons = append(b.Lessons, merged)
			done = append(done, fmt.Sprintf("merged %v into #%d", op.IDs, merged.ID))
		}
	}
	// evidence against wins: contradicted more than confirmed, at least twice
	b.Lessons = slices.DeleteFunc(b.Lessons, func(l Lesson) bool { return l.Contradicted >= 2 && l.Contradicted > l.Confirmed })
	if len(b.Lessons) > MaxLessons {
		sort.SliceStable(b.Lessons, func(i, j int) bool { return b.Lessons[i].Heat() > b.Lessons[j].Heat() })
		b.Lessons = b.Lessons[:MaxLessons]
	}
	return done
}

// ForStage returns up to n lessons for a stage of the game (and those for all stages), strongest first.
func (b *Book) ForStage(stage string, n int) []Lesson {
	var out []Lesson
	for _, l := range b.Lessons {
		if l.Stage == stage || l.Stage == "all" {
			out = append(out, l)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Heat() > out[j].Heat() })
	if len(out) > n {
		out = out[:n]
	}
	return out
}

// Listing renders lessons one per line for a prompt: "#id [stage] text (+confirmed/-contradicted)".
func Listing(ls []Lesson) string {
	var b strings.Builder
	for _, l := range ls {
		fmt.Fprintf(&b, "- #%d [%s] %s (+%d/-%d)\n", l.ID, l.Stage, l.Text, l.Confirmed, l.Contradicted)
	}
	return b.String()
}

// Markdown renders the whole book for people.
func (b *Book) Markdown() string {
	var s strings.Builder
	fmt.Fprintf(&s, "# Lessons: %s\n\nWritten by the strategist's debriefs after games; +confirmed / -contradicted by later games.\n\n", b.Matchup)
	for _, st := range append(append([]string{}, Stages...), "all") {
		var ls []Lesson
		for _, l := range b.Lessons {
			if l.Stage == st {
				ls = append(ls, l)
			}
		}
		if len(ls) > 0 {
			fmt.Fprintf(&s, "## %s\n\n%s\n", st, Listing(ls))
		}
	}
	return s.String()
}
