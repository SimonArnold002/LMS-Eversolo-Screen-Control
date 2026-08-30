#!/usr/bin/env perl
#
# t_discovery.pl - the network sweep, driven with a REAL Eversolo response.
#
#   perl tools/t_discovery.pl
#
# Two things had never been tested, and both were broken in 1.6.0 and earlier:
#
#   1. WHAT IT MAKES OF A DEVICE'S ANSWER. The getModel body below is the
#      verbatim response from Simon's DMP-A8 at 192.168.1.197, captured
#      2026-08-30, so these assertions are against real firmware rather than a
#      guess at its shape - including deviceName ("ManCave"), which is the name
#      the settings page shows and which no test had ever seen.
#
#   2. THAT THERE IS NO DISCOVERY. A /24 sweep took Simon's server off the
#      network (it floods the kernel's ARP table), and the SSDP search that
#      briefly replaced it was machinery for a problem that does not exist -
#      the address is typed in once. The guard below fails if either returns.
#
# ESC_DISCOVERY points at a mutated copy to anti-test an assertion.
#
# Exit 0 = discovery works. Exit 1 = it has regressed.
use strict;
use warnings;
use File::Spec;

my $ROOT = File::Spec->rel2abs(File::Spec->catdir((File::Spec->splitpath($0))[1], File::Spec->updir));
my $DISCOVERY = $ENV{ESC_DISCOVERY}
    || File::Spec->catfile($ROOT, 'EversoloScreenControl', 'Discovery.pm');

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

# ---- stubs ----------------------------------------------------------------
{
    package Slim::Utils::Log;
    sub import { no strict 'refs'; *{ caller() . '::logger' } = \&logger }
    sub logger { bless {}, 'Slim::Utils::Log::Obj' }
    package Slim::Utils::Log::Obj;
    our $AUTOLOAD;
    sub AUTOLOAD { 1 }
    sub DESTROY  { }
}
{
    package Slim::Utils::Prefs;
    sub import { no strict 'refs'; *{ caller() . '::preferences' } = \&preferences }
    sub preferences { bless {}, 'Slim::Utils::Prefs::Obj' }
    package Slim::Utils::Prefs::Obj;
    sub get { }
    sub client { }
}
{
    package Slim::Networking::SimpleAsyncHTTP;
    sub new { bless {}, shift }
    sub get { }
    sub content { '' }
}
{
    package Slim::Networking::Select;
    sub addRead    { }
    sub removeRead { }
}
{
    package Slim::Utils::Timers;
    sub setTimer   { }
    sub killTimers { }
}
$INC{$_} = 1 for qw(
    Slim/Utils/Log.pm Slim/Utils/Prefs.pm Slim/Utils/Timers.pm
    Slim/Networking/SimpleAsyncHTTP.pm Slim/Player/Client.pm
    Slim/Networking/SimpleAsyncHTTP.pm
);
BEGIN { *main::DEBUGLOG = sub () { 0 }; *main::INFOLOG = sub () { 0 }; }

require $DISCOVERY;
my $D = 'Plugins::EversoloScreenControl::Discovery';

# ---- the verbatim answer from the DMP-A8 at 192.168.1.197 -----------------
our $REAL = '{"status":200,"model":"DMP-A8","disModel":"DMP-A8","deviceName":"ManCave",'
    . '"ip":"192.168.1.197","net_mac":"80:0a:80:5e:2b:7b","dType":0,'
    . '"duuid":"80:0a:80:5e:2b:7b","firmware":"v1.5.75","ram":" 4.0G","flash":" 64.0G",'
    . '"androidversion":"11","wif_mac":"44:87:63:30:6f:e5","language":"en",'
    . '"ableRemoteBoot":true,"ableRemoteShutdown":true,"ableRemoteReboot":true,'
    . '"ableRemoteSleep":false,"ableMusicService":true,"hasDspSetting":true,'
    . '"appcode":7931,"isNewphone":false,"nationcode":"826"}';

print "\n-- a real DMP-A8 answer --\n";
{
    my $rec = $D->can('_identify')->($REAL, '192.168.1.197');
    ok($rec, 'the device is recognised');
    is($rec->{model}, 'DMP-A8', 'model');
    is($rec->{name},  'ManCave', 'deviceName is picked up as the name');
    is($rec->{mac},   '800a805e2b7b', 'net_mac, normalised');
    is($rec->{remoteBoot}, 1, 'ableRemoteBoot:true is read as true');
    is($D->can("describe")->($rec), 'DMP-A8 (ManCave)', 'the picker label names the device');
}

print "\n-- things that are not an Eversolo --\n";
{
    ok(!$D->can('_identify')->('<html>hello</html>', '1.2.3.4'), 'a web server is rejected');
    ok(!$D->can('_identify')->('{"status":404}', '1.2.3.4'), 'an explicit failure is rejected');
    ok(!$D->can('_identify')->('', '1.2.3.4'), 'an empty body is rejected');
    my $bare = $D->can('_identify')->('{"status":200}', '1.2.3.4');
    ok($bare, 'a 200 with no fields is still a device');
    is($D->can("describe")->($bare), 'Eversolo', 'and gets a usable label');
}

print "\n-- asking a known address who it is --\n";
{
    # identify() is what the settings page calls to put a name beside an
    # address. Driven here through a stub HTTP layer so the real sub runs.
    my @got;
    {
        no warnings 'redefine';
        *Slim::Networking::SimpleAsyncHTTP::new = sub {
            my ($class, $ok, $err, $args) = @_;
            return bless { ok => $ok, err => $err }, $class;
        };
        *Slim::Networking::SimpleAsyncHTTP::get = sub {
            my ($self, $url) = @_;
            push @got, $url;
            $self->{ok}->( bless { body => $REAL }, 'Stub::Response' );
        };
        *Slim::Networking::SimpleAsyncHTTP::content = sub { $_[0]->{body} };
    }
    *Stub::Response::content = \&Slim::Networking::SimpleAsyncHTTP::content;

    my $seen;
    $D->can('identify')->('192.168.1.197', 9529, sub { $seen = shift });

    is($got[0], 'http://192.168.1.197:9529/ZidooControlCenter/getModel',
        'it asks getModel, on the address and port given');
    is($seen && $seen->{name}, 'ManCave', 'and hands back what the device said');

    my $none;
    $D->can('identify')->('', 9529, sub { $none = 'called'; });
    is($none, 'called', 'no address answers immediately rather than hanging');
}

print "\n-- there is no discovery, and there must not be --\n";
{
    my $code = do { open(my $fh, '<', $DISCOVERY) or die $!; local $/; <$fh> };

    # Comments are stripped first: the module explains at length WHY there is
    # no sweep and no multicast, and that history is worth keeping.
    $code =~ s/^\s*#.*$//mg;

    ok($code !~ /1\s*\.\.\s*254/, 'no code walks an address range');
    ok($code !~ /M-SEARCH|239\.255\.255\.250/, 'nothing is multicast');
    ok($code !~ /\bCONCURRENCY\b/, 'no batch of probes in flight');
    ok($code !~ /\bsub scan\b/, 'there is no scan');
}

print "\n-- MAC normalising (a stored MAC must match a discovered one) --\n";
{
    is($D->can("normaliseMac")->('80:0A:80:5E:2B:7B'), '800a805e2b7b', 'colons and case');
    is($D->can("normaliseMac")->('80-0a-80-5e-2b-7b'), '800a805e2b7b', 'dashes');
    is($D->can("normaliseMac")->('nonsense'), '', 'rubbish is not a MAC');
    is($D->can("normaliseMac")->(undef), '', 'undef is not a MAC');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
