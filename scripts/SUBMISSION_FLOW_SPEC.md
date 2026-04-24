# Impact Scholars Submission Flow Specification

Companion to `create-submission-target.sh`. Covers the design context and surrounding infrastructure — the script itself is the source of truth for operational details.

## Overview

Authors work in their own public GitHub repositories (created from a template) and submit via a script that opens a PR against a private review target repo in `impact-scholars/`. Reviewers see a preview deployment per PR; merging to `main` publishes to GitHub Pages.

```
┌─────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────┐    ┌─────────┐
│  Template   │───▶│ Author repo  │───▶│ Script opens │───▶│ Review + │───▶│  Merge  │
│ (main/bare) │    │ (from tmpl)  │    │  PR against  │    │  preview │    │ deploys │
│             │    │              │    │ review target│    │          │    │ to Pages│
└─────────────┘    └──────────────┘    └──────────────┘    └──────────┘    └─────────┘
```

## Repository Roles

### Template repo (`impact-scholars/isp-micropublication-template`)
- `main`: full author-facing template with examples and instructions
- `bare`: minimal skeleton (empty frontmatter, placeholder media, 3-line README) carrying the unified `publish.yml` workflow used by review targets

### Author repo
Forked via GitHub's "Use this template" button from `main`. **Must be public** — cross-repo operations (fetching content, contributor queries) require it.

### Review target repo (created by the script)
- `main`: single "startpoint" commit derived from `bare` — no template history
- `review`: author's content applied on top of startpoint; this is the PR branch

Private during review so reviewer comments and preview URLs aren't public.

## CI/CD

Workflows live on the `bare` branch of the template and get inherited by every review target through `.github/workflows/publish.yml`.

### Trigger behavior

| Event | Jobs | Result |
|---|---|---|
| Pull request | `validate` → `preview` | Preview deployed to Cloudflare Pages, URL posted as sticky PR comment |
| Push to `main` | `validate` → `deploy` | Paper deployed to GitHub Pages |
| Workflow dispatch | `validate` → `deploy` | Manual deployment to GitHub Pages |

### Shared workflows (`impact-scholars/isp-actions-config`)

- **`validate-paper.yml`**: required files (`index.md`, `myst.yml`), frontmatter, thumbnail
- **`deploy-paper.yml`**: base + optional paper-specific conda env, builds exports (PDF, Typst) then HTML. `target` input selects deployment:
  - `pages` (default): uploads artifact and deploys to GitHub Pages; `base_url` defaults to `/${repo-name}`
  - `cloudflare`: deploys `_build/html` to Cloudflare Pages (single project `impact-scholars`, per-PR branch), posts sticky preview comment

### Secrets

Cloudflare credentials (`CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`) are set as **per-repo secrets** by the script. Org-level secrets would be simpler, but GitHub's free plan does not share org secrets with private repos, so each review target gets its own copy.

## Template `bare` vs `main`

| File | `main` (author template) | `bare` (review target seed) |
|---|---|---|
| `index.md` | Full example content | Empty frontmatter |
| `myst.yml` | 5 example authors | Empty `authors: []` |
| `bib.bib` | Example citation | Comment only |
| `figure.png`, `thumbnails/thumbnail.png` | 2MB examples | 1×1 transparent pixel |
| `README.md` | Full instructions | 3-line credit |
| Workflows | `validate.yml` + `deploy.yml` | `publish.yml` (unified review workflow) |

## Review & publish flow

- PR diff shows author additions vs bare skeleton (workflow differences are expected)
- Automatic preview deployment on every PR update, URL posted as a sticky comment
- Authors have write access to `review` and can push fixes
- Merging the PR to `main` triggers deployment to GitHub Pages — no tag required

## Security notes

1. Public author repos only (enforced by the script) — required for cross-repo ops
2. Review targets are private during review
3. Contributors get `push`, not admin, on targets
4. `bare` contains no credentials; secrets are injected per-repo at creation time

## Future enhancements

- [ ] Support private author repos (requires a bot collaborator invitation)
- [ ] Auto-detect GitHub usernames from `myst.yml` if schema supports it
- [ ] Webhook/GitHub Action version of script for self-service submission
- [ ] Archive/close target repos after publication
