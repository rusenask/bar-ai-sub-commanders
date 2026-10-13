package strategist

import (
	"sync"
	"time"
)

// pacer decides how often a sub-commander is reviewed (design/engine.md, slow loop):
//   - busy (enemies in its area, losses, its army fighting): as often as the provider answers, i.e. its
//     average turn time converted to game time with the measured game speed, but no more often than
//     Config.Urgent and no less often than Config.Interval;
//   - calm: every Config.CalmFactor x Config.Interval;
//   - at most Config.MaxInFlight reviews at once, so a slow provider isn't flooded.
type pacer struct {
	mu       sync.Mutex
	latency  float64 // moving average of a review's wall time, seconds (0 = not measured yet)
	speed    float64 // moving average of game frames per wall second (0 = not measured yet)
	obsFrame int
	obsTime  time.Time
	inFlight int
}

const paceSmoothing = 0.3 // weight of the newest sample in the moving averages

func ewma(old, sample float64) float64 {
	if old == 0 {
		return sample
	}
	return old + paceSmoothing*(sample-old)
}

// observe records the game's frame at a wall time, to measure game speed.
func (p *pacer) observe(frame int, now time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.obsTime.IsZero() && frame > p.obsFrame {
		if dt := now.Sub(p.obsTime).Seconds(); dt >= 0.5 {
			p.speed = ewma(p.speed, float64(frame-p.obsFrame)/dt)
			p.obsFrame, p.obsTime = frame, now
		}
		return
	}
	p.obsFrame, p.obsTime = frame, now
}

// took records how long a review took.
func (p *pacer) took(d time.Duration) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.latency = ewma(p.latency, d.Seconds())
}

// interval returns the game frames between reviews of a busy or calm sub-commander.
func (p *pacer) interval(cfg Config, busy bool) int {
	p.mu.Lock()
	defer p.mu.Unlock()
	routine := seconds(cfg.Interval)
	if !busy {
		f := cfg.CalmFactor
		if f <= 0 {
			f = 2
		}
		return int(float64(routine) * f)
	}
	urgent := seconds(cfg.Urgent)
	if p.latency == 0 || p.speed == 0 {
		return max(urgent, routine/2)
	}
	// one review's wall time in game frames, with some slack for the model's tool calls
	provider := int(p.latency * p.speed * 1.2)
	return min(max(urgent, provider), routine)
}

// start reserves a slot for a review; false when MaxInFlight are already running.
func (p *pacer) start(cfg Config) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if cfg.MaxInFlight > 0 && p.inFlight >= cfg.MaxInFlight {
		return false
	}
	p.inFlight++
	return true
}

func (p *pacer) done() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.inFlight = max(0, p.inFlight-1)
}
