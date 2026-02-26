"""Chat Demo – FastAPI Backend with Microsoft AI Foundry."""
import os
import logging
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
from pydantic import BaseModel

logger = logging.getLogger("chatdemo")

# ─── Configuration ────────────────────────────────────────────────────────────
FOUNDRY_ENDPOINT = os.environ.get("FOUNDRY_ENDPOINT", "")
FOUNDRY_RESOURCE_NAME = os.environ.get("FOUNDRY_RESOURCE_NAME", "")
DEPLOYMENT_NAME = os.environ.get("DEPLOYMENT_NAME", "gpt41mini")

# ─── AI Client (lazy init) ───────────────────────────────────────────────────
_openai_client = None


def _get_openai_client():
    """Return an OpenAI-compatible client, with fallback."""
    global _openai_client
    if _openai_client is not None:
        return _openai_client

    from azure.identity import DefaultAzureCredential

    credential = DefaultAzureCredential()

    # Primary path: AIProjectClient → get_openai_client()
    try:
        from azure.ai.projects import AIProjectClient

        project_client = AIProjectClient(
            endpoint=FOUNDRY_ENDPOINT,
            credential=credential,
        )
        _openai_client = project_client.inference.get_chat_completions_client()
        logger.info("Using AIProjectClient path")
        return _openai_client
    except Exception as exc:
        logger.warning("AIProjectClient path failed (%s), trying direct fallback", exc)

    # Fallback: direct Azure OpenAI endpoint with MI token
    try:
        from openai import AzureOpenAI

        _openai_client = AzureOpenAI(
            azure_endpoint=f"https://{FOUNDRY_RESOURCE_NAME}.openai.azure.com",
            api_version="2024-12-01-preview",
            azure_ad_token_provider=_get_token_provider(credential),
        )
        logger.info("Using direct OpenAI fallback path")
        return _openai_client
    except Exception as exc2:
        logger.error("Both AI paths failed: %s", exc2)
        raise exc2


def _get_token_provider(credential):
    """Create a token provider callable for Azure OpenAI."""
    from azure.identity import get_bearer_token_provider

    return get_bearer_token_provider(
        credential, "https://cognitiveservices.azure.com/.default"
    )


# ─── FastAPI App ──────────────────────────────────────────────────────────────
app = FastAPI(title="Chat Demo", docs_url=None, redoc_url=None)


class ChatRequest(BaseModel):
    message: str
    history: list[dict] = []


class ChatResponse(BaseModel):
    reply: str


@app.get("/healthz")
async def health():
    return {"status": "ok"}


@app.post("/api/chat", response_model=ChatResponse)
async def chat(req: ChatRequest):
    try:
        client = _get_openai_client()

        messages = []
        for h in req.history:
            role = h.get("role", "user")
            content = h.get("content", "")
            messages.append({"role": role, "content": content})
        messages.append({"role": "user", "content": req.message})

        # azure-ai-inference ChatCompletionsClient uses .complete()
        # openai AzureOpenAI uses .chat.completions.create()
        if hasattr(client, "complete"):
            response = client.complete(
                model=DEPLOYMENT_NAME,
                messages=messages,
                max_tokens=800,
                temperature=0.7,
            )
        else:
            response = client.chat.completions.create(
                model=DEPLOYMENT_NAME,
                messages=messages,
                max_tokens=800,
                temperature=0.7,
            )
        reply = response.choices[0].message.content
        return ChatResponse(reply=reply)
    except Exception as exc:
        logger.exception("Upstream AI error")
        raise HTTPException(status_code=502, detail=f"AI upstream error: {exc}")


# ─── Serve static frontend ───────────────────────────────────────────────────
STATIC_DIR = Path(__file__).parent.parent / "static"
if STATIC_DIR.is_dir():
    app.mount("/assets", StaticFiles(directory=STATIC_DIR / "assets"), name="assets")

    @app.get("/{path:path}")
    async def serve_frontend(path: str):
        file = STATIC_DIR / path
        if file.is_file():
            return FileResponse(file)
        return FileResponse(STATIC_DIR / "index.html")
