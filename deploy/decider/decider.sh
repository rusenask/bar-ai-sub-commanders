#!/bin/sh
# Decision model server for the sub-commanders (optional), on a Linux host with an NVIDIA GPU.
# Serves TypeSafe's /v1/systemone contract; scbridge -decider-url points at it.
#
#   decider.sh setup              install uv, Kev (jaredpalmer/kev) and its Python env, plus torchvision for Clef
#   decider.sh start clef-flash   Cloudflare/clef-flash on :8010 (~19 GB VRAM, best on our cases)
#   decider.sh start kev-4b       jaredpalmer/kev-4b on :8009 (~15 GB VRAM)
#   decider.sh start kev-9b       jaredpalmer/kev-9b on :8009
#   decider.sh start bar [ver]    our own BAR models (design/decision-models.md) from ~/bar-decider/runs/bar-<task>-<ver>:
#                                 fight :8011, unit :8012, turret :8013 (~3 GB each)
#   decider.sh stop               stop whichever runs
#   decider.sh status
#
# Only one fits on a 24 GB card at a time. Weights download from Hugging Face on first start.
set -e
DIR="$HOME/bar-decider"
UV="$HOME/.local/bin/uv"
HERE="$(cd "$(dirname "$0")" && pwd)"

case "$1" in
setup)
	command -v "$UV" >/dev/null 2>&1 || curl -LsSf https://astral.sh/uv/install.sh | sh
	mkdir -p "$DIR/clef"
	[ -d "$DIR/kev" ] || git clone -q https://github.com/jaredpalmer/kev.git "$DIR/kev"
	cp "$HERE/serve_clef.py" "$DIR/clef/serve_clef.py"
	cd "$DIR/kev" && "$UV" sync --extra serve
	TORCH=$("$DIR/kev/.venv/bin/python" -c 'import torch; print(torch.__version__.split("+")[0])')
	case "$TORCH" in 2.8*) TV=0.23 ;; 2.7*) TV=0.22 ;; *) TV=0.21 ;; esac
	"$UV" pip install --python "$DIR/kev/.venv/bin/python" "torch==$TORCH" "torchvision==$TV.*"
	;;
start)
	"$0" stop >/dev/null 2>&1 || true
	cd "$DIR/kev"
	case "$2" in
	clef | clef-flash) setsid "$UV" run --extra serve python "$DIR/clef/serve_clef.py" --model "Cloudflare/${2:-clef-flash}" --port 8010 >"$DIR/decider.log" 2>&1 </dev/null & ;;
	kev-*) setsid "$UV" run --extra serve python -m kev.serve --run "jaredpalmer/$2" --host 0.0.0.0 --port 8009 --device cuda >"$DIR/decider.log" 2>&1 </dev/null & ;;
	bar)
		port=8011
		for task in fight unit turret; do
			run="$DIR/runs/bar-$task-${3:-v1}"
			[ -d "$run" ] && setsid "$UV" run --extra serve python -m kev.serve --run "$run" --host 0.0.0.0 --port $port --device cuda >"$DIR/decider-$task.log" 2>&1 </dev/null &
			port=$((port + 1))
		done
		;;
	*) echo "start clef-flash | kev-4b | kev-9b | bar [version]" >&2; exit 2 ;;
	esac
	echo "starting $2, log: $DIR/decider.log"
	;;
stop)
	pkill -f "serve_cle[f].py" || true
	pkill -f "m kev[.]serve" || true
	sleep 2
	;;
status)
	tail -n 3 "$DIR/decider.log" 2>/dev/null || true
	nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader
	;;
*)
	sed -n '2,13p' "$0"
	exit 2
	;;
esac
