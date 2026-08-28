package Plugins::EversoloScreenControl::Plugin;

# EversoloScreenControl - A Lyrion Music Server plugin
#
# Per-player plugin that controls the Eversolo DMP-A8 screen based on
# playback state.  Enable/disable per player from the Player Settings menu.
#
# Turns screen ON when music starts, and re-sends ON on every song change
# to reset the Eversolo's own screensaver timer (keeps screen alive during
# continuous playback without polling).  Turns screen OFF after a
# configurable delay when playback pauses or stops.

use strict;
use warnings;

use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Networking::SimpleAsyncHTTP;

use Plugins::EversoloScreenControl::Discovery;

use constant PLUGIN_VERSION => '1.2.1';

# Seconds after plugin init before the first network scan, and the interval
# between scans after that.  A sweep is cheap and asynchronous, but there is
# no reason for it to share the startup window with the server's own init.
use constant STARTUP_SCAN_DELAY => 20;
use constant RESCAN_INTERVAL    => 3600;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.eversoloscreencontrol',
    'defaultLevel' => 'INFO',
    'description'  => 'PLUGIN_EVERSOLO_SCREEN_CONTROL',
});

my $prefs = preferences('plugin.eversoloscreencontrol');

# Per-player defaults (applied the first time a player is seen)
$prefs->setPlayerDefault('enabled',          0);
$prefs->setPlayerDefault('auto_detect_ip',   1);
$prefs->setPlayerDefault('eversolo_ip',      '');
$prefs->setPlayerDefault('eversolo_port',    9529);
$prefs->setPlayerDefault('screen_off_delay', 30);

# Per-player screen-state tracker  { client_id => 0|1 }
my %screenState;

# Players already warned about a placeholder address (see _warnPlaceholder),
# keyed id/address so a DHCP change or a re-created bridge player warns again.
# Declared up here because shutdownPlugin clears it, and a lexical has to be
# in scope textually before the sub that uses it is compiled.
my %warnedPlaceholder;

sub getDisplayName {
    return 'PLUGIN_EVERSOLO_SCREEN_CONTROL';
}

sub initPlugin {
    my $class = shift;

    $class->SUPER::initPlugin(@_);

    main::INFOLOG && $log->is_info && $log->info(
        'Eversolo Screen Control v' . PLUGIN_VERSION . ' starting...'
    );

    # Register the per-player settings page
    if (main::WEBUI) {
        require Plugins::EversoloScreenControl::PlayerSettings;
        Plugins::EversoloScreenControl::PlayerSettings->new;
    }

    # Subscribe to playback STATE changes only (all players — we filter
    # per-player inside the callback).  The second filter array restricts us
    # to the playlist sub-commands that change play state, so read-only
    # queries like 'playlist tracks' / 'playlist name' never wake the callback.
    Slim::Control::Request::subscribe(
        \&_playbackCallback,
        [['playlist'], ['newsong', 'play', 'pause', 'stop', 'jump']],
    );

    # Find the Eversolos on the network.  Deferred past startup so the sweep
    # never competes with the server's own init, then repeated slowly so a
    # device that was off at boot, or that moved on a new DHCP lease, is
    # picked up without anyone touching the settings page.
    Slim::Utils::Timers::setTimer(
        undef, time() + STARTUP_SCAN_DELAY, \&_rescan,
    );

    main::INFOLOG && $log->is_info && $log->info(
        'Eversolo Screen Control plugin initialised.'
    );
}

sub shutdownPlugin {
    main::INFOLOG && $log->is_info && $log->info(
        'Eversolo Screen Control plugin shutting down.'
    );

    # Kill every pending screen-off timer (one per player).  Timers are keyed
    # by the client object, so resolve each id back to its client to match.
    for my $id (keys %screenState) {
        my $client = Slim::Player::Client::getClient($id) || next;
        Slim::Utils::Timers::killTimers($client, \&_turnScreenOff);
    }
    Slim::Utils::Timers::killTimers(undef, \&_rescan);

    %screenState       = ();
    %warnedPlaceholder = ();

    Slim::Control::Request::unsubscribe(\&_playbackCallback);
}

# ---------------------------------------------------------------------------
#  Is this address something that could be an Eversolo out on the network?
#
#  Auto-detect assumes the player IS the Eversolo, which holds for a
#  Squeezelite talking SlimProto from the device itself.  It does NOT hold for
#  a bridged or virtual player (HQPlayer Bridge, LMS-Groups, UPnP bridges):
#  those have no socket, so LMS reports whatever placeholder address their
#  creator handed the constructor.  HQPlayer Bridge passes INADDR_LOOPBACK, so
#  the player answers 127.0.0.1 and every command goes to the LMS server
#  itself -- "Connect timed out: Transport endpoint is not connected".
#
#  Called from PlayerSettings too, to flag the same case in the UI.
# ---------------------------------------------------------------------------
sub isPlaceholderIP {
    my $ip = shift;

    return 1 if !defined $ip || $ip eq '';
    return 1 if $ip =~ /^127\./;                 # loopback
    return 1 if $ip eq '0.0.0.0' || $ip eq '::' || $ip eq '::1';

    return 0;
}

