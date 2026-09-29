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
use Slim::Utils::Strings ();
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

use constant PLUGIN_VERSION => '2.3.0';

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

# ---------------------------------------------------------------------------
#  Per-player defaults.
#
#  NOT $prefs->setPlayerDefault: there is no such method in LMS.  Prefs::Base's
#  AUTOLOAD turns an unknown call into a pref accessor, so that spelling stored
#  a namespace pref literally called "setPlayerDefault" (the value being the
#  LAST pref NAME passed) and applied no default to any player at all.  Measured
#  on the live server, and it is in the release too, which is why initPlugin
#  removes the junk pref.
#
#  A client pref can only be initialised against a client, so these are applied
#  per player: to the players already attached, and to each one that arrives
#  (LMS's own Client::new sends `client new`).
#
#  Every reader keeps its own fallback as well, and must: allClients hands back
#  the stored prefs of players that are NOT attached, and those never pass
#  through here.
# ---------------------------------------------------------------------------
my %CLIENT_DEFAULTS = (

    enabled          => 0,

    # The address of the Eversolo this player drives.  This is the ONLY thing
    # that says which device a player talks to.  The settings page fills it in
    # from the network scan, or the user types it in; either way what is stored
    # is an address, and nothing else has to be consulted to use it.
    eversolo_ip      => '',

    # Drive the Eversolo's power from the LMS player's power button.  OFF by
    # default and deliberately so: a mis-fire costs a full cold boot, so this is
    # something you turn on for the one player that feeds the device.
    power_control    => 0,

    # The device's wired MAC, learned from getModel by the settings page.
    # Powering ON cannot be an HTTP call - the device is off and nothing is
    # listening - so the only way up is a Wake-on-LAN packet addressed to this.
    eversolo_mac     => '',
    eversolo_port    => 9529,
    screen_off_delay => 30,

    # Put this player's Eversolo on the power page, and the page on Material's
    # Home screen.  OFF by default: the tile appears only once a user asks for
    # it, and it only does anything for a player that also has power_control on.
    # See the "Power page" section below for why a page exists at all.
    home_power       => 0,
);

# ---------------------------------------------------------------------------
#  Power page state.  NOT per player, and deliberately so: the page exists for
#  the moment a device is off and its player has gone from LMS, so it is keyed
#  by the DEVICE's address, never by a client.
# ---------------------------------------------------------------------------

# The path of the power page (Power.pm).  Owned here and handed to Power->init,
# so the page module needs nothing from this one - see the settings-page trap in
# CLAUDE.md.
use constant POWER_PAGE_PATH => '/eversolopower';

# How long a press is believed over the device's own answer.  A woken DMP-A8
# takes the better part of a minute to answer HTTP, and a powered-off one keeps
# answering for a few seconds while it shuts down; inside these windows the page
# says "switching on/off" rather than contradicting the button just pressed.
use constant WAKE_GRACE => 120;
use constant STOP_GRACE => 60;

# { device ip => { to => 'on'|'off', until => epoch } }
my %powerPending;

