# Versioning Convention

The version lives in `lib/brainiac/version.rb` as a module constant (`Brainiac::VERSION`).

## When to bump

Do NOT bump the version as part of regular feature or bugfix work. Version bumps are handled separately by the maintainer at release time.

## Which segment to bump (for release commits)

Use best judgement:

- **Patch** (0.3.0 → 0.3.1): Bug fixes, small corrections, one-liner changes
- **Minor** (0.3.0 → 0.4.0): New features, meaningful behavior changes, new capabilities
- **Major** (0.3.0 → 1.0.0): Breaking changes, major rewrites, incompatible API changes

Default to **patch** for most fixes. Don't over-increment — small changes get small bumps.
