# Mergen - Task Execution Plan

**PRD Version**: 1.3
**Total Effort**: ~95.5 developer-days

## Critical Path

```
T001 → T002 → T003 → T004 → T005 → T010 → T014 → T015 → T017 → T034 → T036
  │                    │              │                          │
  └→ T009              └→ T007 → T008                           └→ T035, T037
                                   │
                                   └→ T027, T017
```

**Critical path length**: ~24 developer-days (T001 → T047)

## Phase Breakdown

### Phase 1: Core Infrastructure & MVP CLI

**Total Effort**: 24 developer-days
**Parallel Tracks**: 2-3 concurrent tracks possible

```
Track A (Core):     T001 → T002 → T003 → T004 → T005 → T006
Track B (Engine):                  T003 → T007 → T008
Track C (Validation):  T001 → T009
Track D (CLI):                                         → T010 → T011
Track E (Daemon):      T001 → T012
Track F (Tests):                                              → T013
Track G (Migration):           T002 → T003 → T048
```

**Execution Order**:
1. T001 (Package Structure) — unblocks everything
2. T002 (UCI Schema) + T009 (Validation) — parallel
3. T003 (UCI Library) — needs T002
4. T004 (Provider Arch) + T007 (Rule CRUD) + T012 (Watchdog) — parallel after T003
5. T005 (RIPE Provider) + T008 (Policy Routing) — parallel
6. T006 (Cache) — after T005
7. T010 (Core CLI) — after T003-T009
8. T011 (Utility CLI) + T013 (Tests) + T048 (Config Migration) — parallel after T010

**Milestone**: `mergen add --asn 13335 --via wg0 && mergen apply` works

---

### Phase 2: Reliability & Security

**Total Effort**: 16.5 developer-days
**Parallel Tracks**: 3 concurrent tracks

```
Track A (Safety):   T014 → T015 → T016
Track B (nftables): T017 → T018
Track C (Logging):  T019 → T020
Track D (Security): T021
Track E (Tests):    T022
```

**Execution Order**:
1. T014 (Snapshot) + T017 (nftables) + T019 (Logging) — parallel
2. T015 (Atomic) + T018 (ipset) + T020 (Extended CLI) + T021 (Security) — parallel
3. T016 (Safe Mode) — after T014
4. T022 (Integration Tests) — after all above

**Milestone**: Automatic rollback works, device stays accessible

---

### Phase 3: Multi-Provider & Advanced

**Total Effort**: 20 developer-days
**Parallel Tracks**: 4 concurrent tracks

```
Track A (Providers): T023 → T026
Track B (Providers): T024, T025
Track C (Engine):    T027, T028, T029
Track D (Automation): T030, T031, T032
Track E:             T033
```

**Execution Order**:
1. T023 (bgp+bgpview) + T024 (MaxMind) + T025 (RouteViews+IRR) + T027 (IPv6) + T030 (Import/Export) — parallel
2. T026 (Fallback) + T028 (Conflicts) + T031 (Cron) + T032 (Hotplug) — parallel
3. T029 (Tags) + T033 (Resolve+Tests) — parallel

**Milestone**: 6 providers, IPv6, auto-update, import/export all working

---

### Phase 4: LuCI Core Pages

**Total Effort**: 10 developer-days
**Parallel Tracks**: 3 after scaffold

```
Track A: T034 → T035
Track B: T034 → T036
Track C: T034 → T037
```

**Execution Order**:
1. T034 (LuCI Scaffold) — unblocks pages
2. T035 (Overview) + T036 (Rules) + T037 (Provider+Advanced) — parallel

**Milestone**: Basic LuCI CRUD from web panel

---

### Phase 5: LuCI Advanced Pages

**Total Effort**: 10 developer-days
**Parallel Tracks**: 4 concurrent

```
T038 (Rules Adv) + T039 (ASN Browser) + T040 (Interfaces+Logs) + T041 (Settings Full)
```

**Execution Order**: All 4 tasks parallel (independent pages)

**Milestone**: All 7 LuCI pages fully functional

---

### Phase 6: Advanced Features & Distribution

**Total Effort**: 16.5 developer-days
**Parallel Tracks**: 4 concurrent + sequential QA

```
Track A: T042 (DNS) + T043 (Country) + T044 (Traffic+Failover) + T045 (mwan3)
Track B: T046 (Testing) → T047 (Docs+Submission)
Track C: T049 (CI/CD Pipeline) — can start early, after T013
```

**Execution Order**:
1. T042 + T043 + T044 + T045 + T049 (CI/CD) — parallel (independent features; T049 can start earlier)
2. T046 (Performance Testing) — after features
3. T047 (Documentation + Submission) — after all testing

**Milestone**: All features complete, published to OpenWrt package feed

## Git Branch Strategy

```
main
├── feature/F001-project-scaffold
├── feature/F002-asn-resolver
├── feature/F003-rule-engine
├── feature/F004-cli-watchdog
├── feature/F005-rollback-safety
├── feature/F006-nftables
├── feature/F007-logging-security
├── feature/F008-multi-provider
├── feature/F009-ipv6-engine
├── feature/F010-import-automation
├── feature/F011-luci-core
├── feature/F012-luci-advanced
├── feature/F013-advanced-features
└── feature/F014-distribution-qa
```

One branch per feature. One commit per task. Merge to main after feature completion.

## Risk Items

| Risk                                  | Impact | Mitigation                                   |
|---------------------------------------|--------|----------------------------------------------|
| nftables API differences across versions | High | ipset fallback (T018), version detection     |
| RIPE rate limiting during development | Medium | Mock responses, cache layer (T006)           |
| LuCI1 CBI complexity                 | Medium | Start simple, iterate (T034 before T036)     |
| Memory constraints on 32MB devices   | High   | Streaming parse, prefix limits (T021)        |
| ash/busybox shell compatibility      | Medium | shunit2 tests on real ash (T013)             |
