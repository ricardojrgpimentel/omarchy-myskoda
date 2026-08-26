# MySkoda for Omarchy

A read-only Omarchy bar widget for vehicles available through MySkoda. The bar
shows a car icon and highlights it while charging. Click it for the last known
location, address, battery or fuel level, remaining range, charging status,
lock state, odometer, software version, and any open doors, windows, boot, or
bonnet.

The helper talks directly to the same private API used by the MySkoda app. It
does not require Python or the `myskoda` package. Its only dependencies are
`curl`, `jq`, `awk`, and `openssl`, which are present in Omarchy.

## Install

From this checkout on an Omarchy machine:

```sh
omarchy plugin add "$PWD" --enable
```

After this repository becomes public, it can be installed directly from its
Git URL. The widget defaults to the right side of the bar and can be moved with
`omarchy bar move`.

## Sign in

Run the helper from the installed plugin:

```sh
~/.config/omarchy/plugins/community.myskoda/bin/myskoda login
```

It opens the official Volkswagen Group/MySkoda sign-in page using OAuth PKCE.
After sign-in, the browser may be unable to open the final `myskoda://` address.
Copy that complete address from the browser and paste it into the terminal.

Only the resulting rotating refresh token and short-lived access token are
stored. Your email and password are entered only on the official identity page
and are never seen by this plugin.

If you already have a MySkoda OIDC refresh token, import it instead:

```sh
~/.config/omarchy/plugins/community.myskoda/bin/myskoda token
```

Confirm the account and list its vehicles:

```sh
~/.config/omarchy/plugins/community.myskoda/bin/myskoda vehicles
```

Accounts with multiple vehicles can set a VIN in the widget settings. Empty
selects the first vehicle.

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

## Offline UI testing

Copy `tests/fixture.json` to
`~/.config/omarchy-myskoda/fixture.json`. While that file exists, `car` returns
it and makes no MySkoda request. Remove it to return to live data.

Run the repository checks with:

```sh
tests/test.sh
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
