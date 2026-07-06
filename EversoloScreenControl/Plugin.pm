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

use constant PLUGIN_VERSION => '1.0.3';

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
    %screenState = ();

    Slim::Control::Request::unsubscribe(\&_playbackCallback);
}

# ---------------------------------------------------------------------------
#  Resolve the Eversolo IP for a given player.
#  If auto_detect_ip is on, use the player's live IP (from $client->ip()).
#  Otherwise fall back to the manually stored IP.
# ---------------------------------------------------------------------------
sub _resolveIP {
    my $client = shift;

    if ($prefs->client($client)->get('auto_detect_ip')) {
        my $ip = $client->ip() || '';
        $ip =~ s/:.*$//;   # strip port if present
        return $ip;
    }

    return $prefs->client($client)->get('eversolo_ip') || '';
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
    $log->error("Eversolo [$player]: Failed '$command' — $error");
}

1;

__END__
