# .github
This repo contains items that are shared by all repositories in the Cardinalblue org.

This repo contains items that are shared by all repositories in the Adobe org.

## Issue & Pull Request Templates

If your repo does not override these templates by providing your own versions, it will receive these templates by default.

Details on creating your own templates can be found in github docs. 
[Using templates to encourage useful issues and pull requests](https://docs.github.com/en/github/building-a-strong-community/using-templates-to-encourage-useful-issues-and-pull-requests)
## Shared Workflows

Reusable workflows called by the backend repos (pic-collage-server, pic-collage-stickers,
piccollage-async-server). Each one is called by a thin stub in the repo; the logic lives
here, so a change applies to all three at once.

| workflow | what it does | notes |
|---|---|---|
| `backend-claude-code-review.yml` | Reports blockers and obvious mistakes as resolvable inline threads, plus one sticky status comment. | Silence is the expected outcome. Never raises a point already on the PR. |
| `backend-pr-risk.yml` | One sticky comment saying how much attention the PR deserves and where to spend it. | Routing only — it never reports findings. See `backend-pr-risk/README.md`. |
