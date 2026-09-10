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

use IO::Socket::INET;
use Socket ();

# Both of these are always loaded by the server, so the calls below have always
# resolved — but this module calls them itself (playmode, clients, getClient)
# and so should say so rather than rely on someone else's require.
use Slim::Player::Client;
use Slim::Player::Source;

use Plugins::EversoloScreenControl::Discovery;

use constant PLUGIN_VERSION => '2.2.0';

# There is no network scan and there must not be one. A /24 sweep took the
# server off the network (it ARP-floods the box), and the SSDP search that
# briefly replaced it was machinery for a problem that does not exist: the
# Eversolo's address is typed in once, on the player's settings page.

# Events alone are not enough to keep the screen honest.  The plugin can only
# turn a screen off in response to a stop it witnessed, so a stop it did not
# see — one that happened across a server restart, or that a bridged player
# never announced — would leave the screen on with nothing able to correct it.
# The reconcile pass compares each enabled player's real state against what the
# screen is believed to be doing and fixes any disagreement.  It reads LMS's
# own state in-process and only ever sends a command when the two disagree, so
# in the steady state it costs nothing and puts no traffic on the network.
use constant STARTUP_RECONCILE_DELAY => 15;
use constant RECONCILE_INTERVAL      => 60;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.eversoloscreencontrol',
    'defaultLevel' => 'INFO',
    'description'  => 'PLUGIN_EVERSOLO_SCREEN_CONTROL',
});

my $prefs = preferences('plugin.eversoloscreencontrol');
my $serverPrefs = preferences('server');

# Per-player defaults (applied the first time a player is seen)
$prefs->setPlayerDefault('enabled',          0);

# The address of the Eversolo this player drives.  This is the ONLY thing that
# says which device a player talks to.  The settings page fills it in from the
# network scan, or the user types it in; either way what is stored is an
# address, and nothing else has to be consulted to use it.
$prefs->setPlayerDefault('eversolo_ip',      '');

# Drive the Eversolo's power from the LMS player's power button.  OFF by
# default and deliberately so: a mis-fire costs a full cold boot, so this is
# something you turn on for the one player that feeds the device.
$prefs->setPlayerDefault('power_control',    0);

# The device's wired MAC, learned from getModel by the settings page.  Powering
# ON cannot be an HTTP call - the device is off and nothing is listening - so
# the only way up is a Wake-on-LAN packet addressed to this.
$prefs->setPlayerDefault('eversolo_mac',     '');
$prefs->setPlayerDefault('eversolo_port',    9529);
$prefs->setPlayerDefault('screen_off_delay', 30);

# Per-player screen-state tracker  { client_id => 0|1 }.  A player absent from
# this hash has an UNKNOWN screen state — which is exactly where every player
# starts after a server restart, and why the reconcile pass asserts the screen
# rather than assuming it is already right.
my %screenState;

# Players with an off-timer already scheduled { client_id => client }.  Keeping
# the client object as the value lets shutdown cancel even a reconcile-created
# timer whose screen state is still unknown.
my %offPending;

# Last song position seen for a player { client_id => seconds }, sampled once
# per reconcile pass.  A position that does not move between two passes while
# LMS still claims 'play' is the signal that LMS's state is stale — that is
# what triggers the one and only call the plugin makes to the device itself.
my %lastElapsed;

# Playback notifications invalidate an in-flight device-state question.  The
# HTTP answer is asynchronous and must not apply a pause/stop observed before a
# later play event.
my %playbackRevision;

# Likewise, an answer from a previous plugin lifecycle must not act after the
# plugin has shut down or been reloaded.
my $lifecycleRevision = 0;

# Players already warned about having no address set (see _warnNoAddress), so
# the warning is said once per player rather than once per track.  Declared up
# here because shutdownPlugin clears it, and a lexical has to be in scope
# textually before the sub that uses it is compiled.
my %warnedPlaceholder;

sub getDisplayName {
    return 'PLUGIN_EVERSOLO_SCREEN_CONTROL';
}

sub initPlugin {
    my $class = shift;

    $lifecycleRevision++;

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

    # The player's power button, for players that opted into power control.
    Slim::Control::Request::subscribe( \&_powerCallback, [['power']] );

    # Bring every enabled player's screen into line with what it is actually
    # doing, then keep checking.  Without this a player that was stopped while
    # the plugin was down keeps its screen on for ever: no further event is
    # coming, because the stop already happened.
    Slim::Utils::Timers::setTimer(
        undef, time() + STARTUP_RECONCILE_DELAY, \&_reconcile,
    );

    main::INFOLOG && $log->is_info && $log->info(
        'Eversolo Screen Control plugin initialised.'
    );
}

