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

sub WEBUI   () { 0 }
sub INFOLOG () { 0 }
sub DEBUGLOG() { 0 }

our (%PREFS, %DEFAULTS, @CLIENTS, @TIMERS, @HTTP_GET, @STATE_CALLBACKS, @POWER_OFF);

{
    package Stub::ClientPrefs;
    sub new { bless { ns => $_[1], id => $_[2] }, $_[0] }
    sub get {
        my ($self, $key) = @_;
        return $main::PREFS{$self->{ns}}{$self->{id}}{$key}
            if exists $main::PREFS{$self->{ns}}{$self->{id}}{$key};
        return $main::DEFAULTS{$self->{ns}}{$key};
    }
    sub set {
        my ($self, $key, $value) = @_;
        $main::PREFS{$self->{ns}}{$self->{id}}{$key} = $value;
        return ($value, 1);
    }

    package Stub::PrefsRoot;
    sub new { bless { ns => $_[1] }, $_[0] }
    sub client { Stub::ClientPrefs->new($_[0]->{ns}, $_[1]->id) }
    sub setPlayerDefault { $main::DEFAULTS{$_[0]->{ns}}{$_[1]} = $_[2] }

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

    package Stub::Request;
    sub new { bless { client => $_[1], value => $_[2] }, $_[0] }
    sub client { $_[0]->{client} }
    sub getParam { $_[1] eq '_newvalue' ? $_[0]->{value} : undef }
    sub isCommand { 0 }
    sub getRequestString { '' }
}

{
    package Plugins::EversoloScreenControl::Discovery;
    sub deviceState { push @main::STATE_CALLBACKS, $_[2] }
    sub setPowerOption { push @main::POWER_OFF, [$_[0], $_[1], $_[2]] }
    sub normaliseMac { $_[0] }
}

$INC{$_} = 1 for qw(
    Slim/Plugin/Base.pm Slim/Utils/Log.pm Slim/Utils/Prefs.pm
    Slim/Utils/Timers.pm Slim/Networking/SimpleAsyncHTTP.pm
    Slim/Player/Client.pm Slim/Player/Source.pm
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

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
