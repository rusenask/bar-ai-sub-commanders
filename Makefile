BAR_DIR ?= $(HOME)/Library/Application Support/Beyond-All-Reason-mac
MODEL ?= lightning/deepseek-v4.1-flash
BAR_REF ?= 8247b61

.PHONY: build install run up down restart logs test-game test-bridge ref lint

build:
	go build -o bin/scbridge ./cmd/scbridge
	go build -o bin/fakegame ./cmd/fakegame

# copy the widgets into your BAR install (picked up next game, or /luaui reload)
install:
	mkdir -p "$(BAR_DIR)/LuaUI/Widgets"
	cp widget/LuaUI/Widgets/gui_subcommanders*.lua "$(BAR_DIR)/LuaUI/Widgets/"

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
	AI_PROFILE=$(AI_PROFILE) testenv/run.sh "$(CURDIR)/testenv/$(SCRIPT)" $(TIMEOUT) $(SCENARIO)
	@cat testenv/sctest_out.txt

# bridge for test games (port 17878, opencode on 14517), separate from the one real games use
test-bridge:
	docker build -q -t bar-scbridge:test .
	-docker rm -f scbridge-test
	docker run -d --name scbridge-test -p 127.0.0.1:17878:7878 -p 127.0.0.1:14517:4517 \
		-v "$(CURDIR)/strategist:/app/strategist:ro" -v "$$(sed -n 's/^LLM_API_KEY_FILE=//p' .env):/run/secrets/llm_api_key:ro" \
		-e SCBRIDGE_MODEL=$${MODEL:-$$(sed -n 's/^MODEL=//p' .env)} -e SCBRIDGE_DECIDER_URL=$(DECIDER_URL) \
		$(TEST_BRIDGE_ARGS) bar-scbridge:test

lint:
	luac -p widget/LuaUI/Widgets/*.lua testenv/LuaUI/Widgets/*.lua
	go vet ./...

# BAR game source at the installed version, for API reference
ref:
	git clone --filter=blob:none --no-checkout https://github.com/beyond-all-reason/Beyond-All-Reason.git ref/bar
	cd ref/bar && git sparse-checkout set --no-cone '/luaui/' '/common/' '/modules/' '/gamedata/' '/units/' '/luarules/configs/BARb/' '/init.lua' '/luarules/gadgets/*.lua' && git checkout $(BAR_REF)
