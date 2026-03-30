# Versioning Guide

This document explains the versioning system for the Splunk Lab project and how developers should work with it.

## Overview

The Splunk Lab uses [Semantic Versioning](https://semver.org/) (SemVer) with the format `MAJOR.MINOR.PATCH`:

- **MAJOR** — Incompatible changes (breaking changes to setup, configuration, or major features)
- **MINOR** — New features or enhancements (backwards-compatible additions)
- **PATCH** — Bug fixes and minor improvements (backwards-compatible fixes)

## Version Storage

The version is stored in a single source of truth: the `VERSION` file at the project root.

```
VERSION                  # Single source of truth (e.g., "0.1.0")
version.py               # Python module that reads from VERSION file
```

All components (status-api, Docker images, lab-guide UI) read from this file programmatically.

## How Versioning Works

### 1. Version Display

The current version is displayed in:
- **Status Dashboard** — Shows `v{VERSION}` in the status page header (http://localhost:3131)
- **Status API** — Returns version in JSON response at `/api/status`
- **Docker Images** — Tagged with the version number during releases

### 2. Automatic Version Propagation

The `version.py` module provides programmatic access to the version:

```python
from version import __version__
print(__version__)  # e.g., "0.1.0"
```

The status-api imports this module and includes it in the `/api/status` endpoint response, which the lab-guide UI then displays.

## Developer Workflow

### Making Changes

When working on changes, follow this workflow:

1. **Create a feature branch**
   ```bash
   git checkout -b feature/my-new-feature
   ```

2. **Make your changes**
   - Implement your feature or fix
   - Run tests to verify: `pytest tests/ -v`

3. **Update version if needed**
   - For bug fixes: increment PATCH (e.g., `0.1.0` → `0.1.1`)
   - For new features: increment MINOR (e.g., `0.1.0` → `0.2.0`)
   - For breaking changes: increment MAJOR (e.g., `0.1.0` → `1.0.0`)

   Edit the `VERSION` file:
   ```bash
   echo "0.2.0" > VERSION
   ```

4. **Commit and push**
   ```bash
   git add .
   git commit -m "Add new feature with version bump"
   git push origin feature/my-new-feature
   ```

5. **Create a pull request**
   - Open a PR against `main`
   - CI tests will run automatically
   - Once approved, merge to `main`

### Creating a Release

Releases are automated via GitHub Actions when you push a version tag:

1. **Ensure VERSION file is updated**
   ```bash
   cat VERSION  # Should show the new version, e.g., "0.2.0"
   ```

2. **Create and push a version tag**
   ```bash
   git tag v0.2.0
   git push origin v0.2.0
   ```

3. **Automatic release process**
   The GitHub Actions `release.yml` workflow will:
   - Verify that the tag matches the VERSION file
   - Build Docker images with version tags (`splunk-lab-status-api:0.2.0`, `splunk-lab-mcp:0.2.0`)
   - Create a release archive (`splunk-lab-0.2.0.tar.gz`)
   - Generate a changelog from git commits
   - Create a GitHub Release with the changelog and archive
   - Update the `latest` tag to point to this release

4. **GitHub Release created**
   - View at: https://github.com/andrewkriley/splunk-lab/releases
   - Includes: changelog, source archive, and release notes

## Version Tag Format

Version tags must follow the format `v{MAJOR}.{MINOR}.{PATCH}`:

- ✅ Valid: `v0.1.0`, `v1.0.0`, `v2.3.4`
- ❌ Invalid: `0.1.0`, `v0.1`, `release-0.1.0`

The leading `v` is required for Git tags but omitted in the VERSION file and display.

## Testing Version Changes

To test version display locally:

1. **Update VERSION file**
   ```bash
   echo "0.2.0-dev" > VERSION
   ```

2. **Rebuild and restart the stack**
   ```bash
   docker compose down
   docker compose up -d --build
   ```

3. **Check version display**
   - Open http://localhost:3131 and click "Status"
   - Version should appear in the status page header
   - API: `curl http://localhost:3131/api/status | jq .version`

## Troubleshooting

### Version not showing in UI

If the version doesn't appear in the status dashboard:

1. Check that the VERSION file exists and contains valid version:
   ```bash
   cat VERSION
   ```

2. Verify the status-api can read the version:
   ```bash
   docker compose logs status-api | grep version
   ```

3. Check the API response:
   ```bash
   curl -s http://localhost:3131/api/status | jq .version
   ```

4. Rebuild the status-api container:
   ```bash
   docker compose down
   docker compose build status-api
   docker compose up -d
   ```

### Tag already exists

If you need to move a tag:

```bash
# Delete local tag
git tag -d v0.2.0

# Delete remote tag
git push origin :refs/tags/v0.2.0

# Create new tag
git tag v0.2.0
git push origin v0.2.0
```

### VERSION file doesn't match tag

The release workflow will fail if the VERSION file doesn't match the tag. To fix:

1. Update the VERSION file to match the tag you want to create
2. Commit the change
3. Create the tag pointing to that commit

## Best Practices

1. **Always update VERSION before tagging** — The VERSION file is the source of truth
2. **Use descriptive commit messages** — They become part of the release changelog
3. **Test before releasing** — Run the full test suite before pushing a version tag
4. **Document breaking changes** — Major version bumps should be clearly documented
5. **Keep versions in sync** — Don't create orphaned tags that don't match VERSION file

## Pre-push Hook

The repository includes a pre-push hook that runs integration tests before allowing pushes. This ensures version changes don't break the lab:

```bash
# Install the hook (one-time setup)
cp hooks/pre-push .git/hooks/pre-push
chmod +x .git/hooks/pre-push
```

The hook will automatically test the stack before pushing, helping catch version-related issues early.

## Examples

### Releasing a Bug Fix (Patch)

```bash
# Update VERSION file
echo "0.1.1" > VERSION

# Commit the change
git add VERSION
git commit -m "Fix status API connection timeout"

# Push to main
git push origin main

# Create and push tag
git tag v0.1.1
git push origin v0.1.1
```

### Releasing a New Feature (Minor)

```bash
# Update VERSION file
echo "0.2.0" > VERSION

# Commit with your feature changes
git add VERSION your-new-files
git commit -m "Add OpenTelemetry integration"

# Push to main
git push origin main

# Create and push tag
git tag v0.2.0
git push origin v0.2.0
```

### Releasing Breaking Changes (Major)

```bash
# Update VERSION file
echo "1.0.0" > VERSION

# Commit with your breaking changes
git add VERSION modified-files
git commit -m "BREAKING: Migrate to Splunk 11.0"

# Push to main
git push origin main

# Create and push tag with release notes
git tag -a v1.0.0 -m "Major release: Splunk 11.0 upgrade

Breaking Changes:
- Requires Splunk 11.0 or later
- Updated MCP server API
- New environment variable configuration format"

git push origin v1.0.0
```
