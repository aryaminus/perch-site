# perch-site

The public face of [Perch](https://aryaminus.github.io/perch-site/) — an independent, open-source client for
a self-hosted [Hermes Agent](https://github.com/NousResearch/hermes-agent).

This repository holds **only** what a user or a store reviewer is ever shown:

| Path | What |
|---|---|
| [`/privacy/`](https://aryaminus.github.io/perch-site/privacy/) | the privacy policy both app stores require |
| [`/support/`](https://aryaminus.github.io/perch-site/support/) | how to get help, report content, report a vulnerability |
| [`/pair.sh`](https://aryaminus.github.io/perch-site/pair.sh) · [`/enable-approvals.sh`](https://aryaminus.github.io/perch-site/enable-approvals.sh) | the two setup scripts the app tells you to download |

It contains no application source, and it is not where issues go — the contact
address is on the support page.

Every file here is **generated** from Perch's own repository by
`tools/site/build-site.mjs` and pushed on change, so the published privacy
policy and the one in the source tree cannot drift apart.

Served straight from the branch, with `.nojekyll`: there is no site build. A
build that can fail is a privacy policy that can 404, and a store listing points
at that URL.