# The action handed to Material's registerCustomAction, kept so it can be
# withdrawn later.  Material has no unregister and no de-dupe - it PUSHES - so
# this is registered at most once per server run and afterwards only edited in
# place: Material serialises its registry on every `material-skin
# plugin-actions` request, and loadCustomPinned skips an action with neither
# `iframe` nor `weblink`, so deleting `iframe` takes the tile off offer.
# NOT cleared in shutdownPlugin: a re-init in the same process must reuse it,
# or it would push a second tile.
my $homeTile;

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

    # Register the per-player settings page, and the power page.
    if (main::WEBUI) {
        require Plugins::EversoloScreenControl::PlayerSettings;
        Plugins::EversoloScreenControl::PlayerSettings->new;

        require Plugins::EversoloScreenControl::Power;
        Plugins::EversoloScreenControl::Power->init(POWER_PAGE_PATH);
    }

    # What the power page polls and presses.  Server-level (no player): the
    # player is exactly what is missing when a device needs waking.
    Slim::Control::Request::addDispatch(
        [ 'eversolopower', 'status' ], [ 0, 1, 1, \&_powerStatusQuery ] );
    Slim::Control::Request::addDispatch(
        [ 'eversolopower', 'set' ],    [ 0, 0, 1, \&_powerSetCommand ] );

    # Offer or withdraw the Home tile the moment a player's settings change it.
    # Fires for client prefs too: Base::set reads the callbacks off the
    # namespace root.
    $prefs->setChange( \&_syncHomeTile, qw(home_power power_control enabled) );

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

    # Per-player defaults, for the players already attached and for every one
    # that arrives later.  The remove clears the junk namespace pref the old
    # setPlayerDefault spelling wrote on every start - see %CLIENT_DEFAULTS.
    $prefs->remove('setPlayerDefault') if $prefs->exists('setPlayerDefault');
    _initClientPrefs($_) for Slim::Player::Client::clients();
    Slim::Control::Request::subscribe( \&_onClientNew, [['client'], ['new']] );

    # A player REMOVED from LMS takes its power page entry with it - see _onForget.
    Slim::Control::Request::subscribe( \&_onForget, [['client'], ['forget']] );

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
    %powerPending      = ();

    Slim::Control::Request::unsubscribe(\&_playbackCallback);
    Slim::Control::Request::unsubscribe(\&_powerCallback);
    Slim::Control::Request::unsubscribe(\&_onForget);
    Slim::Control::Request::unsubscribe(\&_onClientNew);
}

# After every plugin's initPlugin, so Material's registry exists to be called.
sub postinitPlugin {
    _syncHomeTile();
    return;
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

    _sendWake( $mac, _resolveIP($client), $name, 'player powered on' );

    return;
}

