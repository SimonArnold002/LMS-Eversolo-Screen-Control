#!/usr/bin/env perl
#
# t_plugin.pl - exercise the stateful Plugin.pm paths without a running LMS.
#
#   perl tools/t_plugin.pl
#
use strict;
use warnings;
use File::Spec;

my $ROOT = File::Spec->rel2abs(
    File::Spec->catdir((File::Spec->splitpath($0))[1], File::Spec->updir)
);
my $PLUGIN = $ENV{ESC_PLUGIN}
    || File::Spec->catfile($ROOT, 'EversoloScreenControl', 'Plugin.pm');

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $what) = @_;
    $cond ? ($pass++, print "  PASS  $what\n") : ($fail++, print "  FAIL  $what\n");
    return $cond ? 1 : 0;
}
sub is {
    my ($got, $want, $what) = @_;
    $got  = defined $got  ? $got  : '(undef)';
    $want = defined $want ? $want : '(undef)';
    ok($got eq $want, $what . ($got eq $want ? '' : "  [got '$got', want '$want']"));
}

# WEBUI on: the Home tile is only offered with a web UI.  Nothing here calls
# initPlugin, which is the other thing WEBUI gates.
sub WEBUI   () { 1 }
sub INFOLOG () { 0 }
sub DEBUGLOG() { 0 }

our (%PREFS, %DEFAULTS, %ONCHANGE, @CLIENTS, @TIMERS, @HTTP_GET, @STATE_CALLBACKS, @POWER_OFF,
     @REGISTERED, @IDENTIFY, $IDENTIFY_INLINE, @WAKES);

