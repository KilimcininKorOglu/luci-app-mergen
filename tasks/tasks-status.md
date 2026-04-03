# Mergen - Task Status Tracker

**Last Updated**: 2026-04-03
**PRD Version**: 1.3
**Total Features**: 14
**Total Tasks**: 49

## Status Summary

| Status      | Count | Percentage |
|-------------|-------|------------|
| NOT_STARTED | 19    | 39%        |
| IN_PROGRESS | 0     | 0%         |
| COMPLETED   | 30    | 61%        |
| BLOCKED     | 0     | 0%         |
| AT_RISK     | 0     | 0%         |

## Feature Overview

| Feature | Name                            | Phase   | Tasks | Status      |
|---------|---------------------------------|---------|-------|-------------|
| F001    | Project Scaffold & UCI Config   | Phase 1 | 4     | NOT_STARTED |
| F002    | ASN Resolver & RIPE Provider    | Phase 1 | 3     | NOT_STARTED |
| F003    | Rule Engine & Route Manager     | Phase 1 | 3     | NOT_STARTED |
| F004    | CLI MVP & Watchdog              | Phase 1 | 4     | NOT_STARTED |
| F005    | Rollback & Atomic Apply         | Phase 2 | 3     | NOT_STARTED |
| F006    | nftables/ipset Integration      | Phase 2 | 2     | NOT_STARTED |
| F007    | Logging, CLI & Security         | Phase 2 | 4     | NOT_STARTED |
| F008    | Multi-Provider System           | Phase 3 | 4     | NOT_STARTED |
| F009    | IPv6 & Advanced Rule Engine     | Phase 3 | 3     | COMPLETED   |
| F010    | Import/Export & Automation      | Phase 3 | 4     | NOT_STARTED |
| F011    | LuCI Core Pages                 | Phase 4 | 4     | NOT_STARTED |
| F012    | LuCI Advanced Pages             | Phase 5 | 4     | NOT_STARTED |
| F013    | Advanced Features               | Phase 6 | 4     | NOT_STARTED |
| F014    | Distribution & QA               | Phase 6 | 3     | NOT_STARTED |

## Task Detail

### Phase 1: Core Infrastructure & MVP CLI (13 tasks)

| Task | Feature | Name                              | Priority | Effort | Status      | Dependencies |
|------|---------|-----------------------------------|----------|--------|-------------|--------------|
| T001 | F001    | OpenWrt Package Structure         | P1       | 2d     | COMPLETED   | None         |
| T002 | F001    | UCI Configuration Schema          | P1       | 1.5d   | COMPLETED   | T001         |
| T003 | F001    | UCI Read/Write Library            | P1       | 2d     | COMPLETED   | T002         |
| T004 | F002    | Provider Plugin Architecture      | P1       | 1.5d   | COMPLETED   | T003         |
| T005 | F002    | RIPE Stat API Integration         | P1       | 2d     | COMPLETED   | T004         |
| T006 | F002    | Prefix Cache Layer                | P2       | 1.5d   | COMPLETED   | T004, T005   |
| T007 | F003    | Rule CRUD Operations              | P1       | 2d     | COMPLETED   | T003         |
| T008 | F003    | Policy Routing (ip rule/route)    | P1       | 2.5d   | COMPLETED   | T003, T007   |
| T009 | F003    | Input Validation Library          | P1       | 1d     | COMPLETED   | T001         |
| T010 | F004    | Core CLI Commands                 | P1       | 3d     | COMPLETED   | T003-T009    |
| T011 | F004    | Utility CLI (version/help/valid.) | P2       | 1d     | COMPLETED   | T010         |
| T012 | F004    | Watchdog Daemon                   | P2       | 2d     | COMPLETED   | T001, T003   |
| T013 | F004    | Unit Test Framework & Tests       | P2       | 1.5d   | COMPLETED   | T003-T009    |
| T048 | F001    | Config Migration Script           | P2       | 1d     | COMPLETED   | T002, T003   |

### Phase 2: Reliability & Security (9 tasks)

