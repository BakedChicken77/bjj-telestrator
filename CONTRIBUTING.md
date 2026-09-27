# Contributing

Use short feature branches and pull requests into `main`. Prefer focused commits with clear messages such as `fix: preserve annotation timing after seek`. Avoid mixing unrelated formatting or generated media with a behavior change. The configured solo-maintainer policy requires CI and resolved conversations without requiring an impossible self-approval.

Install dependencies using README.md. Run `backend/.venv/bin/python scripts/verify.py --browser` (use the Windows virtualenv path on Windows), and `python -m unittest discover -s tests/repository -v` for release/setup utilities. Native Swift changes require the iOS CI job and physical iPhone checks where hardware behavior matters. Do not replace native tests with browser mocks.

Maintain normalized display coordinates and half-open annotation intervals. Preserve original media. Treat a gesture as one undoable edit. Persist projects atomically and keep large media out of JavaScript memory. Never bypass a failed export or native test to publish a release.

Use the existing pinned package/lock files. Review Dependabot PRs and rerun `npm run ios:sync` when Capacitor changes so the managed SPM package remains aligned. Do not commit `node_modules`, `.venv`, `public/` generated iOS assets, build output, `.xcresult`, recordings, project data, signing keys or provisioning profiles. The release packager rejects credential/generated-data paths accidentally added to Git.

For a release, update frontend/package.json and package-lock.json to the same semantic version, add its CHANGELOG section, merge the PR after CI, then push the matching `vX.Y.Z` tag. The release workflow independently reruns all required gates on that tag before publication. Published releases are not overwritten by reruns. See docs/GITHUB_SETUP.md for signing and distribution.

The repository is private by default and no open-source license has been assigned automatically. Third-party dependencies retain their own licenses. Decide the application's distribution license explicitly before making the repository public.
