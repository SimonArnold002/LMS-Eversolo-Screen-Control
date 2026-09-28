package Plugins::EversoloScreenControl::Power;

# THE POWER PAGE: a power button for an Eversolo whose player has gone.
#
# Once an Eversolo is switched off its LMS player disappears, and with it the
# player's power button - the only thing that ever sent the Wake-on-LAN packet.
# This page needs no player.  It lists every device whose player has
# `home_power` on (see Plugin.pm, "The power page"), asks each whether it is
# answering, and gives it one button: switch on when it is off, switch off when
# it is on.  Material shows it from a Home tile (an `iframe` custom action, so it
# opens inline as a dialog); any browser can open it by its path.
#
# A RAW HANDLER, as HQPlayer Bridge's /hqplive is: the bytes below are the whole
# document, with no template, skin or settings chrome around them - the same
# footing framed in Material's dialog as standalone.
#
# THIS MODULE CALLS NOTHING IN Plugin.pm.  Its path is handed in by init, and
# everything that changes is fetched by the page over jsonrpc (`eversolopower
# status` / `eversolopower set`).  A page module that reaches into Plugin.pm at
# request time without `use`-ing it dies part way through and renders whatever
# was built by then - that shipped 1.5.0's settings page broken.
#
# THE HEREDOC DOES NOT INTERPOLATE (<<'HTML'), so the JavaScript in it is exactly
# what the browser gets: no Perl escape can eat a backslash, a `$` or an `@`.
# The localised labels go in through %%TOKEN%% substitution instead, each one
# HTML-escaped, and reach the script as data attributes on <body>.
#
# A RAW HANDLER OWNS ITS STATUS CODE.  LMS builds the status line from whatever
# the handler set and fills in nothing, so the code is set first and explicitly
# (HQPlayer Bridge shipped a literal "HTTP/1.1  " for 13 versions without it).

use strict;
use warnings;

use Encode ();

use Slim::Utils::Strings ();
use Slim::Web::Pages;
use Slim::Web::HTTP;

my $PATH = '';

sub init {
    my ( $class, $path ) = @_;

    $PATH = $path;

    Slim::Web::Pages->addRawFunction( qr{^\Q$path\E}, \&_handler );

    return;
}

sub _handler {
    my ( $httpClient, $response ) = @_;

    return unless $httpClient && $httpClient->connected;

    # OCTETS on the wire, and UTF-8 ones - the Content-Type promises it, and
    # strings.txt carries an ellipsis.  Encoded only when the page holds
    # CHARACTERS: labels that arrive as UTF-8 octets leave the whole page
    # unflagged and already right, and encoding those again would send mojibake.
    my $body = _page();
    $body = Encode::encode_utf8($body) if utf8::is_utf8($body);

    $response->code(200);
    $response->content_type('text/html; charset=utf-8');

    # A power state is live.  A cached copy of this page is a lie about it.
    $response->header( 'Cache-Control' => 'no-cache, no-store, must-revalidate' );
    $response->header( Pragma          => 'no-cache' );

    Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$body );

    return;
}

sub _page {
    my %L = (
        title    => 'PLUGIN_EVERSOLO_POWER_PAGE',
        hint     => 'PLUGIN_EVERSOLO_PP_HINT',
        on       => 'PLUGIN_EVERSOLO_PP_ON',
        off      => 'PLUGIN_EVERSOLO_PP_OFF',
        waking   => 'PLUGIN_EVERSOLO_PP_WAKING',
        stopping => 'PLUGIN_EVERSOLO_PP_STOPPING',
        turnon   => 'PLUGIN_EVERSOLO_PP_TURN_ON',
        turnoff  => 'PLUGIN_EVERSOLO_PP_TURN_OFF',
        confirm  => 'PLUGIN_EVERSOLO_PP_CONFIRM',
        nomac    => 'PLUGIN_EVERSOLO_PP_NOMAC',
        none     => 'PLUGIN_EVERSOLO_PP_NONE',
        error    => 'PLUGIN_EVERSOLO_PP_ERROR',
    );

    $_ = _esc( Slim::Utils::Strings::string($_) ) for values %L;

    my $html = PAGE();

    $html =~ s/%%(\w+)%%/exists $L{$1} ? $L{$1} : ''/ge;

    return $html;
}

sub _esc {
    my $s = shift;

    return '' unless defined $s;

    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;

    return $s;
}

