---
name: release
description: Cut and publish a Listen release. Use when the user asks to release, ship, publish, or cut a version of Listen.
---

# Release Listen

This is the cross-harness entry point for the Listen release workflow. Before
acting, read [the complete release procedure](../../../.claude/skills/release/SKILL.md)
and follow it exactly.

The procedure deliberately keeps the only public-release confirmation after
the version, changelog, review, commit and push are ready. `release.sh` is the
only publisher. Do not recreate its signing, notarization, tagging, appcast or
Homebrew logic in an agent instruction.