{
    package Stub::ClientPrefs;
    sub new { bless { ns => $_[1], clientid => $_[2] }, $_[0] }
    sub get {
        my ($self, $key) = @_;
        return $main::PREFS{$self->{ns}}{$self->{clientid}}{$key}
            if exists $main::PREFS{$self->{ns}}{$self->{clientid}}{$key};
        return $main::DEFAULTS{$self->{ns}}{$key};
    }
    # As LMS's Base::init: writes a pref only when it is missing or undef, and
    # writes it STRAIGHT into the hash - no validation, and no change callback.
    sub init {
        my ($self, $hash) = @_;
        my $store = $main::PREFS{$self->{ns}}{$self->{clientid}} ||= {};
        for my $key (keys %$hash) {
            next if defined $store->{$key};
            $store->{$key} = $hash->{$key};
        }
        return;
    }
    # As LMS's Base::set: store, then run the namespace's change callbacks for
    # that pref, handing over the LIVE client or undef when it is not connected.
    sub set {
        my ($self, $key, $value) = @_;
        $main::PREFS{$self->{ns}}{$self->{clientid}}{$key} = $value;
        my $client = Slim::Player::Client::getClient($self->{clientid});
        $_->($key, $value, $client) for @{ $main::ONCHANGE{$self->{ns}}{$key} || [] };
        return ($value, 1);
    }

    package Stub::PrefsRoot;
    sub new { bless { ns => $_[1] }, $_[0] }
    sub client { Stub::ClientPrefs->new($_[0]->{ns}, $_[1]->id) }
    # DELIBERATELY NO setPlayerDefault.  There is no such method in LMS: Base's
    # AUTOLOAD would turn the call into a pref accessor and store a namespace
    # pref of that name.  This stub used to provide one, and that is exactly why
    # the suite passed while no player ever got a default.  Plugin.pm now uses
    # client->init, and this stub must never grow the fake method back.
    sub exists { exists $main::PREFS{$_[0]->{ns}}{$_[1]} ? 1 : 0 }
    sub remove { delete $main::PREFS{$_[0]->{ns}}{$_} for @_[1 .. $#_]; return }
    sub setChange {
        my ($self, $cb, @names) = @_;
        push @{ $main::ONCHANGE{$self->{ns}}{$_} }, $cb for @names;
    }
    # As LMS's: EVERY player with stored prefs, connected or not.  Unlike LMS
    # it applies the player defaults, which only makes the stub stricter (a
    # default of 0 reads back as 0, not undef).
    sub allClients {
        my $ns = $_[0]->{ns};
        return map { Stub::ClientPrefs->new($ns, $_) }
               reverse sort keys %{ $main::PREFS{$ns} || {} };
    }

    # LMS's own constructor for a player that may no longer exist: takes a
    # plain id, and hasPrefs says whether the namespace holds any for it.
    package Slim::Utils::Prefs::Client;
    sub hasPrefs { exists $main::PREFS{ $_[1]->{ns} }{ $_[2] } ? 1 : 0 }
    sub new      { Stub::ClientPrefs->new( $_[1]->{ns}, $_[2] ) }

    package Slim::Utils::Prefs;
    sub import {
        no strict 'refs';
        *{ caller() . '::preferences' } = \&preferences;
    }
    sub preferences { Stub::PrefsRoot->new($_[0]) }
}

{
    package Slim::Utils::Log;
    sub import { }
    sub addLogCategory { bless {}, 'Stub::Log' }
    package Stub::Log;
    our $AUTOLOAD;
    sub AUTOLOAD { 1 }
    sub DESTROY { }
}

{
    package Slim::Plugin::Base;
    sub initPlugin { }
}

{
    package Slim::Utils::Timers;
    sub import { }
    sub setTimer {
        my ($obj, $when, $cb) = @_;
        push @main::TIMERS, { obj => $obj, when => $when, cb => $cb };
    }
    sub killTimers {
        my ($obj, $cb) = @_;
        @main::TIMERS = grep {
            my $same_obj = !defined($_->{obj}) && !defined($obj)
                || defined($_->{obj}) && defined($obj) && $_->{obj} == $obj;
            !($same_obj && $_->{cb} == $cb);
        } @main::TIMERS;
    }
}

{
    package Slim::Networking::SimpleAsyncHTTP;
    sub import { }
    sub new {
        my ($class, $ok, $error, $params) = @_;
        bless { ok => $ok, error => $error, params => $params }, $class;
    }
    sub get { push @main::HTTP_GET, $_[1] }
    sub params { $_[0]->{params}{$_[1]} }
}

{
    package Stub::Client;
    sub new {
        my ($class, $id, %args) = @_;
        bless { id => $id, name => $args{name} || $id, mode => $args{mode} || 'stop',
                power => $args{power} || 0, buddies => [] }, $class;
    }
    sub id       { $_[0]->{id} }
    sub name     { $_[0]->{name} }
    sub power    { $_[0]->{power} }
    sub isSynced { scalar @{$_[0]->{buddies}} ? 1 : 0 }
    sub syncedWith { @{$_[0]->{buddies}} }

    package Slim::Player::Client;
    sub import { }
    sub clients { @main::CLIENTS }
    sub getClient {
        my $id = shift;
        return (grep { $_->id eq $id } @main::CLIENTS)[0];
    }

    package Slim::Player::Source;
    sub import { }
    sub playmode { $_[0]->{mode} }
    sub songTime { $_[0]->{elapsed} || 0 }
}

{
    package Slim::Control::Request;
    sub subscribe { }
    sub unsubscribe { }
    sub addDispatch { }

    package Stub::Request;
    sub new { bless { client => $_[1], value => $_[2] }, $_[0] }
    sub client { $_[0]->{client} }
    sub getParam { $_[1] eq '_newvalue' ? $_[0]->{value} : undef }
    sub isCommand { 0 }
    sub getRequestString { '' }

    # The `client forget` notification as LMS delivers it: AFTER forgetClient,
    # so the id is on the request and ->client (a getClient lookup) is undef.
    package Stub::ForgetRequest;
    sub new      { bless { id => $_[1] }, $_[0] }
    sub clientid { $_[0]->{id} }
    sub client   { undef }

    # A CLI request with LMS's completion semantics, which are the whole point
    # of the async tests: setStatusDone calls executeDone itself when the status
    # is "processing" (3), and execute() calls it again after the function
    # returns unless the status is STILL processing.  `done` counts executeDone.
    package Stub::Query;
    sub new { my ($c, %p) = @_; bless { params => {%p}, status => 1, done => 0, result => {} }, $c }
    sub getParam            { $_[0]->{params}{$_[1]} }
    sub addResult           { $_[0]->{result}{$_[1]} = $_[2] }
    sub addResultLoop       { $_[0]->{result}{$_[1]}[$_[2]]{$_[3]} = $_[4] }
    sub setStatusProcessing { $_[0]->{status} = 3 }
    sub setStatusBadParams  { $_[0]->{status} = 102 }
    sub setStatusDone {
        my $was = $_[0]->{status};
        $_[0]->{status} = 10;
        $_[0]->{done}++ if $was == 3;
    }
    sub execute {
        my ($self, $func) = @_;
        $func->($self);
        $self->{done}++ unless $self->{status} == 3;
        return $self;
    }
}

{
    package Plugins::EversoloScreenControl::Discovery;
    sub deviceState { push @main::STATE_CALLBACKS, $_[2] }
    sub setPowerOption { push @main::POWER_OFF, [$_[0], $_[1], $_[2]] }
    # MIRRORS Discovery::normaliseMac, and must.  It was a passthrough, which
    # is worse than useless here: the real one returns '' for anything that is
    # not exactly 12 hex characters, and that empty string is what makes
    # canwake 0 and refuses a wake.  A passthrough let a malformed MAC read as
    # wakeable, so no assertion in this file could ever catch one.
    # t_power.pl tests the REAL sub; this only has to agree with it.
    sub normaliseMac {
        my $mac = shift;
        return '' unless defined $mac;
        $mac = lc $mac;
        $mac =~ s/[^0-9a-f]//g;
        return length($mac) == 12 ? $mac : '';
    }
    # getModel: pending unless $IDENTIFY_INLINE, which answers "up" at once.
    sub identify {
        my ($ip, $port, $cb) = @_;
        return $cb->({ ip => $ip }) if $main::IDENTIFY_INLINE;
        push @main::IDENTIFY, [ $ip, $cb ];
    }
}

{
    package Slim::Utils::Strings;
    sub string { $_[0] }

    package Plugins::MaterialSkin::Plugin;
    sub registerCustomAction { push @main::REGISTERED, [ @_ ] }
}

$INC{$_} = 1 for qw(
    Slim/Plugin/Base.pm Slim/Utils/Log.pm Slim/Utils/Prefs.pm
    Slim/Utils/Timers.pm Slim/Networking/SimpleAsyncHTTP.pm
    Slim/Player/Client.pm Slim/Player/Source.pm Slim/Utils/Strings.pm
    Plugins/EversoloScreenControl/Discovery.pm
);

require $PLUGIN;
my $P = 'Plugins::EversoloScreenControl::Plugin';

sub set_plugin_prefs {
    my ($client, %prefs) = @_;
    $PREFS{'plugin.eversoloscreencontrol'}{$client->id} = { %prefs };
}

print "\n-- stale device-state answers --\n";
{
    my $client = Stub::Client->new('player-state', mode => 'play');
    @CLIENTS = ($client);
    set_plugin_prefs($client, enabled => 1, eversolo_ip => '192.168.1.197',
        eversolo_port => 9529, screen_off_delay => 30);
    @STATE_CALLBACKS = ();
    @HTTP_GET = ();

    $P->can('_askDevice')->($client);
    is(scalar @STATE_CALLBACKS, 1, 'the device-state request is pending');

    # A later playback notification makes the answer stale even if LMS has
    # already returned to play by the time the HTTP callback runs.
    $P->can('_playbackCallback')->(Stub::Request->new($client, undef));
    @HTTP_GET = ();
    $STATE_CALLBACKS[0]->('pause');
    is(scalar @HTTP_GET, 0, 'a pre-notification pause answer cannot turn the screen off');
}

print "\n-- reconcile-created timer cleanup --\n";
{
    my $client = Stub::Client->new('player-timer', mode => 'stop');
    @CLIENTS = ($client);
    set_plugin_prefs($client, enabled => 1, eversolo_ip => '192.168.1.197',
        eversolo_port => 9529, screen_off_delay => 30);
    @TIMERS = ();

    $P->can('_onPauseOrStop')->($client);
    is(scalar @TIMERS, 1, 'an off timer exists while screen state is unknown');
    $P->can('shutdownPlugin')->();
    is(scalar @TIMERS, 0, 'shutdown cancels that pending off timer');
}

print "\n-- native LMS syncPower targets --\n";
{
    my $master = Stub::Client->new('master', mode => 'stop');
    my $synced = Stub::Client->new('synced', mode => 'stop');
    my $independent = Stub::Client->new('independent', mode => 'stop');
    $master->{buddies} = [$synced, $independent];
    @CLIENTS = ($master, $synced, $independent);

    set_plugin_prefs($master, enabled => 0, power_control => 0);
    set_plugin_prefs($synced, enabled => 1, power_control => 1,
        eversolo_ip => '192.168.1.20', eversolo_port => 9529);
    set_plugin_prefs($independent, enabled => 1, power_control => 1,
        eversolo_ip => '192.168.1.30', eversolo_port => 9529);
    $PREFS{server}{$synced->id}{syncPower} = 1;
    $PREFS{server}{$independent->id}{syncPower} = 0;
    @POWER_OFF = ();

    $P->can('_powerCallback')->(Stub::Request->new($master, 0));
    is(scalar @POWER_OFF, 1, 'only the syncPower buddy with plugin control is acted on');
    is($POWER_OFF[0][0], '192.168.1.20', 'the synced buddy powers down its own Eversolo');
}

# ---------------------------------------------------------------------------
#  The power page and its Home tile.
# ---------------------------------------------------------------------------
my $OPTED = { enabled => 1, power_control => 1, home_power => 1 };

print "\n-- the Home tile follows the opt-in --\n";
{
    %PREFS = ();
    @CLIENTS = ();
    @REGISTERED = ();
    my $sync = $P->can('_syncHomeTile');

    # An address is part of qualifying now, so the fixture carries one: this
    # block is about the opt-in, not about the address gate below.
    $PREFS{'plugin.eversoloscreencontrol'}{'p1'} =
        { enabled => 1, power_control => 1, home_power => 0,
          eversolo_ip => '192.168.1.197' };
    $sync->();
    is(scalar @REGISTERED, 0, 'nobody opted in: no tile is registered');

    $PREFS{'plugin.eversoloscreencontrol'}{'p1'}{home_power} = 1;
    $sync->();
    is(scalar @REGISTERED, 1, 'opting in registers exactly one tile');
    my ($section, $tile) = @{ $REGISTERED[0] || [] };
    is($section, 'pinned', 'in the section Material turns into Home tiles');
    is($tile && $tile->{iframe}, '/eversolopower', 'opening the power page inline');

    $sync->();
    is(scalar @REGISTERED, 1, 'syncing again does not push a second tile - Material cannot de-dupe');

    $PREFS{'plugin.eversoloscreencontrol'}{'p1'}{home_power} = 0;
    $sync->();
    ok($tile && !exists $tile->{iframe}, 'opting out withdraws the tile: no iframe, so loadCustomPinned skips it');
    is(scalar @REGISTERED, 1, 'without registering anything new');

    $PREFS{'plugin.eversoloscreencontrol'}{'p1'}{home_power} = 1;
    $sync->();
    is($tile && $tile->{iframe}, '/eversolopower', 'opting back in restores the SAME tile');
    is(scalar @REGISTERED, 1, 'still one registration');

    $PREFS{'plugin.eversoloscreencontrol'}{'p1'}{power_control} = 0;
    $sync->();
    ok($tile && !exists $tile->{iframe}, 'home_power without power_control does not offer the tile');
}

print "\n-- which devices the page lists --\n";
{
    %PREFS = ();
    @CLIENTS = ();     # every player is DISCONNECTED - the case the page is for

    my $ns = 'plugin.eversoloscreencontrol';
    $PREFS{$ns}{a} = { %$OPTED, eversolo_ip => ' 192.168.1.197 ', eversolo_mac => '800a805e2b7b' };
    $PREFS{$ns}{b} = { %$OPTED, eversolo_ip => '192.168.1.197', eversolo_name => 'DMP-A8 (ManCave)' };
    $PREFS{$ns}{c} = { %$OPTED, eversolo_ip => '' };
    $PREFS{$ns}{d} = { enabled => 1, power_control => 1, home_power => 0, eversolo_ip => '192.168.1.50' };
    $PREFS{$ns}{e} = { %$OPTED, eversolo_ip => '192.168.1.60' };

    my @d = $P->can('_powerDevices')->();
    is(scalar @d, 2, 'disconnected players are listed; no address and not opted in are not');
    my ($mancave) = grep { $_->{ip} eq '192.168.1.197' } @d;
    ok($mancave, 'two players on one device list it once, by address');
    is($mancave && $mancave->{mac},  '800a805e2b7b',     'the MAC one player learned is kept');
    is($mancave && $mancave->{name}, 'DMP-A8 (ManCave)', 'and the name the other learned');
    my ($bare) = grep { $_->{ip} eq '192.168.1.60' } @d;
    is($bare && $bare->{name}, '192.168.1.60', 'a device never identified is named by its address');
}

print "\n-- eversolopower status: async completion --\n";
{
    %PREFS = ();
    @CLIENTS = ();
    my $ns = 'plugin.eversoloscreencontrol';
    $PREFS{$ns}{a} = { %$OPTED, eversolo_ip => '192.168.1.197', eversolo_mac => '800a805e2b7b' };
    $PREFS{$ns}{b} = { %$OPTED, eversolo_ip => '192.168.1.60' };

    my $status = $P->can('_powerStatusQuery');

    @IDENTIFY = ();
    $IDENTIFY_INLINE = 0;
    my $q = Stub::Query->new->execute($status);
    is(scalar @IDENTIFY, 2, 'every listed device is asked, in parallel');
    is($q->{status}, 3, 'the request waits for them');
    is($q->{done}, 0, 'and has not completed');

    my %cb = map { $_->[0] => $_->[1] } @IDENTIFY;
    $cb{'192.168.1.197'}->({ ip => '192.168.1.197' });
    is($q->{done}, 0, 'one answer is not enough');
    $cb{'192.168.1.60'}->(undef);
    is($q->{done}, 1, 'the last answer completes it exactly once');

    my %row = map { $_->{id} => $_ } @{ $q->{result}{devices_loop} || [] };
    is($row{'192.168.1.197'}{state},   'on',  'a device that answers is on');
    is($row{'192.168.1.60'}{state},    'off', 'a device that does not is off');
    is($row{'192.168.1.197'}{canwake}, 1,     'a known MAC can be woken');
    is($row{'192.168.1.60'}{canwake},  0,     'an unknown one cannot');

    # The trap: answers that arrive INSIDE the function.  Declaring processing
    # before the loop would make LMS run executeDone twice.
    $IDENTIFY_INLINE = 1;
    $q = Stub::Query->new->execute($status);
    is($q->{done}, 1, 'answers arriving synchronously still complete it exactly once');
    $IDENTIFY_INLINE = 0;

    %PREFS = ();
    $q = Stub::Query->new->execute($status);
    is($q->{result}{count}, 0, 'no opted-in device: an empty answer');
    is($q->{done}, 1, 'completed at once');
}

print "\n-- eversolopower set --\n";
{
    no warnings 'redefine';
    local *Plugins::EversoloScreenControl::Plugin::_sendWake = sub { push @WAKES, [ @_ ]; 1 };

    %PREFS = ();
    my $ns = 'plugin.eversoloscreencontrol';
    my $driver = Stub::Client->new('driver', mode => 'stop');
    @CLIENTS = ($driver);
    $PREFS{$ns}{driver} = { %$OPTED, eversolo_ip => '192.168.1.197', eversolo_mac => '800a805e2b7b',
                            eversolo_port => 9529, screen_off_delay => 30 };
    $PREFS{$ns}{other}  = { enabled => 1, power_control => 1, home_power => 0,
                            eversolo_ip => '192.168.1.50', eversolo_mac => '001122334455' };

    my $set    = $P->can('_powerSetCommand');
    my $status = $P->can('_powerStatusQuery');

    @WAKES = (); @POWER_OFF = ();
    my $q = Stub::Query->new(id => '192.168.1.50', to => 'on')->execute($set);
    is($q->{status}, 102, 'a device not opted in cannot be pressed');
    $q = Stub::Query->new(id => '10.0.0.1', to => 'off')->execute($set);
    is($q->{status}, 102, 'nor can an address no player names');
    $q = Stub::Query->new(id => '192.168.1.197', to => 'toggle')->execute($set);
    is($q->{status}, 102, 'on and off are the only verbs');
    is(scalar(@WAKES) + scalar(@POWER_OFF), 0, 'and none of those sent anything');

    $q = Stub::Query->new(id => '192.168.1.197', to => 'on')->execute($set);
    is(scalar @WAKES, 1, 'on sends one wake');
    is($WAKES[0][0], '800a805e2b7b', 'to the MAC read from the prefs');
    is($WAKES[0][1], '192.168.1.197', 'with the device address for the directed broadcast');
    is($q->{result}{state}, 'waking', 'and answers waking');

    @IDENTIFY = ();
    my $s = Stub::Query->new->execute($status);
    $IDENTIFY[0][1]->(undef);
    is($s->{result}{devices_loop}[0]{state}, 'waking', 'still booting: waking, not off');
    @IDENTIFY = ();
    $s = Stub::Query->new->execute($status);
    $IDENTIFY[0][1]->({});
    is($s->{result}{devices_loop}[0]{state}, 'on', 'once it answers: on');
    @IDENTIFY = ();
    $s = Stub::Query->new->execute($status);
    $IDENTIFY[0][1]->(undef);
    is($s->{result}{devices_loop}[0]{state}, 'off', 'and the press is forgotten once it agreed');

    # Off: the device, and every connected player's pending screen-off for it.
    @TIMERS = ();
    $P->can('_onPauseOrStop')->($driver);
    is(scalar @TIMERS, 1, 'the driving player has a screen-off pending');
    $q = Stub::Query->new(id => '192.168.1.197', to => 'off')->execute($set);
    is(scalar @POWER_OFF, 1, 'off sends one power-off');
    is(join(' ', @{ $POWER_OFF[0] || [] }), '192.168.1.197 9529 poweroff', 'to the stored address and port');
    is(scalar @TIMERS, 0, 'and the pending screen-off is dropped, as a player power-off does');
    is($q->{result}{state}, 'stopping', 'answering stopping');

    @IDENTIFY = ();
    $s = Stub::Query->new->execute($status);
    $IDENTIFY[0][1]->({});
    is($s->{result}{devices_loop}[0]{state}, 'stopping', 'still answering while it shuts down: stopping');
}

# The pref names initPlugin hands to setChange, READ OUT OF THE REAL SOURCE
# rather than copied here - a hand-mirrored list silently stops testing the
# thing it mirrors the moment the real one gains a name.
sub sync_tile_prefs {
    my $src = do { open my $fh, '<', $PLUGIN or die $!; local $/; <$fh> };

    my ($names) = $src =~ /setChange\(\s*\\&_syncHomeTile,\s*qw\(([^)]*)\)/
        or die "could not find the _syncHomeTile setChange list in $PLUGIN\n";

    return split ' ', $names;
}

print "\n-- a player removed from LMS takes its device off the power page --\n";
{
    my $ns = 'plugin.eversoloscreencontrol';
    %PREFS = ();
    %ONCHANGE = ();
    @CLIENTS = ();     # both players are gone from LMS

    my @watched = sync_tile_prefs();
    ok( scalar( grep { $_ eq 'eversolo_ip' } @watched ),
        'the tile follows eversolo_ip, so filling an address in offers it' );

    # The wiring initPlugin makes, so the tile follows through the real carrier.
    Stub::PrefsRoot->new($ns)->setChange( $P->can('_syncHomeTile'), @watched );

    $PREFS{$ns}{gone} = { %$OPTED, eversolo_ip => '192.168.1.197', eversolo_mac => '800a805e2b7b' };
    $PREFS{$ns}{kept} = { %$OPTED, eversolo_ip => '192.168.1.60' };

    $P->can('_syncHomeTile')->();
    my $tile = @REGISTERED ? $REGISTERED[-1][1] : undef;
    is($tile && $tile->{iframe}, '/eversolopower', 'the tile is offered while both are opted in');

    # A FORGET MUST NOT TAKE THE DEVICE OFF THE PAGE.  LMS issues `client forget`
    # by itself 300s after any slimproto player disconnects, and an Eversolo on
    # SqueezeConnect is one - so switching the device off would have withdrawn
    # the tile five minutes later, removing the only way left to wake it.  The
    # opt-in is the user's tick and nothing else clears it.  Do not "restore"
    # the clearing: see _onForget's header for why the removal it was written
    # for never arrives as a forget at all.
    my $forget = $P->can('_onForget');
    $forget->( Stub::ForgetRequest->new('gone') );

    is($PREFS{$ns}{gone}{home_power},   1, 'a forget does NOT clear the opt-in');
    is($PREFS{$ns}{gone}{eversolo_ip}, '192.168.1.197', 'nor the address');
    is($PREFS{$ns}{gone}{power_control}, 1, 'nor power control');

    my @ips = sort map { $_->{ip} } $P->can('_powerDevices')->();
    is("@ips", '192.168.1.197 192.168.1.60',
        'the forgotten player\'s device stays on the power page, where it is needed');

    $forget->( Stub::ForgetRequest->new('kept') );
    ok($tile && $tile->{iframe},
        'and forgetting every player still leaves the tile - only unticking withdraws it');

    # Unticking is the one route that does.
    $PREFS{$ns}{gone}{home_power} = 0;
    $PREFS{$ns}{kept}{home_power} = 0;
    $P->can('_syncHomeTile')->();
    ok($tile && !exists $tile->{iframe}, 'unticking the last player withdraws the tile');

    $forget->( Stub::ForgetRequest->new('never-seen') );
    ok(!exists $PREFS{$ns}{'never-seen'}, 'forgetting a player the plugin never knew writes nothing');
}

print "\n-- the player's own power button gets the same grace window --\n";
{
    my $ns = 'plugin.eversoloscreencontrol';
    %PREFS = (); %ONCHANGE = (); @IDENTIFY = (); @WAKES = (); @POWER_OFF = ();

    my $driver = Stub::Client->new('driver', mode => 'stop');
    @CLIENTS = ($driver);
    $PREFS{$ns}{driver} = { %$OPTED, eversolo_ip => '192.168.1.197',
                            eversolo_mac => '800a805e2b7b', eversolo_port => 9529 };

    my $status = $P->can('_powerStatusQuery');

    # Control: nothing pressed, the device does not answer - the page says off.
    @IDENTIFY = ();
    my $s = Stub::Query->new->execute($status);
    $IDENTIFY[0][1]->(undef);
    is($s->{result}{devices_loop}[0]{state}, 'off', 'an unpressed silent device reads off');

    # The PLAYER's power button, not the page's.
    {
        local *Plugins::EversoloScreenControl::Plugin::_sendWake =
            sub { push @WAKES, [ @_ ]; 1 };
        $P->can('_powerCallback')->( Stub::Request->new($driver, 1) );
    }
    is(scalar @WAKES, 1, 'powering the player on wakes the device');

    @IDENTIFY = ();
    $s = Stub::Query->new->execute($status);
    $IDENTIFY[0][1]->(undef);
    is($s->{result}{devices_loop}[0]{state}, 'waking',
        'and the page says waking while it boots, not off with a live button');

    # And the other direction: it still answers for a few seconds after a
    # power-off, which must not read as "on".
    $P->can('_powerCallback')->( Stub::Request->new($driver, 0) );
    is(scalar @POWER_OFF, 1, 'powering the player off powers the device down');

    @IDENTIFY = ();
    $s = Stub::Query->new->execute($status);
    $IDENTIFY[0][1]->({});
    is($s->{result}{devices_loop}[0]{state}, 'stopping',
        'and the page says stopping while it is still answering');

    # A wake that never left must NOT arm the window.
    %PREFS = (); @WAKES = ();
    $PREFS{$ns}{driver} = { %$OPTED, eversolo_ip => '192.168.1.197',
                            eversolo_mac => '800a805e2b7b', eversolo_port => 9529 };
    {
        local *Plugins::EversoloScreenControl::Plugin::_sendWake =
            sub { push @WAKES, [ @_ ]; 0 };
        $P->can('_powerCallback')->( Stub::Request->new($driver, 1) );
    }
    @IDENTIFY = ();
    $s = Stub::Query->new->execute($status);
    $IDENTIFY[0][1]->(undef);
    is($s->{result}{devices_loop}[0]{state}, 'off',
        'a wake that never left leaves the device reading off, not waking');
}

print "\n-- powering the device down leaves nothing to reconcile --\n";
{
    my $ns = 'plugin.eversoloscreencontrol';
    %PREFS = (); %ONCHANGE = (); @TIMERS = (); @POWER_OFF = (); @HTTP_GET = ();

    # A FRESH ID: %screenState is a lexical inside Plugin.pm, so no suite can
    # reset it between blocks - reusing an id would measure the leftovers.
    my $client = Stub::Client->new('powerdown', mode => 'stop');
    @CLIENTS = ($client);
    set_plugin_prefs($client, enabled => 1, power_control => 1,
        eversolo_ip => '192.168.1.197', eversolo_port => 9529, screen_off_delay => 30);

    my $offtimer = $P->can('_turnScreenOff');

    # CONTROL: a player whose screen state is unknown DOES get reconciled -
    # that is what makes the assertion below mean something.
    $P->can('_reconcile')->();
    is( scalar( grep { $_->{cb} == $offtimer } @TIMERS ), 1,
        'an unknown screen state is reconciled, as it must be' );

    # Now power the device down from the player's own button.
    %PREFS = (); @TIMERS = ();
    set_plugin_prefs($client, enabled => 1, power_control => 1,
        eversolo_ip => '192.168.1.197', eversolo_port => 9529, screen_off_delay => 30);
    $P->can('_powerCallback')->( Stub::Request->new($client, 0) );
    is(scalar @POWER_OFF, 1, 'the device is powered down');

    # The screen is off because the whole DEVICE is.  Recording that as unknown
    # had reconcile schedule an off-timer within 60s and fire a doomed
    # Key.Screen.OFF at a device that was already gone.
    @TIMERS = (); @HTTP_GET = ();
    $P->can('_reconcile')->();
    is( scalar( grep { $_->{cb} == $offtimer } @TIMERS ), 0,
        'and afterwards reconcile schedules no screen-off at a device already off' );
    is( scalar @HTTP_GET, 0, 'and sends it nothing' );
}

print "\n-- a device going off clears EVERY player that drives it --\n";
{
    my $ns = 'plugin.eversoloscreencontrol';
    %PREFS = (); %ONCHANGE = (); @TIMERS = (); @POWER_OFF = (); @HTTP_GET = ();

    # Two players, ONE Eversolo - the case the power page de-duplicates for.
    # Only A has power_control, so only A's button drives the device; B just
    # has the screen control enabled, which is all reconcile needs.
    my $a = Stub::Client->new('twoA', mode => 'stop');
    my $b = Stub::Client->new('twoB', mode => 'stop');
    @CLIENTS = ($a, $b);
    set_plugin_prefs($a, enabled => 1, power_control => 1,
        eversolo_ip => '192.168.1.197', eversolo_port => 9529, screen_off_delay => 30);
    set_plugin_prefs($b, enabled => 1, power_control => 0,
        eversolo_ip => '192.168.1.197', eversolo_port => 9529, screen_off_delay => 30);

    my $offtimer = $P->can('_turnScreenOff');

    # B has a screen-off pending when the device is powered down under it.
    $P->can('_onPauseOrStop')->($b);
    is( scalar( grep { $_->{cb} == $offtimer } @TIMERS ), 1,
        'B has a screen-off pending' );

    # A's power button takes the whole device down.
    $P->can('_powerCallback')->( Stub::Request->new($a, 0) );
    is(scalar @POWER_OFF, 1, 'the device is powered down from A');

    is( scalar( grep { $_->{cb} == $offtimer } @TIMERS ), 0,
        "and B's pending screen-off goes with it, not just A's" );

    @TIMERS = (); @HTTP_GET = ();
    $P->can('_reconcile')->();
    is( scalar( grep { $_->{cb} == $offtimer } @TIMERS ), 0,
        'reconcile then schedules nothing for either player' );
    is( scalar @HTTP_GET, 0, 'and sends the dead device nothing' );
}

print "\n-- the MAC is a fact about the DEVICE, not about the opted-in player --\n";
{
    my $ns = 'plugin.eversoloscreencontrol';
    %PREFS = (); %ONCHANGE = (); @CLIENTS = ();

    # The case the page exists for, and the one this used to fail: the opted-in
    # player never learned the MAC (its box was ticked while the device was
    # off), and a sibling player on the same address holds it.  _lookup is the
    # only writer and it writes per player, only while the device answers.
    $PREFS{$ns}{'a-optedin'} = { %$OPTED, eversolo_ip => '192.168.1.197' };
    # 12 hex, as the field stores it: Discovery::_identify normalises net_mac
    # before PlayerSettings writes it (t_discovery.pl tests that against the
    # real sub, with colons, dashes and rubbish).
    $PREFS{$ns}{'b-knows'}   = { enabled => 1, power_control => 0, home_power => 0,
                                 eversolo_ip => '192.168.1.197',
                                 eversolo_mac => '800a805e2b7b',
                                 eversolo_name => 'DMP-A8 (ManCave)' };

    my @d = $P->can('_powerDevices')->();
    is(scalar @d, 1, 'one device, listed because a player opted in');
    is($d[0]->{mac}, '800a805e2b7b',
        "and it can be woken using the sibling player's MAC");
    is($d[0]->{name}, 'DMP-A8 (ManCave)', 'and named from it too');

    # The opt-in is still what decides whether the device appears at all.
    %PREFS = ();
    $PREFS{$ns}{'b-knows'} = { enabled => 1, power_control => 0, home_power => 0,
                               eversolo_ip => '192.168.1.197',
                               eversolo_mac => '800a805e2b7b' };
    my @none = $P->can('_powerDevices')->();
    is(scalar @none, 0, 'a player that knows the MAC but has not opted in lists nothing');
}

print "\n-- no address, no tile --\n";
{
    my $ns = 'plugin.eversoloscreencontrol';
    # @REGISTERED is NOT reset: the tile is registered once per server run and
    # _syncHomeTile mutates that same hashref for ever after, so clearing the
    # list here would just hide it.
    %PREFS = (); %ONCHANGE = (); @CLIENTS = ();

    Stub::PrefsRoot->new($ns)->setChange( $P->can('_syncHomeTile'), sync_tile_prefs() );

    # Every box ticked, no address typed in yet.  Nothing can be sent anywhere,
    # so there is nothing for a tile to open - it used to be offered anyway, and
    # opened a page saying no player had the box ticked.
    $PREFS{$ns}{half} = { %$OPTED, eversolo_ip => '' };

    $P->can('_syncHomeTile')->();
    my $tile = @REGISTERED ? $REGISTERED[-1][1] : undef;
    ok( !( $tile && $tile->{iframe} ), 'a player with the boxes ticked but no address gets no tile' );
    my @none = $P->can('_powerDevices')->();
    is( scalar @none, 0, 'and no device on the page' );

    # Whitespace is not an address either.
    Stub::PrefsRoot->new($ns)->client( Stub::Client->new('half') )->set('eversolo_ip', '   ');
    $tile = @REGISTERED ? $REGISTERED[-1][1] : undef;
    ok( !( $tile && $tile->{iframe} ), 'nor is a field holding only spaces' );

    # Typing the address in is what offers it, through the real pref carrier.
    Stub::PrefsRoot->new($ns)->client( Stub::Client->new('half') )
        ->set('eversolo_ip', '192.168.1.197');

    $tile = @REGISTERED ? $REGISTERED[-1][1] : undef;
    is( $tile && $tile->{iframe}, '/eversolopower',
        'filling the address in offers the tile, with no other change' );
}

print "\n-- a wake needs a MAC --\n";
{
    %PREFS = ();
    @CLIENTS = ();
    @POWER_OFF = ();
    $PREFS{'plugin.eversoloscreencontrol'}{x} = { %$OPTED, eversolo_ip => '192.168.1.70' };
    my $q = Stub::Query->new(id => '192.168.1.70', to => 'on')->execute($P->can('_powerSetCommand'));
    is($q->{status}, 102, 'the REAL _sendWake refuses a device with no MAC, and the press is refused');
}

print "\n-- per-player defaults actually reach the player --\n";
{
    my $ns = 'plugin.eversoloscreencontrol';
    %PREFS = (); %DEFAULTS = (); %ONCHANGE = (); @CLIENTS = ();

    # The method that never existed.  If this ever answers again, the defaults
    # block has gone back to a call LMS AUTOLOADs into a pref of its own name.
    ok( !Stub::PrefsRoot->can('setPlayerDefault'),
        'there is no setPlayerDefault to call, in the stub or in LMS' );

    $P->can('_initClientPrefs')->( Stub::Client->new('fresh') );

    is($PREFS{$ns}{fresh}{eversolo_port},    9529, 'a fresh player gets the default port');
    is($PREFS{$ns}{fresh}{screen_off_delay}, 30,   'and the default screen-off delay');
    is($PREFS{$ns}{fresh}{power_control},    0,    'power control off by default');
    is($PREFS{$ns}{fresh}{home_power},       0,    'and it is not on the power page');

    # The settings page reads the delay with no fallback of its own, so the
    # default has to BE there, not merely implied by a reader.
    is( Stub::PrefsRoot->new($ns)->client( Stub::Client->new('fresh') )
            ->get('screen_off_delay'),
        30, 'and the settings page reads it back' );

    # A configured player must come through untouched, including a deliberate 0.
    $PREFS{$ns}{set} = { eversolo_port => 4321, screen_off_delay => 0 };
    $P->can('_initClientPrefs')->( Stub::Client->new('set') );
    is($PREFS{$ns}{set}{eversolo_port},    4321, 'an existing setting is not overwritten');
    is($PREFS{$ns}{set}{screen_off_delay}, 0,    'and a deliberate 0 delay survives');

    # Base::init writes straight into the hash, so nothing here may look like a
    # user changing a pref - that would offer the Home tile on its own.
    my $fired = 0;
    $ONCHANGE{$ns}{home_power} = [ sub { $fired++ } ];
    $P->can('_initClientPrefs')->( Stub::Client->new('quiet') );
    is($fired, 0, 'initialising defaults fires no pref-change callback');

    # And the players that arrive after the module loaded.
    $P->can('_onClientNew')->( Stub::Request->new( Stub::Client->new('arrived') ) );
    is($PREFS{$ns}{arrived}{eversolo_port}, 9529, 'a player that arrives later is initialised too');

    $P->can('_onClientNew')->( Stub::ForgetRequest->new('nobody') );
    ok(!exists $PREFS{$ns}{nobody}, 'a notification carrying no client writes nothing');
}

print "\n-- one device reads the same way on every restart --\n";
{
    my $ns = 'plugin.eversoloscreencontrol';
    %PREFS = (); %ONCHANGE = (); @CLIENTS = ();

    # Two players pointing at ONE Eversolo and disagreeing about the port.  A
    # device has one control port, so one of them is simply wrong - but the page
    # must not pick a different one per restart, which is what it did while the
    # answer came from whatever order allClients happened to yield.
    $PREFS{$ns}{'aa:player'} = { %$OPTED, eversolo_ip => '192.168.1.197',
        eversolo_port => 9529, eversolo_name => 'DMP-A8' };
    $PREFS{$ns}{'zz:player'} = { %$OPTED, eversolo_ip => '192.168.1.197',
        eversolo_port => 7777, eversolo_name => 'ZZ misconfigured' };

    my @d = $P->can('_powerDevices')->();
    is(scalar @d,      1,        'two players on one address still list one device');
    is($d[0]->{port},  9529,     'the port comes from the lowest client id, not the hash order');
    is($d[0]->{name}, 'DMP-A8',  'and so does the name');
}

print "\n-- a forgotten player leaves no state behind --\n";
{
    %PREFS = (); %ONCHANGE = (); @TIMERS = (); @HTTP_GET = ();

    my $client = Stub::Client->new('comes-back', mode => 'stop');
    @CLIENTS = ($client);
    set_plugin_prefs($client, enabled => 1, eversolo_ip => '192.168.1.197',
        eversolo_port => 9529, screen_off_delay => 30);

    my $offtimer = $P->can('_turnScreenOff');

    # An off-timer IS pending, so reconcile must leave this player alone.  The
    # control assertion: without it the one below could pass for the wrong
    # reason, against a reconcile that schedules on every pass.
    $P->can('_onPauseOrStop')->($client);
    @TIMERS = ();
    $P->can('_reconcile')->();
    is( scalar( grep { $_->{cb} == $offtimer } @TIMERS ), 0,
        'reconcile leaves a player whose off-timer is already pending alone' );

    # Now LMS forgets the player and one of the same id comes back.  LMS's
    # forgetTimer killed the timer with EV_KILL, which returns BEFORE the
    # callback - so _turnScreenOff never ran and never cleared the flag.
    $P->can('_onForget')->( Stub::ForgetRequest->new('comes-back') );

    @TIMERS = ();
    $P->can('_reconcile')->();
    is( scalar( grep { $_->{cb} == $offtimer } @TIMERS ), 1,
        'after a forget that id is reconciled again, not skipped for ever' );
}

print "\n-- a wake that never left is not a wake --\n";
{
    # No packet can be addressed, so nothing leaves the host.  This is the case
    # that used to return 1 and arm the 120s grace window over a device that was
    # never signalled - and nothing answers a magic packet, so it was invisible.
    no warnings 'redefine';
    local *Socket::inet_aton = sub { undef };

    my $r = $P->can('_sendWake')->(
        '80:0a:80:5e:2b:7b', '192.168.1.197', 'DMP-A8', 'test' );

    is($r, 0, '_sendWake reports failure when no packet could be sent');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
