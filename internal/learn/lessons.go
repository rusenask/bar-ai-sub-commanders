package learn

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Lessons are the strategist's own notes from past games of a matchup (learn/lessons/<matchup>.md): after
// each game it writes what worked and what didn't (strategist.Debrief); the next game's first reports
// include them. The newest MaxLessons entries are kept.
const MaxLessons = 20

const lessonSep = "\n---\n"

func lessonsPath(dir, matchup string) string {
	return filepath.Join(dir, "lessons", matchup+".md")
}

// Lessons returns a matchup's notes, newest first ("" when none).
func Lessons(dir, matchup string) string {
	data, err := os.ReadFile(lessonsPath(dir, matchup))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// AddLesson puts a game's notes first and drops the oldest beyond MaxLessons.
func AddLesson(dir, matchup, header, text string) error {
	text = strings.TrimSpace(text)
	if text == "" {
		return nil
	}
	entry := fmt.Sprintf("## %s (%s)\n\n%s", header, time.Now().Format("2006-01-02 15:04"), text)
	entries := []string{entry}
	if old := Lessons(dir, matchup); old != "" {
		entries = append(entries, strings.Split(old, lessonSep)...)
	}
	if len(entries) > MaxLessons {
		entries = entries[:MaxLessons]
	}
	path := lessonsPath(dir, matchup)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(strings.Join(entries, lessonSep)+"\n"), 0o644)
}
