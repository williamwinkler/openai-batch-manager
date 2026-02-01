# Branch rulesets

Import these rulesets in GitHub to protect the default branch.

## main - require checks

- **File:** `main-require-checks.json`
- **Effect:** On the default branch (`main`), requires pull requests and that status checks **tests** and **format** pass before merging. Branches must be up to date (strict).

### Required status checks

The ruleset expects these status check contexts (provided by our workflows):

| Context | Workflow |
|--------|----------|
| `tests` | [CI](.github/workflows/ci.yml) – `mix test` |
| `format` | [Code Quality](.github/workflows/quality.yml) – `mix format --check-formatted` and related checks |

### How to import

1. In the repo: **Settings** → **Rules** → **Rulesets**
2. **New ruleset** → **Import a ruleset**
3. Choose `main-require-checks.json`
