# NexCell DevOps Assessment

## ABOUT YOU

**Name / Time spent (minutes):** Yosr Taktak / 120 min

**AI tools used, and one thing you changed or corrected from their output:**
Used Claude (Anthropic) throughout for drafting and review. Corrected two things from its first draft of the stub app: removed a redundant `asyncio.sleep(0.1)` after `blpop` (which already blocks efficiently, so the sleep only added latency), and added a `connect_timeout=3` to the Postgres readiness check, since an unbounded connection attempt could make `/ready` hang instead of failing fast.

---

## BUILD AND RUN

**What I delivered, and how to run and verify it (commands):**
Stub API/worker (`/health`, `/ready`, Redis-consuming worker), a corrected production Dockerfile, `docker-compose.yml` (api, worker, redis, postgres, migrate), GitHub Actions CI (build+tag by SHA, compose stack, smoke test, OIDC ECS deploy placeholder), and `smoke_test.sh`.

```bash
cp .env.example .env
docker compose up -d --build
./smoke_test.sh
curl localhost:8000/health   # {"status":"ok"}
curl localhost:8000/ready    # {"status":"ready","redis":"ok","postgres":"ok"}
```

**Top 3 problems fixed in the starting Dockerfile, and why each matters:**
1. **Hardcoded `OPENAI_API_KEY`** — a secret baked into an image layer is extractable (`docker history`) even if a later line overwrites it; on a public repo this is an immediate compromise.
2. **`python:latest` + no `USER`** — an unpinned tag breaks reproducibility (today's build ≠ tomorrow's), and running as root means any app-level exploit gets root inside the container. Fixed with `python:3.12-slim` pinned, plus a dedicated non-root `appuser`.
3. **`pip install .` with no pinned versions + `--reload` in prod** — open version ranges make builds non-reproducible (the exact bug the brief describes); `--reload` is a dev-only flag that wastes CPU watching files that never change in a container. Fixed with pinned `requirements.txt` and a proper `--workers` Uvicorn config.

**How dependencies are kept reproducible, and how migrations run safely on deploy:**
`requirements.txt` pins exact versions (no open ranges). Migrations run as a dedicated one-off `migrate` service in Compose, gated with `depends_on: condition: service_completed_successfully` — `api`/`worker` cannot start until migrations finish, removing the manual-ordering risk described in the brief (code/schema shipped out of order).

---

## AWS DESIGN

**Target architecture in 3 to 5 lines:**
ECS Fargate for API and workers, each with autoscaling (API on ALB request count/CPU, workers on Redis queue depth), behind an ALB; Next.js frontend on Fargate behind CloudFront; ElastiCache Redis right-sized to actual usage; vector DB on a Reserved EC2 instance; Postgres stays managed/unchanged (out of scope). All compute in private subnets; VPC endpoints for ECR/S3/CloudWatch Logs cut NAT data-processing cost.

```
Internet → CloudFront → ALB → ECS Fargate (API, autoscaled)
                                   │
                          ┌────────┴────────┐
                          ▼                 ▼
                       Redis            Postgres (managed)
                          ▲
                    ECS Fargate (Workers, autoscaled on queue depth)
                          │
                     EC2 (Vector DB, Reserved)
```

**Networking and security: VPC and subnets, IAM, secrets, how CI authenticates to AWS:**
Public subnets hold only the ALB; Fargate tasks, EC2, and ElastiCache sit in private subnets. IAM roles are scoped per service (separate task execution role vs. task role, least privilege). Secrets live in AWS Secrets Manager, injected at runtime — never baked into images. CI authenticates via GitHub OIDC assuming a scoped deploy-only IAM role; no long-lived access keys, replacing the current static-keys-in-GitHub-secrets setup.

