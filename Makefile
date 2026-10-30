BAR_DIR ?= $(HOME)/Library/Application Support/Beyond-All-Reason-mac
MODEL ?= node06/glm-5.3-flash
BAR_REF ?= 8247b61

.PHONY: build install run up down restart logs test-game test-batch test-bridge play-vs report compare track timeline benchmarks test-lua decider-deploy decider-eval ref lint errors

build:
	go build -o bin/scbridge ./cmd/scbridge
	go build -o bin/fakegame ./cmd/fakegame
	go build -o bin/gamereport ./cmd/gamereport

# copy the widgets into your BAR install (picked up next game, or /luaui reload)
install:
	mkdir -p "$(BAR_DIR)/LuaUI/Widgets" "$(BAR_DIR)/LuaUI/Include"
	cp widget/LuaUI/Widgets/gui_subcommanders*.lua "$(BAR_DIR)/LuaUI/Widgets/"
	cp widget/LuaUI/Include/sc_*.lua "$(BAR_DIR)/LuaUI/Include/"

# run the bridge in this terminal instead of Docker (uses your own opencode config)
run: build
	./bin/scbridge -model $(MODEL)

# the bridge + opencode in Docker (settings in .env; MODEL=provider/model overrides)
up:
	$(if $(filter command line,$(origin MODEL)),MODEL=$(MODEL)) docker compose up -d --build

down:
	docker compose down

# pick up prompt/agent edits in strategist/
restart:
	docker compose restart

logs:
	docker compose logs -f --tail=100

# scripted test game in an isolated write dir: make test-game SCENARIO=ai
# 1v1 against BARbarian: make test-game SCENARIO=duel SCRIPT=script_vsai.txt AI_PROFILE=medium TIMEOUT=1200
SCENARIO ?= multi
SCRIPT ?= script_nullai.txt
TIMEOUT ?= 420
test-game:
	AI_PROFILE=$(AI_PROFILE) MAP="$(MAP)" SPEED=$(SPEED) LOCKSTEP=$(LOCKSTEP) testenv/run.sh "$(CURDIR)/testenv/$(SCRIPT)" $(TIMEOUT) $(SCENARIO)
	@cat testenv/sctest_out.txt

# several fast games against BARbarian with a summary and a report (testenv/batch/<date>-<label>/report.md):
# make test-batch GAMES=5 BATCH_SCENARIO=duel AI_PROFILE=hard LABEL=my-change
GAMES ?= 3
test-batch:
	LABEL="$(LABEL)" WORKERS="$(WORKERS)" DUEL_MINUTES="$(DUEL_MINUTES)" AI_PROFILE=$(or $(AI_PROFILE),medium) MAP="$(MAP)" SPEED=$(or $(SPEED),15) LOCKSTEP=$(LOCKSTEP) testenv/batch.sh $(GAMES) $(or $(BATCH_SCENARIO),duelrules) script_vsai.txt

# play a local 1v1 against sub-commanders (a second BAR window joins as the bot); all settings optional:
# make play-vs [YOU=Armada] [BOT=Legion] [MAP="..."] [BOT_AI=0] [BARB=ally:hard]
play-vs:
	MAP="$(MAP)" YOU="$(YOU)" BOT="$(BOT)" BOT_AI="$(BOT_AI)" BARB="$(BARB)" play/vs.sh

# analyse games: make report (the latest batch), make report BATCH=testenv/batch/<dir>, or a single log
report:
	go run ./cmd/gamereport $(or $(BATCH),testenv/batch/latest/)

# one game minute by minute (economy, losses / kills by kind, decisions): make timeline GAME=<log> [JSON=1]
timeline:
	go run ./cmd/gamereport -timeline $(if $(JSON),-json) $(GAME)

# A/B arms side by side: make compare ARMS="testenv/batch/<A> testenv/batch/<B>"
compare:
	go run ./cmd/gamereport -compare $(ARMS)

# log a batch (an A/B's arms found from it) to Lightning's experiment tracker (scripts/track.py); batches
# do it themselves at the end
track:
	uv run --quiet --with litlogger python scripts/track.py $(BATCH)

# rebuild the strong players' benchmark from logged replays (testenv/pro_replays.py, testenv/replays.sh)
benchmarks:
	go run ./cmd/gamereport -bench-from testenv/data/pro

# bridge for test games (port 17878, opencode on 14517), separate from the one real games use
test-bridge:
	mkdir -p testenv/records
	docker build -q -t bar-scbridge:test .
	-docker rm -f scbridge-test
	docker run -d --name scbridge-test -p 127.0.0.1:17878:7878 -p 127.0.0.1:14517:4517 \
		-v "$(CURDIR)/strategist:/app/strategist:ro" -v "$$(sed -n 's/^LLM_API_KEY_FILE=//p' .env):/run/secrets/llm_api_key:ro" \
		-e SCBRIDGE_MODEL=$${MODEL:-$$(sed -n 's/^MODEL=//p' .env)} -e SCBRIDGE_DECIDER_URL=$(DECIDER_URL) \
		-v "$(CURDIR)/testenv/records:/app/records" -e SCBRIDGE_RECORD=/app/records/reviews.jsonl \
		-e SCBRIDGE_ERRORS_LOG=/app/records/widget-errors.jsonl \
		$(TEST_BRIDGE_ARGS) bar-scbridge:test

lint: test-lua
	luac -p widget/LuaUI/Widgets/*.lua widget/LuaUI/Include/*.lua testenv/LuaUI/Widgets/*.lua
	scripts/lua-globals.sh widget/LuaUI/Widgets/*.lua widget/LuaUI/Include/*.lua testenv/LuaUI/Widgets/zz_*.lua
	scripts/lua-locals.sh widget/LuaUI/Widgets/*.lua widget/LuaUI/Include/*.lua testenv/LuaUI/Widgets/zz_*.lua
	go vet ./...

# the widgets' Lua errors, caught (sc_guard.lua: logs/widget-errors*.jsonl, the infolog) or not; DAYS=7
errors:
	python3 scripts/widget_errors.py --days $(or $(DAYS),7)

# unit tests of the widget's engine modules (widget/LuaUI/Include) under plain Lua
test-lua:
	lua widget/tests/run.lua widget/tests/*_test.lua

# BAR game source at the installed version, for API reference
ref:
	git clone --filter=blob:none --no-checkout https://github.com/beyond-all-reason/Beyond-All-Reason.git ref/bar
	cd ref/bar && git sparse-checkout set --no-cone '/luaui/' '/common/' '/modules/' '/gamedata/' '/units/' '/luarules/configs/BARb/' '/init.lua' '/luarules/gadgets/*.lua' && git checkout $(BAR_REF)

# optional decision model on a GPU host: make decider-deploy DECIDER_HOST=100.108.100.25 DECIDER=clef-flash
DECIDER_HOST ?= 100.108.100.25
DECIDER ?= clef-flash
decider-deploy:
	ssh $(DECIDER_HOST) mkdir -p bar-decider/deploy
	scp -q deploy/decider/decider.sh deploy/decider/serve_clef.py $(DECIDER_HOST):bar-decider/deploy/
	ssh $(DECIDER_HOST) sh bar-decider/deploy/decider.sh setup
	ssh $(DECIDER_HOST) sh bar-decider/deploy/decider.sh start $(DECIDER)

# score a running decision model on BAR decisions: make decider-eval DECIDER_URL=http://100.108.100.25:8010
decider-eval:
	go run ./cmd/decidereval -url $(DECIDER_URL)
