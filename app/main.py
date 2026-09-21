import os
import asyncio
from fastapi import FastAPI
import redis.asyncio as redis
import psycopg

app = FastAPI()

REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379/0")
DATABASE_URL = os.getenv(
    "DATABASE_URL", "postgresql://app:app@localhost:5432/app"
)


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/ready")
async def ready():
    checks = {"redis": "failed", "postgres": "failed"}

    try:
        r = redis.from_url(REDIS_URL)
        await r.ping()
        await r.close()
        checks["redis"] = "ok"
    except Exception:
        pass

    try:
        with psycopg.connect(DATABASE_URL, connect_timeout=3) as conn:
            conn.execute("SELECT 1")
        checks["postgres"] = "ok"
    except Exception:
        pass

    status = "ready" if all(v == "ok" for v in checks.values()) else "not_ready"
    return {"status": status, **checks}


async def worker():
    r = redis.from_url(REDIS_URL)
    print("worker started, listening on 'jobs' queue")
    while True:
        job = await r.blpop("jobs", timeout=5)
        if job:
            print(f"processed job: {job[1]}")


if __name__ == "__main__":
    asyncio.run(worker())