# The packet itself, apart from any player: the power page wakes a device whose
# player is not in LMS at all.  $ip only picks the directed broadcast; the MAC is
# what the device answers to.  Returns 1 once the packet has gone out.
sub _sendWake {
    my ( $mac, $ip, $name, $why ) = @_;

    $mac = Plugins::EversoloScreenControl::Discovery::normaliseMac($mac) or return 0;

    my $packet = magicPacket($mac);

    my $sock = IO::Socket::INET->new( Proto => 'udp', Blocking => 0 );

    if ( !$sock ) {
        $log->warn("Eversolo [$name]: could not open a socket to wake the device - $!");
        return 0;
    }

    if ( !setsockopt( $sock, Socket::SOL_SOCKET(), Socket::SO_BROADCAST(), 1 ) ) {
        # Not fatal on its own - say so, and let the sends below be the verdict.
        $log->warn("Eversolo [$name]: could not set SO_BROADCAST - $!");
    }

    my @targets = ('255.255.255.255');

    # The device's own subnet, which is the one that actually has to carry it.
    $ip = '' unless defined $ip;
    if ( $ip =~ /^(\d+\.\d+\.\d+)\.\d+$/ ) {
        unshift @targets, "$1.255";
    }

    # COUNT WHAT ACTUALLY LEFT.  Nothing answers a magic packet, so a send that
    # failed is invisible - and returning 1 for it told the caller to believe a
    # press for the whole 120s WAKE_GRACE while the device was never signalled.
    # Any one of the four getting out is a wake; none of them is a failure.
    my $sent = 0;

    for my $target (@targets) {
        my $addr = Socket::inet_aton($target) or next;

        for my $port ( 9, 7 ) {
            if ( defined send( $sock, $packet, 0,
                               Socket::pack_sockaddr_in( $port, $addr ) ) ) {
                $sent++;
            }
            else {
                $log->warn(
                    "Eversolo [$name]: Wake-on-LAN to $target:$port failed - $!");
            }
        }
    }

    close $sock;

    if ( !$sent ) {
        $log->warn(
            "Eversolo [$name]: $why - NO Wake-on-LAN packet could be sent to $mac");
        return 0;
    }

    $log->info("Eversolo [$name]: $why — sent Wake-on-LAN to $mac");

    return 1;
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
#  The power page: a power button for a device whose player has gone.
#
#  Once an Eversolo is off its LMS player disappears, so the player's own power
#  button - the only route to _wakeDevice above - is gone exactly when it is
#  needed.  The page (Power.pm) is reachable without any player: from a Material
#  Home tile, or by its path.  It lists the devices of every player that has
#  home_power on, and says for each whether it is answering.
#
#  WHERE THE DEVICES COME FROM.  $prefs->allClients, which returns the stored
#  prefs of EVERY player the namespace has seen, connected or not - a player
#  that has left LMS keeps its prefs.  Those objects are read-only (LMS does not
#  migrate them), and nothing here writes to one.
#
#  A device is its ADDRESS, as everywhere else in this plugin, so two players
#  pointing at one Eversolo list it once.  Nothing the page sends is trusted as
#  an address: a press names a device, and the address, port and MAC are read
#  back from the prefs.
#
#  A player qualifies with enabled + power_control + home_power, the same gate
#  as the player's own power button plus the opt-in for the page.
# ---------------------------------------------------------------------------
sub _homePowerOn {
    my $cp = shift;

    return $cp->get('enabled') && $cp->get('power_control') && $cp->get('home_power');
}

sub _powerDevices {
    my %byIP;

    # BY CLIENT ID, not in allClients order: allClients walks the KEYS of the
    # prefs hash, and Perl randomises that per process.  Every field below is
    # filled by the first player that has one, so without a fixed order two
    # players on one device would hand the page a different port - or a
    # different name, or a different MAC - on different restarts.
    for my $cp ( sort { ($a->{'clientid'} || '') cmp ($b->{'clientid'} || '') }
                 $prefs->allClients ) {
        next unless _homePowerOn($cp);

        my $ip = $cp->get('eversolo_ip');
        $ip = '' unless defined $ip;
        $ip =~ s/^\s+|\s+$//g;
        next if $ip eq '';

        my $d = $byIP{$ip} ||= {
            id   => $ip,
            ip   => $ip,
            port => $cp->get('eversolo_port') || 9529,
            mac  => '',
            name => '',
        };

        # Two players on one device: either may be the one that learned the
        # MAC or the name, so take whichever has it.
        $d->{mac}  ||= Plugins::EversoloScreenControl::Discovery::normaliseMac( $cp->get('eversolo_mac') );
        $d->{name} ||= $cp->get('eversolo_name') || '';
    }

    $_->{name} ||= $_->{ip} for values %byIP;

    return sort { lc $a->{name} cmp lc $b->{name} || $a->{ip} cmp $b->{ip} } values %byIP;
}

# A player removed from LMS ("forget player") must not leave its device on the
# power page, and LMS will not do it for us: forgetClient drops the CONNECTION
# and leaves every client pref where it was (read from LMS 9.0's source, and
# recorded in HQPlayer Bridge's ledger).  allClients would go on listing it, and
# with the player gone there is no settings page left to untick it from.  So the
# opt-in goes with the player.
#
# Only home_power is cleared.  The rest stays as LMS keeps it, so a player that
# comes back later has its address and power settings, and the page is one tick
# away.  Setting it fires the setChange callback, which withdraws the Home tile
# if this was the last player asking for it.
#
# THE ID, NOT ->client: the notification is delivered AFTER forgetClient has
# removed the player, and Request::client is a getClient() lookup - always
# undef here.  A forget LMS REFUSES (a connected player) notifies nothing.
# A player LMS has just attached gets the defaults, because there was no client
# to hold them when this module loaded.  Cheap and idempotent: Base::init only
# writes a pref that is missing or undef, and writes it straight into the hash,
# so nothing here fires a setChange callback.
sub _onClientNew {
    my $request = shift;

    _initClientPrefs( $request->client );

    return;
}

sub _initClientPrefs {
    my $client = shift or return;

    $prefs->client($client)->init( \%CLIENT_DEFAULTS );

    return;
}

sub _onForget {
    my $request = shift;

    my $id = $request->clientid or return;

    # THE IN-MEMORY STATE GOES FIRST, and for every forgotten player, whatever
    # its settings were.  Nothing else will ever clear it: `forgetClient` calls
    # `Timers::forgetTimer`, which kills the watcher with EV_KILL - and the
    # wrapper in Timers.pm returns on EV_KILL BEFORE calling the sub, so
    # `_turnScreenOff` never runs and the `delete $offPending{$id}` inside it
    # never happens.
    #
    # %offPending is the one that bites.  Reconcile skips a not-playing player
    # whose off-timer it believes is pending, so a player of this id that comes
    # back would never have its screen turned off again - the exact hole the
    # reconcile pass exists to close.  It also retains the discarded client.
    delete $offPending{$id};
    delete $screenState{$id};
    delete $lastElapsed{$id};
    delete $playbackRevision{$id};

    # Keyed by id plus a suffix, so match on the id rather than one spelling.
    delete $warnedPlaceholder{$_}
        for grep { /^\Q$id\E\// } keys %warnedPlaceholder;

    return unless Slim::Utils::Prefs::Client->hasPrefs( $prefs, $id );

    my $cp = Slim::Utils::Prefs::Client->new( $prefs, $id );
    return unless $cp->get('home_power');

    $log->info("Eversolo: player $id was removed from LMS - taking its device off the power page");

    $cp->set( 'home_power', 0 );

    return;
}

# Offer the Home tile while any player asks for it, withdraw it when none does.
# Runs at postinit and on every change to a pref that decides it.
sub _syncHomeTile {
    return unless main::WEBUI;

    my $wanted = grep { _homePowerOn($_) } $prefs->allClients;

    if ( !$wanted ) {
        if ( $homeTile && delete $homeTile->{iframe} ) {
            main::INFOLOG && $log->is_info && $log->info(
                'Home power tile withdrawn - no player has it switched on' );
        }
        return;
    }

    if ( !$homeTile ) {
        # Through ->can, as HQPlayer Bridge does: a compiled call would bind at
        # OUR compile time, and ->can on a package that was never loaded
        # answers undef instead of dying.  No Material, no tile, no error - the
        # page itself is still there at its path.
        my $register = eval { Plugins::MaterialSkin::Plugin->can('registerCustomAction') };

        if ( !$register ) {
            main::INFOLOG && $log->is_info && $log->info(
                'no Material registerCustomAction - no Home tile (the power page is still at '
              . POWER_PAGE_PATH . ')' );
            return;
        }

        my $tile = {
            title => Slim::Utils::Strings::string('PLUGIN_EVERSOLO_POWER_PAGE'),
            icon  => 'power_settings_new',
        };

        # `iframe`, not `weblink`: a pinned tile opens an iframe as a Material
        # dialog, and a weblink always tears off a separate browser window.
        if ( !eval { $register->( 'pinned', $tile ); 1 } ) {
            $log->warn("could not register the Material Home tile: $@");
            return;
        }

        $homeTile = $tile;
    }

    if ( !$homeTile->{iframe} ) {
        $homeTile->{iframe} = POWER_PAGE_PATH;
        main::INFOLOG && $log->is_info && $log->info(
            'Home power tile offered - it appears once Material is reloaded' );
    }

    return;
}

# What the page shows for a device: its own answer, unless a press is still
# inside its grace window and the answer does not agree with it yet.
sub _powerState {
    my ( $ip, $up ) = @_;

    my $p = $powerPending{$ip};

    if ( $p && ( time() > $p->{until} || ( $p->{to} eq 'on' ? $up : !$up ) ) ) {
        delete $powerPending{$ip};
        $p = undef;
    }

    return $p ? ( $p->{to} eq 'on' ? 'waking' : 'stopping' )
              : ( $up ? 'on' : 'off' );
}

# eversolopower status
#   -> count, devices_loop: [{ id, name, state (on|off|waking|stopping), canwake }]
#
# Asks every listed device getModel, in parallel.  "Answers" is ON; anything
# else is OFF, because an Eversolo that is off has nothing listening at all.
#
# ASYNC, AND THE ORDER MATTERS.  Slim::Control::Request::setStatusDone calls
# executeDone itself when the status is "processing", and execute() calls it
# again after the function returns unless the status is STILL processing.  So a
# probe that answers synchronously (identify does for an empty address, which
# _powerDevices never lists - but a stubbed or future probe may) must not
# complete a request already put into processing: the callback would fire twice.  Processing is therefore declared only AFTER
# the loop, and only if something is still outstanding.
sub _powerStatusQuery {
    my $request = shift;

    my @devices = _powerDevices();
    my $left    = scalar @devices;
    my $inline  = 1;
    my $idx     = 0;

    $request->addResult( 'count', scalar @devices );

    for my $d (@devices) {
        my $i = $idx++;

        Plugins::EversoloScreenControl::Discovery::identify( $d->{ip}, $d->{port}, sub {
            my $up = shift ? 1 : 0;

            $request->addResultLoop( 'devices_loop', $i, 'id',      $d->{id} );
            $request->addResultLoop( 'devices_loop', $i, 'name',    $d->{name} );
            $request->addResultLoop( 'devices_loop', $i, 'state',   _powerState( $d->{ip}, $up ) );
            $request->addResultLoop( 'devices_loop', $i, 'canwake', $d->{mac} ? 1 : 0 );

            $request->setStatusDone() if !--$left && !$inline;
        } );
    }

    $inline = 0;

    $left ? $request->setStatusProcessing() : $request->setStatusDone();

    return;
}

# eversolopower set id:<device> to:on|off
sub _powerSetCommand {
    my $request = shift;

    my $id = $request->getParam('id');
    my $to = $request->getParam('to');

    $id = '' unless defined $id;
    $to = '' unless defined $to;

    my ($d) = grep { $_->{id} eq $id } _powerDevices();

    if ( !$d || ( $to ne 'on' && $to ne 'off' ) ) {
        $request->setStatusBadParams();
        return;
    }

    if ( $to eq 'on' ) {
        if ( !_sendWake( $d->{mac}, $d->{ip}, $d->{name}, 'power page pressed' ) ) {
            $log->warn("Eversolo [$d->{name}]: cannot wake the device - its hardware address is not known yet");
            $request->setStatusBadParams();
            return;
        }
    }
    else {
        $log->info("Eversolo [$d->{name}]: power page pressed — powering the device down");

        # As a player's own power-off does: a pending screen-off is moot for
        # every connected player that drives this device.
        for my $client ( Slim::Player::Client::clients() ) {
            next unless $client;

            my $cip = $prefs->client($client)->get('eversolo_ip');
            $cip = '' unless defined $cip;
            $cip =~ s/^\s+|\s+$//g;
            next unless $cip eq $d->{ip};

            Slim::Utils::Timers::killTimers( $client, \&_turnScreenOff );
            delete $offPending{ $client->id() };
            delete $screenState{ $client->id() };
        }

        Plugins::EversoloScreenControl::Discovery::setPowerOption(
            $d->{ip}, $d->{port}, 'poweroff' );
    }

    $powerPending{ $d->{ip} } = {
        to    => $to,
        until => time() + ( $to eq 'on' ? WAKE_GRACE : STOP_GRACE ),
    };

    $request->addResult( 'state', $to eq 'on' ? 'waking' : 'stopping' );
    $request->setStatusDone();

    return;
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
