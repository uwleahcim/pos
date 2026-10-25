# ADR 1: Flutter apps are screens only; one Python backend owns every business rule

Date: 2026-10-25 · Status: accepted (Mike)

## Decision
Every screen (stations, handhelds, kitchen displays, remote units, admin portal) is a Flutter app that
renders and collects. Pricing, menu rules, taxes, order merging, routing and payments live in one Python
backend (FastAPI, Pydantic, SQLAlchemy, Alembic) that runs the same container image on each location hub and
in the cloud.

## Why
Flutter is the only mainstream toolkit with iOS, Android, Windows, macOS and Linux as official targets.
The menu engine design is written in Python terms and needs Python's validation, migration, spreadsheet and
testing tools. One copy of the rules means one place to test and fix them; a Dart or C copy was rejected
as a maintenance burden.

## Consequences
Terminals need a reachable backend (a hub or the cloud) and do not work alone; the redundancy in ADR 2
covers that. Payment SDKs that only exist natively need thin Flutter plugins.
