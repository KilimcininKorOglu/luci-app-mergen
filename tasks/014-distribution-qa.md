# F014 - Distribution & QA

## Description

Performance stress testing, platform validation, user documentation and OpenWrt package feed submission.

**PRD Reference**: Section 11, 12, 15 (Phase 6 — Distribution)

## Tasks

### T046 - Performance & Platform Testing

**Status**: NOT_STARTED
**Priority**: P2 (High)
**Effort**: 3 days

**Description**:
50,000 prefix stress test, multi-platform validation and OpenWrt version compatibility tests.

**Dependencies**: T017, T027

**Technical Details**:
- Performance stress test:
  - 50,000 prefix, 100+ rule scenario
  - Measurements: apply time, memory usage, nft set load time
  - Targets (PRD Section 11): 1000 prefix < 5 sec, daemon < 10 MB RSS
  - Memory overflow check on 32 MB RAM device
- Platform tests:
  - x86 VM (QEMU)
  - Raspberry Pi (arm)
  - GL.iNet (mips)
- Regression tests:
  - OpenWrt 23.05
  - OpenWrt 24.xx
- E2E tests: add rule from LuCI → verify traffic

**Success Criteria**:
1. No memory overflow with 50,000 prefixes
2. 1000 prefixes applied in under 5 seconds
3. Daemon RSS < 10 MB
4. Works on 3 different platforms (x86, arm, mips)
5. Compatible with OpenWrt 23.05 and 24.xx

**Files to Touch**:
- `mergen/tests/test_performance.sh` (new)
- `mergen/tests/test_platform.sh` (new)

---

### T047 - Documentation & Package Feed Submission

**Status**: NOT_STARTED
**Priority**: P2 (High)
**Effort**: 2.5 days

**Description**:
User documentation, OpenWrt package feed PR and community announcement.

**Dependencies**: T046

**Technical Details**:
- User documentation:
  - Installation guide (opkg install)
  - Configuration guide (UCI config examples)
  - CLI reference (all commands and flags)
  - LuCI usage guide (with screenshots)
  - Troubleshooting section
- OpenWrt package feed:
  - Prepare PR to `packages` feed
  - Compliance with Makefile standards
  - License: appropriate open source license
- Community:
  - OpenWrt forum announcement
  - GitHub releases and changelog

**Success Criteria**:
1. Documentation covers all commands and features
2. User can get up and running from scratch using the installation guide
3. OpenWrt package feed PR is submitted
4. Forum announcement is posted

**Files to Touch**:
- `docs/install.md` (new)
- `docs/configuration.md` (new)
- `docs/cli-reference.md` (new)
- `docs/luci-guide.md` (new)
- `docs/troubleshooting.md` (new)

---

### T049 - GitHub Actions CI/CD Pipeline

**Status**: NOT_STARTED
**Priority**: P2 (High)
**Effort**: 1 day

**Description**:
GitHub Actions CI/CD pipeline with OpenWrt SDK Docker image for automated testing and package building.

**Dependencies**: T013

**Technical Details**:
- `.github/workflows/ci.yml` — main CI pipeline
- Trigger: push to main, pull requests
- Jobs:
  1. **Lint**: shellcheck on all `.sh` files
  2. **Unit tests**: run `tests/run_all.sh` in OpenWrt SDK Docker container
  3. **Build**: `make package/mergen/compile` in OpenWrt SDK
  4. **Package size check**: verify `.ipk` < 500 KB
- OpenWrt SDK Docker image: official `openwrt/sdk` or custom image
- Matrix strategy: test on OpenWrt 23.05 and 24.xx SDK versions
- Artifact: upload built `.ipk` as GitHub Actions artifact
- PRD Section 12 test infrastructure compliance

**Success Criteria**:
1. CI runs automatically on push and PR
2. shellcheck passes on all shell scripts
3. Unit tests run in OpenWrt SDK container
4. Package builds successfully
5. Package size is verified < 500 KB

**Files to Touch**:
- `.github/workflows/ci.yml` (new)
- `.github/workflows/release.yml` (new — optional, tag-based release)
