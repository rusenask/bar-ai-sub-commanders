FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 go build -trimpath -o /out/scbridge ./cmd/scbridge

FROM ghcr.io/anomalyco/opencode:1.18.34
COPY --from=build /out/scbridge /usr/local/bin/scbridge
# global opencode config for the container: only the LLM provider the strategist
# uses; its key comes from the llm_api_key secret
COPY docker/opencode.json /root/.config/opencode/opencode.json
COPY strategist /app/strategist
WORKDIR /app
EXPOSE 7878 4517
ENTRYPOINT ["scbridge", "-game-addr", "0.0.0.0:7878", "-opencode-host", "0.0.0.0", "-strategist-dir", "/app/strategist"]