# ---------------------------------------------------------------------------
#  Resolve the Eversolo address for a given player.
#
#  The Eversolo's address is a property of the DEVICE, not of the player: the
#  plugin is configured on whatever player feeds that Eversolo, and the player
#  may be a bridge sitting anywhere on the network.  So the address configured
#  for this player always wins, and the player's own IP is only ever a
#  convenience for the one case where they happen to be the same box.
#
#  The ladder:
#    1. the address configured for this player  — always wins
#    2. a device found by the network scan      — one match, used outright
#    3. the player's own IP                     — only when auto-detect is on
#                                                  and it is a real address
#                                                  (a Squeezelite running on
#                                                  the Eversolo itself)
# ---------------------------------------------------------------------------
sub _resolveIP {
    my $client = shift;

    my $cprefs = $prefs->client($client);

    # 1. Configured address. Hardcode it and nothing else is consulted.
    my $manual = $cprefs->get('eversolo_ip') || '';
    $manual =~ s/^\s+|\s+$//g;
    return $manual if $manual ne '';

    # 2. Discovered device. With exactly one Eversolo on the network there is
    #    nothing to choose between, so use it — this is what makes a bridged
    #    player work with no configuration at all. With several, the settings
    #    page asks which one rather than guessing.
    my $found = Plugins::EversoloScreenControl::Discovery::found();
    my @ips   = sort keys %$found;

    if (@ips == 1) {
        return $ips[0];
    }
    elsif (@ips > 1) {
        _warnAmbiguous($client, \@ips);
    }

    # 3. The player itself, when it really is the device.
    if ($cprefs->get('auto_detect_ip')) {
        my $ip = $client->ip() || '';
        $ip =~ s/:.*$//;   # strip port if present

        return $ip unless isPlaceholderIP($ip);

        _warnPlaceholder($client, $ip, scalar(@ips));
    }

    return '';
}

# ---------------------------------------------------------------------------
#  Periodic network scan.
#
#  Timers hand the keyed object back as the first argument (setTimer($obj, ...)
#  calls $cb->($obj, @args)), so the leading undef here is the key, not a
#  mistake — this timer is keyed on nothing because there is one scan for the
#  whole server, not one per player.
# ---------------------------------------------------------------------------
sub _rescan {
    Plugins::EversoloScreenControl::Discovery::scan(sub {
        Slim::Utils::Timers::setTimer(
            undef, time() + RESCAN_INTERVAL, \&_rescan,
        );
    });
}

sub _warnAmbiguous {
    my ($client, $ips) = @_;

    my $key = ($client->id() || '') . '/ambiguous';
    return if $warnedPlaceholder{$key}++;

    $log->warn(sprintf(
        "Eversolo [%s]: %d devices answer the control API (%s) — pick the right one under Player Settings > Eversolo Screen Control",
        $client->name() || $client->id(), scalar(@$ips), join(', ', @$ips)
    ));
}

sub _warnPlaceholder {
    my ($client, $ip, $foundCount) = @_;

    my $key = ($client->id() || '') . '/' . ($ip || '');
    return if $warnedPlaceholder{$key}++;

    $log->warn(sprintf(
        "Eversolo [%s]: this player is bridged or virtual (%s), and the network scan found %s — set the Eversolo's address under Player Settings > Eversolo Screen Control, or press Scan again once the device is awake.",
        $client->name() || $client->id(),
        $ip || 'no address',
        $foundCount ? "$foundCount devices to choose between" : 'no device'
    ));
}

# ---------------------------------------------------------------------------
#  Event callback — fires for every player, we filter per-player prefs here
# ---------------------------------------------------------------------------
sub _playbackCallback {
    my $request = shift;
    my $client  = $request->client() || return;
    my $id      = $client->id()      || return;

    # ---- Per-player gate: is Eversolo control enabled for THIS player? ----
    return unless $prefs->client($client)->get('enabled');

    my $eversolo_ip = _resolveIP($client);
    return unless $eversolo_ip && $eversolo_ip ne '';

    # Determine current playback mode
    my $mode = Slim::Player::Source::playmode($client) || 'stop';

    # Detect "playlist newsong" — this fires on every track change and is
    # used to re-send Screen.ON so the Eversolo's own screensaver timer is
    # reset each time a new song starts.
    my $isNewSong = $request->isCommand([['playlist'], ['newsong']]) ? 1 : 0;

    main::DEBUGLOG && $log->is_debug && $log->debug(
        sprintf('Eversolo [%s]: mode=%s  newsong=%d  request=%s',
            $client->name() || $id, $mode, $isNewSong,
            $request->getRequestString())
    );

    if ($mode eq 'play') {
        _onPlay($client, $isNewSong);
    }
    elsif ($mode eq 'pause' || $mode eq 'stop') {
        _onPauseOrStop($client);
    }
}