sub shutdownPlugin {
    main::INFOLOG && $log->is_info && $log->info(
        'Eversolo Screen Control plugin shutting down.'
    );

    $lifecycleRevision++;

    # Reconcile can schedule an off timer while screenState is still unknown,
    # so cancel the client objects retained in offPending as well as timers for
    # players which already have a known state.
    for my $client (values %offPending) {
        Slim::Utils::Timers::killTimers($client, \&_turnScreenOff) if $client;
    }

    for my $id (keys %screenState) {
        my $client = Slim::Player::Client::getClient($id) || next;
        Slim::Utils::Timers::killTimers($client, \&_turnScreenOff);
    }
    Slim::Utils::Timers::killTimers(undef, \&_reconcile);

    %screenState       = ();
    %offPending        = ();
    %lastElapsed       = ();
    %playbackRevision  = ();
    %warnedPlaceholder = ();

    Slim::Control::Request::unsubscribe(\&_playbackCallback);
    Slim::Control::Request::unsubscribe(\&_powerCallback);
}



# ---------------------------------------------------------------------------
#  Make every enabled player's screen match what that player is actually doing.
#
#  This is the safety net under the event subscription, and it is what makes a
#  bridged player behave like a direct one.  Three cases it repairs:
#
#    - the plugin was down when the player stopped (a server restart), so the
#      stop event is gone and no further one is coming;
#    - the player stopped in a way that produced no notification the plugin
#      recognised;
#    - the screen state was lost with the process, leaving it unknown.
#
#  It acts only on disagreement: a stopped player whose screen is already off
#  costs one hash lookup and sends nothing.
# ---------------------------------------------------------------------------
sub _reconcile {
    for my $client ( Slim::Player::Client::clients() ) {

        next unless $client;
        next unless $prefs->client($client)->get('enabled');

        my $id = $client->id() || next;

        my $mode = Slim::Player::Source::playmode($client) || 'stop';

        if ($mode eq 'play') {

            # LMS says playing.  Trust it only if the song clock is actually
            # moving: a player fed through a bridge can be stranded in 'play'
            # with a frozen clock when the far end stops talking, and then the
            # screen would stay on for ever on the strength of a stale state.
            my $now  = Slim::Player::Source::songTime($client) || 0;
            my $prev = $lastElapsed{$id};

            $lastElapsed{$id} = $now;

            if ( defined $prev && $now == $prev ) {
                # Frozen.  Ask the device itself rather than guess — this is
                # the only case that costs a network call, and it happens only
                # once per interval per stuck player.
                _askDevice($client);
                next;
            }

            # Playing and the clock is moving — assert the screen on.
            next if $screenState{$id};

            main::INFOLOG && $log->is_info && $log->info(sprintf(
                'Eversolo [%s]: reconcile — playing but screen not known to be on',
                $client->name() || $id
            ));

            _onPlay($client, 0);
        }
        else {
            # Not playing.  Known-off is the only state that needs nothing.
            delete $lastElapsed{$id};

            next if defined $screenState{$id} && !$screenState{$id};
            next if $offPending{$id};

            main::INFOLOG && $log->is_info && $log->info(sprintf(
                'Eversolo [%s]: reconcile — %s but screen still %s',
                $client->name() || $id, $mode,
                defined $screenState{$id} ? 'on' : 'in an unknown state'
            ));

            _onPauseOrStop($client);
        }
    }

    Slim::Utils::Timers::setTimer(
        undef, time() + RECONCILE_INTERVAL, \&_reconcile,
    );
}