| Task | Feature | Name                              | Priority | Effort | Status      | Dependencies     |
|------|---------|-----------------------------------|----------|--------|-------------|------------------|
| T014 | F005    | Routing State Snapshot & Rollback | P1       | 2.5d   | COMPLETED   | T008, T010       |
| T015 | F005    | Atomic Apply                      | P1       | 2d     | COMPLETED   | T014             |
| T016 | F005    | Watchdog Timer & Safe Mode        | P1       | 2d     | COMPLETED   | T012, T014       |
| T017 | F006    | nftables Set Management           | P1       | 2.5d   | COMPLETED   | T008             |
| T018 | F006    | ipset Fallback                    | P2       | 1.5d   | COMPLETED   | T017             |
| T019 | F007    | Logging Framework                 | P2       | 1.5d   | COMPLETED   | T003             |
| T020 | F007    | Extended CLI Commands             | P2       | 2d     | COMPLETED   | T010, T019       |
| T021 | F007    | Security Hardening                | P1       | 1.5d   | COMPLETED   | T009, T005       |
| T022 | F007    | Phase 2 Integration Tests         | P2       | 1d     | COMPLETED   | T014-T017, T019  |

### Phase 3: Multi-Provider & Advanced (11 tasks)

| Task | Feature | Name                              | Priority | Effort | Status      | Dependencies |
|------|---------|-----------------------------------|----------|--------|-------------|--------------|
| T023 | F008    | bgp.tools & bgpview.io Providers  | P2       | 2d     | COMPLETED   | T004         |
| T024 | F008    | MaxMind GeoLite2 Provider         | P3       | 2d     | COMPLETED   | T004         |
| T025 | F008    | RouteViews & IRR/RADB Providers   | P3       | 2.5d   | COMPLETED   | T004         |
| T026 | F008    | Provider Fallback & Health        | P2       | 2d     | COMPLETED   | T004, T006   |
| T027 | F009    | IPv6 Dual-Stack Routing           | P2       | 2.5d   | COMPLETED   | T008, T017   |
| T028 | F009    | Conflict Detection & Aggregation  | P3       | 2d     | COMPLETED   | T007         |
| T029 | F009    | Rule Grouping (Label/Tag)         | P4       | 1d     | COMPLETED   | T007         |
| T030 | F010    | JSON Import/Export                | P2       | 2d     | NOT_STARTED | T007, T010   |
| T031 | F010    | Cron Auto-Update                  | P2       | 1.5d   | NOT_STARTED | T006, T010   |
| T032 | F010    | Hotplug Integration               | P2       | 1.5d   | NOT_STARTED | T010, T012   |
| T033 | F010    | Resolve Command & Phase 3 Tests   | P3       | 1d     | NOT_STARTED | T005, T023   |

### Phase 4: LuCI Core Pages (4 tasks)

| Task | Feature | Name                              | Priority | Effort | Status      | Dependencies |
|------|---------|-----------------------------------|----------|--------|-------------|--------------|
| T034 | F011    | LuCI Package Scaffold & RPC      | P2       | 2.5d   | NOT_STARTED | T010         |
| T035 | F011    | Overview Page                     | P2       | 2d     | NOT_STARTED | T034         |
| T036 | F011    | Rules Page (Basic CRUD)           | P2       | 3d     | NOT_STARTED | T034         |
| T037 | F011    | Provider & Advanced Settings      | P3       | 2.5d   | NOT_STARTED | T034         |

### Phase 5: LuCI Advanced Pages (4 tasks)

| Task | Feature | Name                              | Priority | Effort | Status      | Dependencies |
|------|---------|-----------------------------------|----------|--------|-------------|--------------|
| T038 | F012    | Rules Page Advanced               | P3       | 2d     | NOT_STARTED | T036         |
| T039 | F012    | ASN Browser Page                  | P3       | 3d     | NOT_STARTED | T034, T005   |
| T040 | F012    | Interfaces & Logs Pages           | P3       | 3d     | NOT_STARTED | T034         |
| T041 | F012    | Advanced & Provider Settings Full | P3       | 2d     | NOT_STARTED | T037         |

### Phase 6: Advanced Features & Distribution (6 tasks)

| Task | Feature | Name                              | Priority | Effort | Status      | Dependencies |
|------|---------|-----------------------------------|----------|--------|-------------|--------------|
| T042 | F013    | DNS-Based Routing                 | P3       | 3d     | NOT_STARTED | T017, T018   |
| T043 | F013    | Country-Based Routing             | P3       | 2d     | NOT_STARTED | T024, T010   |
| T044 | F013    | Traffic Statistics & Failover     | P3       | 3d     | NOT_STARTED | T017, T012   |
| T045 | F013    | mwan3 Integration                 | P4       | 2d     | NOT_STARTED | T008         |
| T046 | F014    | Performance & Platform Testing    | P2       | 3d     | NOT_STARTED | T017, T027   |
| T047 | F014    | Documentation & Feed Submission   | P2       | 2.5d   | NOT_STARTED | T046         |
| T049 | F014    | GitHub Actions CI/CD Pipeline     | P2       | 1d     | NOT_STARTED | T013         |
