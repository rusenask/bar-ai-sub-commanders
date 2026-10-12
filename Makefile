BAR_DIR ?= $(HOME)/Library/Application Support/Beyond-All-Reason-mac
MODEL ?= lightning/deepseek-v4.1-flash
BAR_REF ?= 8247b61

.PHONY: build install run up down restart logs test-game ref lint

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
SCENARIO ?= multi
SCRIPT ?= script_nullai.txt
test-game:
	testenv/run.sh "$(CURDIR)/testenv/$(SCRIPT)" 420 $(SCENARIO)
	@cat testenv/sctest_out.txt

lint:
	luac -p widget/LuaUI/Widgets/*.lua testenv/LuaUI/Widgets/*.lua
	go vet ./...

# BAR game source at the installed version, for API reference
ref:
	git clone --filter=blob:none --no-checkout https://github.com/beyond-all-reason/Beyond-All-Reason.git ref/bar
	cd ref/bar && git sparse-checkout set --no-cone '/luaui/' '/common/' '/modules/' '/gamedata/' '/units/' '/luarules/configs/BARb/' '/init.lua' '/luarules/gadgets/*.lua' && git checkout $(BAR_REF)
