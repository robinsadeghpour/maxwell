# Security

Maxwell runs on your Mac with your permissions: it reads Claude Code's files, installs a hook into Claude Code's settings, starts `claude` processes, and updates itself from this repository's releases. A problem in any of these matters.

**To report a vulnerability,** use GitHub's private reporting: the **Security** tab of this repository, then **Report a vulnerability**. Please don't open a public issue. You'll get an answer within a few days.

Releases are built by the `Release` workflow from `v1`, signed with a Developer ID certificate and notarized by Apple. The signing secrets are only available to runs started on `v1` or `main`. Only the latest release gets fixes.
