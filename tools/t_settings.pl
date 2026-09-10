#!/usr/bin/env perl
#
# t_settings.pl - runs the REAL settings handler end to end.
#
#   perl tools/t_settings.pl
#
# Why this exists. 1.5.0 shipped a settings page that did not work on the live
# server, and every check that had been run passed: `perl -c` compiles a module,
# it does not execute it, so it cannot see a handler that dies half way through
# and leaves the page half filled in. Nothing had ever RUN the handler.
#
# So this does. It stubs the six LMS pieces PlayerSettings.pm touches - prefs,
# log, the settings base class, a client, and Discovery - loads the real module,
# and drives handler() through the states a user actually puts it in, asserting
# both the invariant and that the handler RAN TO COMPLETION every time (which is
# what `SUPER_RAN` proves: the last statement in the handler is the SUPER call,
# so if it is missing, something above it died).
#
# ESC_SETTINGS points at a mutated copy to anti-test an assertion.
#
# Exit 0 = the page works. Exit 1 = it has regressed.
use strict;
use warnings;
use File::Spec;

my $ROOT = File::Spec->rel2abs(File::Spec->catdir((File::Spec->splitpath($0))[1], File::Spec->updir));
my $SETTINGS = $ENV{ESC_SETTINGS}
    || File::Spec->catfile($ROOT, 'EversoloScreenControl', 'PlayerSettings.pm');

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

# ---------------------------------------------------------------------------
#  Stubs: just enough LMS for the module to load and run.
# ---------------------------------------------------------------------------
{
    package Stub::Prefs;                       # one player's prefs, as a hash
    sub new  { my ($c, %v) = @_; bless {%v}, $c }
    sub get  { $_[0]->{ $_[1] } }
    sub set  { $_[0]->{ $_[1] } = $_[2]; return ($_[2], 1) }
    sub hasValidator { 0 }
    sub namespace    { 'plugin.eversoloscreencontrol' }
}
our $CPREFS = Stub::Prefs->new;

{
    package Slim::Utils::Prefs;
    sub import { no strict 'refs'; *{ caller() . '::preferences' } = \&preferences }
    sub preferences { bless {}, 'Slim::Utils::Prefs::Obj' }
    package Slim::Utils::Prefs::Obj;
    sub client           { return $main::CPREFS }
    sub setPlayerDefault { }
    sub get              { }
}
{
    package Slim::Utils::Log;
    sub import { no strict 'refs'; *{ caller() . '::logger' } = \&logger }
    sub logger { bless {}, 'Slim::Utils::Log::Obj' }
    package Slim::Utils::Log::Obj;
    our $AUTOLOAD;
    sub AUTOLOAD { return 1 }
    sub DESTROY  { }
}
{
    package Slim::Web::HTTP::CSRF;
    sub protectName { $_[1] }
    sub protectURI  { $_[1] }
}
{
    # The base class, mimicking what LMS really does: save each pref from
    # pref_<name>, then fill prefs.* for the template. The last thing the real
    # handler does is call this, so SUPER_RAN proves it got to the end.
    package Slim::Web::Settings;
    sub handler {
        my ($class, $client, $p) = @_;
        $p->{'SUPER_RAN'} = 1;
        my ($pc, @prefs) = $class->prefs($client);
        for my $pref (@prefs) {
            $pc->set($pref, $p->{ 'pref_' . $pref }) if $p->{'saveSettings'};
            $p->{'prefs'}{ 'pref_' . $pref } = $pc->get($pref);
            $p->{'prefs'}{$pref}             = $pc->get($pref);
        }
        return 'RENDERED';
    }
}
our $ANSWER;        # what the device at the address replies, or undef
our @ASKED;         # every address identify() was called with
our $DEFER_IDENTIFY;
our @PENDING_IDENTIFY;
{
    package Plugins::EversoloScreenControl::Discovery;
    sub identify {
        my ($ip, $port, $cb) = @_;
        push @main::ASKED, $ip;
        if ($main::DEFER_IDENTIFY) {
            push @main::PENDING_IDENTIFY, $cb;
            return;
        }
        return $cb->($main::ANSWER);
    }
    sub describe {
        my $rec = shift or return '';
        my $model = $rec->{model} || 'Eversolo';
        return $rec->{name} ? "$model ($rec->{name})" : $model;
    }
}
{
    package Stub::Client;
    sub new  { bless {}, shift }
    sub id   { '02:ab:88:42:4c:69' }
    sub ip   { '192.168.1.238:49855' }
    sub name { 'HQPlayer' }
}

