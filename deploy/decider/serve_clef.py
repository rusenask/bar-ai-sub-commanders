# Minimal /v1/systemone server for Cloudflare Clef / Clef-flash (open weights, Apache-2.0).
# usage: python serve_clef.py [--model Cloudflare/clef-flash] [--port 8010]
import argparse, sys, time
import torch
import uvicorn
from fastapi import FastAPI, HTTPException
from huggingface_hub import snapshot_download

ap = argparse.ArgumentParser()
ap.add_argument("--model", default="Cloudflare/clef-flash")
ap.add_argument("--host", default="0.0.0.0")
ap.add_argument("--port", type=int, default=8010)
args = ap.parse_args()

path = snapshot_download(args.model)
sys.path.insert(0, path)
from joint_schema_model import load_release_model, systemone  # noqa: E402

model, processor = load_release_model(path, device="cuda")
app = FastAPI()


@app.get("/health")
def health():
    return {"ok": True, "model": args.model}


@app.post("/v1/systemone")
def answer(body: dict):
    start = time.perf_counter()
    try:
        with torch.inference_mode():
            out = systemone(model, processor, {"model": body.get("model") or "clef", **body})
    except ValueError as e:
        raise HTTPException(400, str(e))
    out["latency_ms"] = round((time.perf_counter() - start) * 1000, 1)
    return out


uvicorn.run(app, host=args.host, port=args.port)