**Deploying without downtime, and how you would roll back:**
ECS rolling deployment (`minimumHealthyPercent=100`, `maximumPercent=200`) with the ALB health check gating traffic shift to new tasks. Rollback is re-deploying the previous ECS task definition revision (ECS retains history); the deployment circuit breaker auto-rolls-back if health checks fail mid-rollout.

**Monitoring: the three alarms you would add first, with thresholds:**
1. **API 5xx rate > 5% over 5 min** (ALB target 5XX count) — nothing today alerts on error rate.
2. **Job queue depth > 100 for 10+ consecutive min** (Redis `LLEN` custom metric) — queue is empty 70% of the time, so a sustained backlog signals a stuck worker or LLM outage.
3. **API P95 latency > 2s over 5 min** (ALB target response time) — uptime checks alone don't catch a service that's up but slow.

---

## COST

**Top 3 savings: change, estimated £/month, and the risk each introduces:**

| Change | Savings | Risk |
|---|---|---|
| Staging scheduled to business hours only (not 24/7) + smaller sizing | ~£170 | Late-day hotfix testing needs a manual staging start; acceptable given staging is non-customer-facing |
| Redis `r6g.large` → `t4g.small` (usage is 8% of memory today) | ~£100 | Less headroom for growth; mitigate with a CloudWatch memory alarm at 60% to catch before it's tight |
| API + worker autoscaling (API avg 12% CPU; queue empty 70% of time) | ~£160 | Misconfigured thresholds could add latency during a fast ramp-up; mitigate with a floor of 2 API tasks / 1 worker task during business hours |

**New projected AWS total and cost per customer (show the sum):**

| Line item | Old | New |
|---|---|---|
| Staging | £260 | £90 |
| Fargate API | £210 | £130 |
| Fargate workers | £190 | £110 |
| ElastiCache Redis | £150 | £50 |
| NAT Gateways | £140 | £95 |
| EC2 vector DB (Reserved) | £130 | £95 |
| Fargate frontend | £105 | £90 |
| CloudWatch Logs (INFO, 30-day retention) | £95 | £35 |
| EC2 admin tool (scheduled) | £55 | £20 |
| ALB/CloudFront/S3/ECR (lifecycle policy) | £80 | £65 |
| **Total** | **£1,415** | **£780** |

£780 / 20 customers = **£39/customer/month** — under the £45 target, with margin for the 100-customer trajectory.

**One cost you would deliberately not cut, and how you would catch a cost spike early:**
Keep the NAT Gateway in both AZs rather than one — dropping to a single AZ saves ~£70/month but removes availability-zone failover, a bigger reliability risk than the saving justifies. To catch spikes early: AWS Budgets alerting at 80% of the £900 monthly ceiling, plus AWS Cost Anomaly Detection.

---

## JUDGEMENT

**How this scales to 100 customers:**
Not all three savings age the same way. Staging's cost is independent of customer count, so that saving holds unchanged. Autoscaling API/workers actually improves with growth — it adds capacity automatically as traffic rises, no manual re-sizing needed. The Redis downsize is the one to watch: 8% memory usage at 20 customers will climb well before 100, so `t4g.small` is a near-term saving, not a permanent one — the 60%-memory alarm exists specifically to catch that before it becomes a bottleneck, and the instance should be revisited as customer count grows. Separately, the single-instance EC2 vector DB is the bigger scale risk overall — before 100 tenants it needs to move to a managed/sharded search service to avoid a single point of failure and a CPU ceiling.

**The biggest production risk in the current setup, and your first fix:**
Manual database migrations causing code/schema mismatches (already caused two incidents per the brief). First fix: the `migrate` service in this repo's Compose/CI setup, which gates every deploy behind a successfully completed migration step.

**One thing kept intentionally simple, and what you would do with 3 more hours:**
The `migrate` service is a stub (`print()`), since the assessment's stub app has no real schema to migrate. With 3 more hours: wire real Alembic migrations against Postgres, add minimal Terraform for the target VPC/ECS setup, and define the three CloudWatch alarms above as code rather than prose.