$INC{$_} = 1 for qw(
    Slim/Utils/Prefs.pm Slim/Utils/Log.pm Slim/Web/Settings.pm Slim/Web/HTTP.pm
    Plugins/EversoloScreenControl/Discovery.pm
);

require $SETTINGS;
my $CLASS = 'Plugins::EversoloScreenControl::PlayerSettings';

# ---------------------------------------------------------------------------
sub completed {
    my ($p, $what) = @_;
    ok(!$p->{'DIED'}, "handler ran to completion - $what")
        or print "        died: $p->{DIED}";
    ok($p->{'SUPER_RAN'}, "reached SUPER::handler - $what");
}

my $MANCAVE = {
    model => 'DMP-A8', name => 'ManCave', mac => '800a805e2b7b'
};

sub run {
    my (%opt) = @_;

    $CPREFS = Stub::Prefs->new( %{ $opt{prefs} || {} } );
    $ANSWER = $opt{answer};
    $DEFER_IDENTIFY = $opt{defer} || 0;
    @ASKED  = ();
    @PENDING_IDENTIFY = ();

    my %params = %{ $opt{params} || {} };
    my $client = exists $opt{client} ? $opt{client} : Stub::Client->new;

    eval { $CLASS->handler($client, \%params) };
    $params{'DIED'} = $@ if $@;

    return \%params;
}

print "\n-- nothing configured --\n";
{
    my $p = run();
    completed($p, 'empty');
    is($p->{'deviceName'}, '', 'no name to show');
    is(scalar @ASKED, 0, 'and nothing is asked - there is no address to ask');
}

print "\n-- an address is set, the device has not been asked yet --\n";
{
    my $p = run( prefs => { eversolo_ip => '192.168.1.197' }, answer => $MANCAVE );
    completed($p, 'address set, name unknown');
    is($ASKED[0], '192.168.1.197', 'the device is asked who it is');
    is($CPREFS->get('eversolo_name'), 'DMP-A8 (ManCave)', 'and the answer is remembered');
}

print "\n-- the name is known: show it, do not ask again --\n";
{
    my $p = run( prefs => { eversolo_ip => '192.168.1.197',
                            eversolo_name => 'DMP-A8 (ManCave)',
                            eversolo_mac => '800a805e2b7b' } );
    completed($p, 'name known');
    is($p->{'deviceName'}, 'DMP-A8 (ManCave)', 'the name is on the page');
    is(scalar @ASKED, 0, 'the device is not asked again on every page load');
}

print "\n-- a name is cached but Wake-on-LAN still needs the MAC --\n";
{
    my $p = run(
        prefs  => { eversolo_ip => '192.168.1.197',
                    eversolo_name => 'DMP-A8 (ManCave)' },
        answer => $MANCAVE,
    );
    completed($p, 'name known, MAC missing');
    is(scalar @ASKED, 1, 'the device is asked again while its MAC is missing');
    is($CPREFS->get('eversolo_mac'), '800a805e2b7b', 'the missing MAC is learned');
}

print "\n-- the device does not answer --\n";
{
    my $p = run( prefs => { eversolo_ip => '10.0.0.9' }, answer => undef );
    completed($p, 'no answer');
    is($p->{'deviceName'}, '', 'no name is invented');
    is($CPREFS->get('eversolo_name'), undef, 'and nothing is stored');
}

print "\n-- SAVING an address --\n";
{
    my $p = run(
        answer => $MANCAVE,
        params => { saveSettings => 1, pref_eversolo_ip => ' http://192.168.1.197:9529/ ',
                    pref_enabled => [ '0', '1' ], pref_eversolo_port => '9529',
                    pref_screen_off_delay => '30' },
    );
    completed($p, 'saving an address');
    is($CPREFS->get('eversolo_ip'), '192.168.1.197', 'scheme, port and path stripped');
    is($CPREFS->get('enabled'), 1, 'the checkbox is collapsed to 1, not the raw array');
    is($CPREFS->get('eversolo_name'), 'DMP-A8 (ManCave)', 'the new device is identified');
    is($p->{'prefs'}{'eversolo_ip'}, '192.168.1.197', 'and the page redraws with it');
}