# ---------------------------------------------------------------------------
#  LMS claims this player is playing but its clock has not moved.  Ask the
#  Eversolo what IT is doing and assert the screen to match — the device knows,
#  and LMS in this state does not.
#
#  Whatever the answer, the command is sent rather than skipped on the strength
#  of what the screen is believed to be doing: the belief is exactly what has
#  just been shown to be unreliable.  A device that answers nothing at all is
#  left alone.
# ---------------------------------------------------------------------------
sub _askDevice {
    my $client = shift;

    my $id   = $client->id() || return;
    my $ip   = _resolveIP($client) || return;
    my $port = $prefs->client($client)->get('eversolo_port') || 9529;
    my $requestRevision = $playbackRevision{$id} || 0;
    my $lifecycle       = $lifecycleRevision;

    Plugins::EversoloScreenControl::Discovery::deviceState($ip, $port, sub {
        my $deviceMode = shift;

        # The player, selected device, or plugin lifecycle may have changed
        # while the non-blocking request was in flight.  Only the exact state
        # which prompted the question may consume its answer.
        return unless $lifecycle == $lifecycleRevision;

        my $cprefs = $prefs->client($client);
        return unless $cprefs->get('enabled');
        return unless ($playbackRevision{$id} || 0) == $requestRevision;

        my $current_ip = $cprefs->get('eversolo_ip') || '';
        $current_ip =~ s/^\s+|\s+$//g;
        my $current_port = $cprefs->get('eversolo_port') || 9529;
        return unless $current_ip eq $ip && $current_port == $port;
        return unless ( Slim::Player::Source::playmode($client) || 'stop' ) eq 'play';

        my $name = $client->name() || $id;

        if ( !defined $deviceMode ) {
            main::INFOLOG && $log->is_info && $log->info(
                "Eversolo [$name]: LMS is stuck on 'play' with a frozen clock and the device did not answer — leaving the screen alone"
            );
            return;
        }

        if ( $deviceMode eq 'play' ) {
            main::DEBUGLOG && $log->is_debug && $log->debug(
                "Eversolo [$name]: LMS's clock is frozen but the device is playing — screen stays on"
            );
            _sendEversoloCommand($client, 'Key.Screen.ON');
            $screenState{$id} = 1;
            return;
        }

        $log->info(sprintf(
            "Eversolo [%s]: LMS still says 'play' but the device says it is %s — turning the screen off",
            $name, $deviceMode eq 'pause' ? 'paused' : 'stopped'
        ));

        Slim::Utils::Timers::killTimers($client, \&_turnScreenOff);
        delete $offPending{$id};

        _sendEversoloCommand($client, 'Key.Screen.OFF');
        $screenState{$id} = 0;
    });

    return;
}

# ---------------------------------------------------------------------------
#  Which Eversolo does this player drive?
#
#  The stored address, and nothing else.
#
#  This used to be a four-rung ladder that could fall back to the PLAYER's own
#  IP address, on the theory that a Squeezelite might be running on the Eversolo
#  itself.  That was wrong in the case that actually matters: a player fed
#  through a bridge reports whatever placeholder its creator passed in --
#  HQPlayer Bridge reports 127.0.0.1 -- so every command went to the LMS server
#  instead of to an Eversolo.  The Eversolo's address is a property of the
#  DEVICE, and the player's own address is never evidence of it, so it is not
#  consulted at all any more.  The settings page discovers the address and
#  writes it here; this reads it back.
# ---------------------------------------------------------------------------
sub _resolveIP {
    my $client = shift or return '';

    my $ip = $prefs->client($client)->get('eversolo_ip');
    $ip = '' unless defined $ip;
    $ip =~ s/^\s+|\s+$//g;

    _warnNoAddress($client) if $ip eq '';

    return $ip;
}

# Enabled for a player with no address: nothing can be sent anywhere. Said once
# per player, not once per track.
sub _warnNoAddress {
    my $client = shift;

    my $key = ($client->id() || '') . '/noaddress';
    return if $warnedPlaceholder{$key}++;

    $log->warn(sprintf(
        "Eversolo [%s]: screen control is enabled for this player but no Eversolo address is set - choose the device under Player Settings > Eversolo Screen Control",
        $client->name() || $client->id()
    ));
}


# ---------------------------------------------------------------------------
#  Power: the LMS player's power button drives the Eversolo.
#
#  The two directions are NOT symmetrical, and cannot be made so:
#
#    OFF  is one HTTP call, /ZidooMusicControl/v2/setPowerOption?tag=poweroff.
#    ON   cannot be an HTTP call at all - the device is off, so nothing is
#         listening on 9529 - and is a Wake-on-LAN magic packet instead.
#
#  (This is where an Eversolo differs from the Denon/Marantz receivers the
#  equivalent LMS plugin drives: those keep a network-standby listener alive and
#  can be woken over IP.  Eversolo do not, and say so - their own app sends a
#  WoL packet too.  The device reports whether it will accept one in getModel's
#  ableRemoteBoot, and requires its WIRED port; WoL does not work over Wi-Fi.)
#
#  Off by default per player.  A stray power event that shuts the device down
#  costs a full cold boot to undo, which is not a thing to opt somebody into.
# ---------------------------------------------------------------------------
sub _powerCallback {
    my $request = shift;
    my $client  = $request->client() || return;

    my $on   = $request->getParam('_newvalue');
       $on   = $client->power() unless defined $on;

    # LMS applies syncPower to buddies by calling their power methods directly,
    # so they do not generate their own Request notifications.  Mirror the same
    # target set here and apply each player's independent plugin preferences.
    my @clients = ($client);
    if ( $client->isSynced() ) {
        push @clients, grep {
            $_ && $serverPrefs->client($_)->get('syncPower')
        } $client->syncedWith();
    }

    my %seen;
    for my $target (@clients) {
        my $id = $target->id() || next;
        next if $seen{$id}++;
        _setDevicePower($target, $on);
    }

    return;
}