# ---------------------------------------------------------------------------
#  Playback started or new song began
# ---------------------------------------------------------------------------
sub _onPlay {
    my ($client, $isNewSong) = @_;
    my $id = $client->id();

    # Cancel any pending screen-off timer for this player
    Slim::Utils::Timers::killTimers($client, \&_turnScreenOff);

    # On a song change we ALWAYS re-send Screen.ON.  This resets the
    # Eversolo's own screensaver/screen-off timer so it never kicks in
    # during continuous playback — no polling needed.
    if ($isNewSong) {
        main::INFOLOG && $log->is_info && $log->info(
            sprintf('Eversolo [%s]: New song — refreshing screen ON',
                $client->name() || $id)
        );
        _sendEversoloCommand($client, 'Key.Screen.ON');
        $screenState{$id} = 1;
    }
    elsif (!$screenState{$id}) {
        # First play after the screen was off — turn it on
        main::INFOLOG && $log->is_info && $log->info(
            sprintf('Eversolo [%s]: Play detected — turning screen ON',
                $client->name() || $id)
        );
        _sendEversoloCommand($client, 'Key.Screen.ON');
        $screenState{$id} = 1;
    }
    else {
        main::DEBUGLOG && $log->is_debug && $log->debug(
            sprintf('Eversolo [%s]: Play detected — screen already ON',
                $client->name() || $id)
        );
    }
}

# ---------------------------------------------------------------------------
#  Playback paused or stopped
# ---------------------------------------------------------------------------
sub _onPauseOrStop {
    my $client = shift;
    my $id     = $client->id();

    # // not || so that a configured delay of 0 (immediate off) is honoured
    my $delay = $prefs->client($client)->get('screen_off_delay');
    $delay = 30 if !defined $delay;

    main::INFOLOG && $log->is_info && $log->info(
        sprintf('Eversolo [%s]: Pause/Stop detected — screen OFF in %ds',
            $client->name() || $id, $delay)
    );

    # Reset any existing timer, then set a fresh one.  Key the timer on the
    # client object (a unique reference) — NOT $id.  Slim::Utils::Timers
    # matches the key numerically, so two players' string ids would collide
    # and one player's killTimers would cancel another player's off-timer.
    Slim::Utils::Timers::killTimers($client, \&_turnScreenOff);
    Slim::Utils::Timers::setTimer(
        $client,                      # obj  (used to match killTimers)
        time() + $delay,              # when
        \&_turnScreenOff,             # callback
    );
}

# ---------------------------------------------------------------------------
#  Timer fires — actually turn the screen off
# ---------------------------------------------------------------------------
sub _turnScreenOff {
    my $client = shift;          # timer key is the client object
    return unless $client && ref $client;

    my $id = $client->id();

    # Safety: if playback has resumed in the meantime, bail out
    my $mode = Slim::Player::Source::playmode($client) || 'stop';
    if ($mode eq 'play') {
        main::DEBUGLOG && $log->is_debug && $log->debug(
            sprintf('Eversolo [%s]: Timer fired but player is playing — skipping OFF',
                $client->name() || $id)
        );
        return;
    }

    main::INFOLOG && $log->is_info && $log->info(
        sprintf('Eversolo [%s]: Delay elapsed — turning screen OFF',
            $client->name() || $id)
    );

    _sendEversoloCommand($client, 'Key.Screen.OFF');

    $screenState{$id} = 0;
}

# ---------------------------------------------------------------------------
#  Send HTTP command to the Eversolo (non-blocking)
# ---------------------------------------------------------------------------
sub _sendEversoloCommand {
    my ($client, $key) = @_;

    my $ip   = _resolveIP($client)                                || return;
    my $port = $prefs->client($client)->get('eversolo_port')      || 9529;

    my $url = "http://${ip}:${port}/ZidooControlCenter/RemoteControl/sendkey?key=${key}";

    main::INFOLOG && $log->is_info && $log->info("Eversolo: GET $url");

    my $http = Slim::Networking::SimpleAsyncHTTP->new(
        \&_httpOK,
        \&_httpError,
        {
            timeout => 5,
            command => $key,
            player  => ($client->name() || $client->id()),
            target  => "${ip}:${port}",
            # A failure against a placeholder address has one cause and one
            # cure, so say so in the error rather than leaving a bare timeout.
            hint    => isPlaceholderIP($ip)
                ? " (that address is this server, not an Eversolo — set the device's IP under Player Settings > Eversolo Screen Control)"
                : '',
        },
    );

    $http->get($url);
}

sub _httpOK {
    my $http    = shift;
    my $command = $http->params('command') || '';
    my $player  = $http->params('player')  || '';
    main::INFOLOG && $log->is_info && $log->info(
        "Eversolo [$player]: '$command' sent OK"
    );
}

sub _httpError {
    my $http    = shift;
    my $error   = shift || 'unknown error';
    my $command = $http->params('command') || '';
    my $player  = $http->params('player')  || '';
    my $target  = $http->params('target')  || '';
    my $hint    = $http->params('hint')    || '';
    $log->error("Eversolo [$player]: Failed '$command' to $target — $error$hint");
}

1;

__END__
