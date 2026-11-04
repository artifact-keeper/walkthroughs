# acme-review

Code review the way Acme reviewers do it. Install it in Claude Code and ask for a review, or
run `/acme-review:checklist` before you open a pull request.

- **Skill `review`**: reviews a change in a fixed order (scope, safety, tests, operability) and
  ends with `ready`, `ready after nits` or `not ready`.
- **Command `checklist`**: the pre-merge checklist, filled in for the current working tree.
- **Agent `reviewer`**: a read-only second reviewer for authentication, input handling,
  secrets and dependencies.
- **Hook**: at session start it prints one line saying the plugin is installed. It runs
  nothing else.

Owner: Acme Platform Team. Published to the internal registry; do not copy it elsewhere.