sub _setDevicePower {
    my ($client, $on) = @_;

    my $cprefs = $prefs->client($client);

    return unless $cprefs->get('enabled');
    return unless $cprefs->get('power_control');

    my $name = $client->name() || $client->id();

    if ($on) {
        _wakeDevice($client);
    }
    else {
        my $ip = _resolveIP($client) or return;

        $log->info("Eversolo [$name]: player powered off — powering the device down");

        # Any pending screen-off is moot: the device is going away entirely.
        Slim::Utils::Timers::killTimers($client, \&_turnScreenOff);
        delete $offPending{ $client->id() };
        delete $screenState{ $client->id() };

        Plugins::EversoloScreenControl::Discovery::setPowerOption(
            $ip, $cprefs->get('eversolo_port') || 9529, 'poweroff' );
    }

    return;
}

# ---------------------------------------------------------------------------
#  Wake-on-LAN.
#
#  A magic packet is six 0xFF bytes followed by the target MAC repeated sixteen
#  times, broadcast on the local network.  It is sent to the directed broadcast
#  of the device's own subnet (192.168.1.255 for a device at 192.168.1.197) as
#  well as to 255.255.255.255, because plenty of switches drop one or the other,
#  and to both of the ports the convention uses.
#
#  Nothing acknowledges a magic packet - it is fire and forget - so the screen
#  is not asserted here.  The device takes the better part of a minute to boot;
#  _reconcile notices it once it is answering.
# ---------------------------------------------------------------------------
sub _wakeDevice {
    my $client = shift;

    my $cprefs = $prefs->client($client);
    my $name   = $client->name() || $client->id();

    my $mac = Plugins::EversoloScreenControl::Discovery::normaliseMac(
        $cprefs->get('eversolo_mac') );

    if ( !$mac ) {
        $log->warn(
            "Eversolo [$name]: cannot wake the device - its hardware address is not known yet. "
          . "Open Player Settings > Eversolo Screen Control once while the device is ON, and it will be learned."
        );
        return;
    }

    my $packet = magicPacket($mac);

    my $sock = IO::Socket::INET->new( Proto => 'udp', Blocking => 0 );

    if ( !$sock ) {
        $log->warn("Eversolo [$name]: could not open a socket to wake the device - $!");
        return;
    }

    setsockopt( $sock, Socket::SOL_SOCKET(), Socket::SO_BROADCAST(), 1 );

    my @targets = ('255.255.255.255');

    # The device's own subnet, which is the one that actually has to carry it.
    my $ip = _resolveIP($client) || '';
    if ( $ip =~ /^(\d+\.\d+\.\d+)\.\d+$/ ) {
        unshift @targets, "$1.255";
    }

    for my $target (@targets) {
        my $addr = Socket::inet_aton($target) or next;

        for my $port ( 9, 7 ) {
            send( $sock, $packet, 0, Socket::pack_sockaddr_in( $port, $addr ) );
        }
    }

    close $sock;

    $log->info("Eversolo [$name]: player powered on — sent Wake-on-LAN to $mac");

    return;
}

# Six 0xFF bytes, then the MAC sixteen times: 102 bytes.  Separate so it can be
# checked byte for byte without a network (tools/t_power.pl).
sub magicPacket {
    my $mac = shift or return '';

    $mac = lc $mac;
    $mac =~ s/[^0-9a-f]//g;

    return '' unless length($mac) == 12;

    my $target = pack( 'H12', $mac );

    return ( "\xFF" x 6 ) . ( $target x 16 );
}

# ---------------------------------------------------------------------------
#  Event callback — fires for every player, we filter per-player prefs here
# ---------------------------------------------------------------------------
sub _playbackCallback {
    my $request = shift;
    my $client  = $request->client() || return;
    my $id      = $client->id()      || return;

    $playbackRevision{$id}++;

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
    delete $offPending{$id};

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

    $offPending{$id} = $client;
}

# ---------------------------------------------------------------------------
#  Timer fires — actually turn the screen off
# ---------------------------------------------------------------------------
sub _turnScreenOff {
    my $client = shift;          # timer key is the client object
    return unless $client && ref $client;

    my $id = $client->id();

    delete $offPending{$id};

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
            # A loopback address means the stored address is the server, not a
            # device - one cause, one cure, so say so rather than leaving a
            # bare timeout in the log.
            hint    => ( $ip =~ /^(?:127\.|::1$)/ )
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
