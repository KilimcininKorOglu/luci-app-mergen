# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-04-04

### Added
- SDK-less IPK package builder and release workflow
- GitHub Actions CI/CD pipeline with lint, test, build and release workflows
- Bilingual documentation (Turkish + English) for installation, configuration, CLI, LuCI and troubleshooting
- Performance and platform compatibility test suites
- mwan3 integration with conflict detection and dual mode
- Traffic statistics via nftables counters and interface failover
- Country-based routing via RIR delegated stats resolution
- DNS-based routing via dnsmasq nftset/ipset integration
- Full advanced settings and provider maintenance LuCI pages
- Interfaces status page and live log viewer
- ASN Browser page with search, compare and quick rule
- Drag-drop sorting, bulk ops, clone and JSON export for rules
- Provider settings and tabbed advanced settings pages
- LuCI rules page with CRUD, validation and tags
- LuCI overview page with status cards and rules table
- luci-app-mergen package scaffold and RPC backend
- Resolve command and provider tests
- Hotplug integration for interface up/down events
- Update command for prefix refresh
- JSON import/export and rules.d auto-loading
- Rule tagging/grouping for batch operations
- CIDR conflict detection and prefix aggregation

### Changed
- Project license changed from GPL-2.0-only to MIT

### Fixed
- ShellCheck heredoc parse error and CI exclusions
- ShellCheck warnings in route.sh and engine.sh
- Mock safe mode ping in test_cli.sh and remove silent test failures from CI
- Add nft/ipset mocks to test_route.sh and fix lock path in test_core.sh