print "\n-- SAVING a DIFFERENT address --\n";
{
    my $p = run(
        prefs  => { eversolo_ip => '192.168.1.197', eversolo_name => 'DMP-A8 (ManCave)' },
        answer => undef,
        params => { saveSettings => 1, pref_eversolo_ip => '192.168.1.50',
                    pref_enabled => '1', pref_eversolo_port => '9529',
                    pref_screen_off_delay => '30' },
    );
    completed($p, 'changing the address');
    is($CPREFS->get('eversolo_ip'), '192.168.1.50', 'the new address is stored');
    is($CPREFS->get('eversolo_name'), '',
        "the old device's name is dropped - it must never sit beside another address");
}

print "\n-- a late answer from the old address is ignored --\n";
{
    my $p = run(
        prefs => { eversolo_ip => '192.168.1.197', eversolo_port => 9529 },
        answer => $MANCAVE,
        defer => 1,
    );
    completed($p, 'deferred lookup');
    is(scalar @PENDING_IDENTIFY, 1, 'one asynchronous lookup is pending');

    $CPREFS->set('eversolo_ip', '192.168.1.50');
    $PENDING_IDENTIFY[0]->($MANCAVE);

    is($CPREFS->get('eversolo_name'), undef, "the old device's name is not retained");
    is($CPREFS->get('eversolo_mac'),  undef, "the old device's MAC is not retained");
}

print "\n-- SAVING with the box emptied --\n";
{
    my $p = run(
        prefs  => { eversolo_ip => '192.168.1.197', eversolo_name => 'DMP-A8 (ManCave)' },
        params => { saveSettings => 1, pref_eversolo_ip => '',
                    pref_enabled => '0', pref_eversolo_port => '9529',
                    pref_screen_off_delay => '30' },
    );
    completed($p, 'clearing the address');
    is($CPREFS->get('eversolo_ip'), '', 'the address is cleared');
    is($CPREFS->get('enabled'), 0, 'unticked really is off');
    is(scalar @ASKED, 0, 'and nothing is asked');
}

print "\n-- odd input --\n";
{
    completed(run( client => undef ), 'no player bound');
    completed(run( prefs => { eversolo_ip => ['0','1'], enabled => ['0','1'] } ),
        'prefs already poisoned with arrays');
    my $p = run( params => { saveSettings => 1, pref_eversolo_port => 'x',
                             pref_screen_off_delay => '9999' } );
    completed($p, 'a save with junk in the numeric fields');
    is($CPREFS->get('eversolo_port'), 9529, 'a bad port falls back to the default');
    is($CPREFS->get('screen_off_delay'), 30, 'an out-of-range delay falls back too');
}

print "\n-- there is no discovery, and there must not be --\n";
{
    # A /24 sweep took Simon's server off the network on 2026-08-30 (it floods
    # the kernel's ARP table); the SSDP search that replaced it was machinery
    # for a problem that does not exist. Neither comes back.
    my $src = do { open(my $fh, '<', $SETTINGS) or die $!; local $/; <$fh> };
    my $disc = do {
        my $f = $SETTINGS; $f =~ s/PlayerSettings/Discovery/;
        open(my $fh, '<', $f) or die $!; local $/; <$fh>;
    };

    for my $pair ( [ 'PlayerSettings.pm', $src ], [ 'Discovery.pm', $disc ] ) {
        my ($what, $code) = @$pair;

        # Comments are stripped first: the modules explain at length WHY there
        # is no sweep and no multicast, and that history is worth keeping. It
        # is executable code that must not contain it.
        $code =~ s/^\s*#.*$//mg;
        ok($code !~ /1\s*\.\.\s*254/,      "$what walks no address range");
        ok($code !~ /M-SEARCH|239\.255/,   "$what sends no multicast");
        ok($code !~ /\bsub scan\b/,        "$what has no scan");
    }
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
