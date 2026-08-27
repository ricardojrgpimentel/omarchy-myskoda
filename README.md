# MySkoda for Omarchy

A read-only Omarchy bar widget for vehicles available through MySkoda. The bar
shows a car icon and highlights it while charging. Click it for the last known
location, address, battery or fuel level, remaining range, charging status,
lock state, odometer, software version, and any open doors, windows, boot, or
bonnet.

The helper talks directly to the same private API used by the MySkoda app. It
does not require Python or the `myskoda` package. Its only dependencies are
`curl`, `jq`, `awk`, and `openssl`, which are present in Omarchy.

## Test on an Omarchy machine

The repository is currently private, so authenticate the GitHub CLI first and
clone it locally:

```sh
gh auth login
gh repo clone ricardojrgpimentel/omarchy-myskoda
cd omarchy-myskoda
```

Run the offline checks and validate the plugin before installing it:

```sh
tests/test.sh
omarchy plugin validate .
omarchy plugin add "$PWD" --enable
```

The widget defaults to the right side of the bar. Move it later with
`omarchy bar move` or through the bar settings.

### Test the interface without an account

Install the included synthetic Enyaq reading, then open the widget from the
bar:

```sh
mkdir -p ~/.config/omarchy-myskoda
cp tests/fixture.json ~/.config/omarchy-myskoda/fixture.json
```

The fixture prevents all vehicle API requests. Remove it before testing your
real car:

```sh
rm ~/.config/omarchy-myskoda/fixture.json
```

### Connect your MySkoda account

Open the MySkoda widget from the bar, choose **Sign in with MyŠkoda**, and
complete the sign-in only in the official Volkswagen Group/MyŠkoda page. The
plugin registers a local handler so the final `myskoda://` return address is
normally completed automatically. If a browser cannot return automatically,
copy that complete address from the browser and paste it into the widget, then
choose **Finish sign-in**.

The widget never asks for your email address or password. It only opens the
official sign-in page and uses the resulting OAuth return address to finish the
connection.

The terminal flow remains available if needed:

```sh
~/.config/omarchy/plugins/community.myskoda/bin/myskoda login
```

Confirm that the account and live vehicle snapshot work before opening the
widget:

```sh
helper=~/.config/omarchy/plugins/community.myskoda/bin/myskoda
"$helper" vehicles | jq
"$helper" car | jq
```

The first vehicle is selected by default. If `vehicles` returns more than one,
open the widget settings and enter the desired VIN.

### Remove or retry

Remove the installed plugin without deleting its credentials:

```sh
omarchy plugin remove community.myskoda
```

Remove the local MySkoda tokens as well:

```sh
rm -rf ~/.config/omarchy-myskoda
rm -rf ~/.cache/omarchy-myskoda
```

After this repository becomes public, installation directly from its Git URL
will also be possible.

## Authentication details

The login command uses OAuth PKCE and the official Volkswagen Group identity
page.

Only the resulting rotating refresh token and short-lived access token are
stored. Your email and password are entered only on the official identity page
and are never seen by this plugin.

If you already have a MySkoda OIDC refresh token, import it instead:

```sh
~/.config/omarchy/plugins/community.myskoda/bin/myskoda token
```

## Security and privacy

Tokens are stored with mode `0600` under
`~/.config/omarchy-myskoda/`. QML never reads credentials; it only executes the
helper and consumes one sanitized JSON object. Set `MYSKODA_REFRESH_TOKEN` to
keep the refresh token in an external secret manager instead.

The map uses cached CARTO/OpenStreetMap tiles. It reveals the viewed map area
to that tile provider, but not the car identity. The street address comes from
MySkoda itself; the plugin does not send coordinates to a geocoder.

The integration performs GET requests only after authentication. It contains
no wake, lock/unlock, climate, horn, or charging controls. Unsupported endpoints
are tolerated so EV, hybrid, and combustion vehicles can show the data their
subscriptions provide.

Sign out locally with:

```sh
~/.config/omarchy/plugins/community.myskoda/bin/myskoda logout
```

## Status

This is an early, unofficial integration and is not affiliated with or endorsed
by Škoda Auto. The MySkoda API is private and may change without notice. Initial
live-account testing is still required on an Omarchy machine.

## Credits

The Omarchy widget structure and cached slippy-map approach were inspired by
[`jankeesvw/omarchy-tesla`](https://github.com/jankeesvw/omarchy-tesla). API
routes and authentication behavior were derived from the MIT-licensed
[`skodaconnect/myskoda`](https://github.com/skodaconnect/myskoda) project.

## License

MIT