use constant PAGE => <<'HTML';
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%%title%%</title>
<script>
// MATCH MATERIAL'S THEME, by LMS's own recipe - the one the classic skin's
// settings header uses, and the one HQPlayer Bridge's live page copies. Material
// keeps the user's choice in localStorage on this same origin:
//
//   lms-material::theme   dark | darker | light | auto | <name>[-colored] | user:<name>
//   lms-material::color   blue | <name> | user:<name>
//
// The stylesheets supply the background and accent colours; the text colour is
// Vuetify's there, so it is set here from the light/dark decision.
(function () {
    var theme, col;
    try {
        theme = localStorage.getItem('lms-material::theme');
        col   = localStorage.getItem('lms-material::color');
    } catch (e) { /* private mode, or no Material has ever run here */ }

    if (!theme || theme === 'darker') { theme = 'dark'; }
    if (theme === 'auto') {
        theme = (window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches)
            ? 'light' : 'dark';
    }

    var parts   = theme.split('-');
    var last    = parts[parts.length - 1];
    if (parts.length > 1 && (last === 'colored' || last === 'standard')) { parts.pop(); }
    var name    = parts.join('-');
    var isLight = theme.indexOf('light') === 0 || theme.indexOf('/light/') >= 0;

    function css(href) {
        var l = document.createElement('link');
        l.rel = 'stylesheet'; l.href = href;
        document.head.appendChild(l);
    }

    css(name.indexOf('user:') === 0
        ? '/material/usertheme/' + name.substring(5)
        : '/html/css/themes/' + (isLight ? 'light' : name) + '.min.css');

    if (col) {
        css(col.indexOf('user:') === 0
            ? '/material/usercolor/' + col.substring(5)
            : '/html/css/colors/' + col + '.min.css');
    }

    document.documentElement.className = isLight ? 'lt' : 'dk';
}());
</script>
<style>
:root {
  --bg:   var(--std-background-color, #212121);
  --card: var(--std-popup-background-color, #303030);
  --fg:   #ffffff;
  --dim:  rgba(255,255,255,0.55);
  --line: rgba(255,255,255,0.12);
  --accent: var(--accent-color, #82b1ff);
  --ok: #81c784; --bad: #ef9a9a;
}
html.lt {
  --bg:   var(--std-background-color, #fafafa);
  --card: var(--std-popup-background-color, #ffffff);
  --fg:   rgba(0,0,0,0.87);
  --dim:  rgba(0,0,0,0.54);
  --line: rgba(0,0,0,0.12);
  --accent: var(--primary-color, #1976d2);
  --ok: #2e7d32; --bad: #c62828;
}
* { box-sizing: border-box; }
body { margin: 0; padding: 16px; background: var(--bg); color: var(--fg);
       font: 15px/1.5 Roboto, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
.wrap { max-width: 640px; margin: 0 auto; }
.hint { color: var(--dim); font-size: 0.86em; margin: 0 0 16px; }
.card { display: flex; align-items: center; gap: 16px; background: var(--card);
        border: 1px solid var(--line); border-radius: 8px; padding: 16px; margin-bottom: 12px; }
.info { flex: 1 1 auto; min-width: 0; }
.name { font-weight: 600; font-size: 1.08em; overflow-wrap: anywhere; }
.state { color: var(--dim); font-size: 0.92em; }
.state.on { color: var(--ok); }
.note { color: var(--dim); font-size: 0.82em; margin-top: 4px; }
.err  { color: var(--bad); font-size: 0.86em; margin: 0 0 12px; }
.pwr { flex: 0 0 auto; width: 64px; height: 64px; border-radius: 50%; cursor: pointer;
       border: 2px solid var(--line); background: transparent; color: var(--dim);
       display: flex; align-items: center; justify-content: center; padding: 0;
       transition: color .2s, border-color .2s, background .2s; }
.pwr svg { width: 32px; height: 32px; fill: currentColor; }
.pwr:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; }
.pwr.on { color: var(--ok); border-color: var(--ok); }
.pwr.armed { color: var(--bad); border-color: var(--bad); }
.pwr.waking, .pwr.stopping { color: var(--accent); border-color: var(--accent);
                             animation: pulse 1.2s ease-in-out infinite; }
.pwr:disabled { cursor: default; }
.pwr.off:disabled { opacity: 0.4; }
@keyframes pulse { 50% { opacity: 0.35; } }
[hidden] { display: none !important; }
</style>
</head>
<body data-on="%%on%%" data-off="%%off%%" data-waking="%%waking%%" data-stopping="%%stopping%%"
      data-turnon="%%turnon%%" data-turnoff="%%turnoff%%" data-confirm="%%confirm%%"
      data-nomac="%%nomac%%">
<div class="wrap">
  <p class="hint">%%hint%%</p>
  <p class="err" id="err" hidden>%%error%%</p>
  <p class="hint" id="none" hidden>%%none%%</p>
  <div id="list"></div>
</div>
<script>
(function () {
    var D    = document.body.dataset;
    var list = document.getElementById('list');
    var none = document.getElementById('none');
    var err  = document.getElementById('err');

    // Material's power_settings_new glyph, inline so no icon font is needed.
    var ICON = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M13 3h-2v10h2V3zm4.83 2.17l-1.42 1.42C17.99 7.86 19 9.81 19 12c0 3.87-3.13 7-7 7s-7-3.13-7-7c0-2.19 1.01-4.14 2.58-5.42L6.17 5.17C4.23 6.82 3 9.26 3 12c0 4.97 4.03 9 9 9s9-4.03 9-9c0-2.74-1.23-5.18-3.17-6.83z"/></svg>';

    var devices = [];   // the last status answer
    var armed   = {};   // id -> timer: an ON device's first tap arms, the second switches it off
    var busy    = false;
    var timer   = null;

    function rpc(cmd, cb) {
        var x = new XMLHttpRequest();
        x.open('POST', '/jsonrpc.js', true);
        x.setRequestHeader('Content-Type', 'application/json');
        // Each probe is bounded by the server (2s per device, all in parallel),
        // so this only has to outlast that.
        x.timeout = 15000;
        x.onload = function () {
            var r = null;
            try { r = JSON.parse(x.responseText).result || null; } catch (e) { r = null; }
            cb(r);
        };
        x.onerror = x.ontimeout = function () { cb(null); };
        x.send(JSON.stringify({ id: 1, method: 'slim.request', params: ['', cmd] }));
    }

    function schedule(ms) {
        clearTimeout(timer);
        timer = setTimeout(poll, ms);
    }

    function moving() {
        return devices.some(function (d) { return d.state === 'waking' || d.state === 'stopping'; });
    }

    // Every poll asks every listed device over HTTP, so it stops while the page
    // is not being looked at and resumes the moment it is.
    function poll() {
        if (busy) { return; }
        if (document.hidden) { schedule(5000); return; }
        busy = true;
        rpc(['eversolopower', 'status'], function (r) {
            busy = false;
            if (!r) {
                err.hidden = false;
                schedule(5000);
                return;
            }
            err.hidden = true;
            devices = r.devices_loop || [];
            render();
            schedule(moving() ? 2000 : 5000);
        });
    }

    function el(tag, cls, text) {
        var e = document.createElement(tag);
        if (cls) { e.className = cls; }
        if (text !== undefined) { e.textContent = text; }
        return e;
    }

    function disarm(id) {
        if (armed[id]) { clearTimeout(armed[id]); delete armed[id]; }
    }

    function render() {
        none.hidden = devices.length > 0;
        list.textContent = '';

        devices.forEach(function (d) {
            var on      = d.state === 'on';
            var off     = d.state === 'off';
            var canwake = String(d.canwake) === '1';
            var isArmed = on && !!armed[d.id];

            if (!on) { disarm(d.id); }

            var card = el('div', 'card');
            var info = el('div', 'info');
            info.appendChild(el('div', 'name', d.name));
            info.appendChild(el('div', 'state ' + d.state,
                isArmed ? D.confirm : (D[d.state] || d.state)));
            if (off && !canwake) { info.appendChild(el('div', 'note', D.nomac)); }

            var b = el('button', 'pwr ' + d.state + (isArmed ? ' armed' : ''));
            b.type      = 'button';
            b.innerHTML = ICON;
            b.disabled  = !(on || (off && canwake));
            b.title     = on ? (isArmed ? D.confirm : D.turnoff) : (off && canwake ? D.turnon : '');
            b.setAttribute('aria-label', d.name + ': ' + (b.title || D[d.state] || d.state));
            b.onclick   = function () { press(d); };

            card.appendChild(info);
            card.appendChild(b);
            list.appendChild(card);
        });
    }

    // Off -> on is one tap.  On -> off takes two, because a stray power-off
    // costs the device a full cold boot; the first tap only arms the button for
    // four seconds.  Not confirm(): an embedded webview may never show it, and
    // then the device could never be switched off from here at all.
    function press(d) {
        if (d.state === 'on' && !armed[d.id]) {
            armed[d.id] = setTimeout(function () { delete armed[d.id]; render(); }, 4000);
            render();
            return;
        }

        var to = d.state === 'on' ? 'off' : 'on';
        disarm(d.id);

        // Say so at once; the server's own answer replaces this on the next poll.
        d.state = to === 'on' ? 'waking' : 'stopping';
        render();

        rpc(['eversolopower', 'set', 'id:' + d.id, 'to:' + to], function (r) {
            err.hidden = !!r;
            schedule(1000);
        });
    }

    document.addEventListener('visibilitychange', function () {
        if (!document.hidden) { schedule(0); }
    });

    poll();
}());
</script>
</body>
</html>
HTML

1;
