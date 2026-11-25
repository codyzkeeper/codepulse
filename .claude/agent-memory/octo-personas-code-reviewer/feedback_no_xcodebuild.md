---
name: feedback-no-xcodebuild
description: In Codepulse reviews, do not run xcodebuild; builds/tests go through a shared machine queue the caller runs
metadata:
  type: feedback
---

Do not run `xcodebuild` (build or test) when reviewing Codepulse (the PRThroughput macOS menu-bar app). Reviews are read-only unless asked otherwise.

**Why:** builds go through a shared machine queue; the caller runs them.

**How to apply:** reason statically about compile and test behavior and flag anything that needs a build to confirm, rather than running it.
