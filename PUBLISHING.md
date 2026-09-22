# Marketplace submission

Prepared for the [Omarchy publishing guide](https://plugins.omarchy.org/publish.html).

## Before submitting

- Review and commit the release files, then push them to `main`.
- Make `ricardojrgpimentel/omarchy-myskoda` public. The marketplace cannot
  validate a private repository.
- The root `preview.png` is the supplied screenshot edited to hide the entire
  map, street address, and license plate. The original screenshot is not
  included in the repository.
- Manual tests were confirmed complete by the maintainer on 2026-09-20.

Local release checks:

```sh
tests/test.sh
omarchy plugin validate .
qmllint -I /usr/share/omarchy/shell Panel.qml MapView.qml
git diff --check
```

## Issue form values

Open [Submit a plugin](https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=submit-plugin.yml).

**Title:** `[Plugin]: MySkoda`

**Repository URL:** https://github.com/ricardojrgpimentel/omarchy-myskoda

**Category:** Widgets

**Tags:** Bar, Quickshell

**Suggest a missing tag:** Leave blank.

**Maintainer notes:**

MySkoda is an unofficial, read-only vehicle widget for the Omarchy Quattro
bar. It displays vehicle location, range, battery or fuel level, charging,
lock state, and odometer data from the official MyŠkoda Public API.

Install and remove through `omarchy plugin add` / `omarchy plugin remove`.
There is no custom installer and no root access is required. Runtime
dependencies are Bash, curl, jq, awk, Python 3, standard system utilities,
and the Omarchy Quattro shell. Users create their own API key in the
MyŠkoda app. Credentials are stored locally with restrictive permissions;
removal preserves account data unless the user explicitly deletes it.

The helper sends GET requests only. Maps use cached OpenStreetMap tiles.
The source is MIT licensed; third-party credits are in NOTICE. The plugin
is not affiliated with or endorsed by Škoda Auto.

Review the issue form's submission checkboxes before sending it. Marketplace
approval covers the listing, not a security review.
