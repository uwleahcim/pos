# Restaurant POS

A point-of-sale system for a group of full-service restaurants: Flutter apps on every screen, one Python
backend that runs on two hubs per location and in two cloud regions, and an append-only order log that
merges after any disconnect.

- Architecture (draft 4): `docs/architecture.html` (also published at https://claude.ai/artifact/NyhuxEexcTSdNhYkJ6n4ay)
- Menu engine specification: `docs/menu-engine-design.md` (the binding spec for the engine)
- Decisions: `docs/adr/`
- Phase 0 plan and spike status: `docs/phase0/README.md` and `spikes/`

## Layout

```
backend/   Python backend: menu engine, orders and sync, taxes, payments, APIs (FastAPI)
apps/      Flutter apps: POS, kitchen, admin portal (screens only, no business rules)
spikes/    Phase 0 spikes: one folder per question, each with its pass criteria and result
infra/     Hub install for the mini PCs (infra/hub); hub image and cloud deployment later
docs/      Architecture, spec, decisions, plans
```

## Backend quick start

```
cd backend
uv venv .venv && uv pip install -e '.[dev]'
.venv/bin/pytest
.venv/bin/python -m pos.sync.simulate --replicas 4 --rounds 300 --drop 0.3
.venv/bin/uvicorn pos.api.app:app --reload
```

The first spike, the order operation log with hybrid logical clocks, lives in `backend/src/pos/sync/`; the second,
the menu engine built from the specification, in `backend/src/pos/menu/`. Both pass in software; see `spikes/`.
