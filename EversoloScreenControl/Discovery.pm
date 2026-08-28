package Plugins::EversoloScreenControl::Discovery;

# Finds Eversolo devices on the local network by asking the same HTTP control
# API the plugin drives.  A device answers
#
#   http://<ip>:9529/ZidooControlCenter/getDeviceInfo
#
# with a JSON body carrying status 200 and its model/name, so a responder on
# that port IS an Eversolo (or a Zidoo box speaking the same API) — no vendor
# discovery protocol, no extra modules, nothing to install on the server.
#
# The sweep is entirely non-blocking: every probe is a SimpleAsyncHTTP request
# with a short timeout, and only a handful are ever in flight at once, so the
# event loop keeps serving players while it runs.

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Networking::SimpleAsyncHTTP;

my $log   = logger('plugin.eversoloscreencontrol');
my $prefs = preferences('plugin.eversoloscreencontrol');

# The device answers in milliseconds on a LAN; anything slower is not it.
use constant PROBE_TIMEOUT => 2;

# Probes in flight at once.  A /24 is 254 addresses, so this is the whole cost
# of a sweep: ~13 rounds of 20, a couple of seconds, all of it asynchronous.
use constant CONCURRENCY   => 20;

# One sweep at a time, server-wide.  Everything that asks while a sweep is
# running is parked and answered from that same result.
my $SCANNING = 0;
my @WAITING;

# Discovered devices from the last sweep: { ip => name }
my %FOUND;
my $LAST_SCAN = 0;

sub found     { return { %FOUND } }
sub lastScan  { return $LAST_SCAN }
sub isScanning{ return $SCANNING }

# ---------------------------------------------------------------------------
#  The addresses to probe.
#
#  Derived from the server's own IPv4 address(es) as a /24, which is what a
#  home network is in practice.  A device on a different subnet is out of
#  reach of any sweep short of a routing table, and that is exactly what the
#  manual address field is for.
# ---------------------------------------------------------------------------
sub _candidates {
    my @nets;

    for my $addr ( _serverAddresses() ) {
        next unless $addr =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/;
        next if $1 == 127;
        my $net = "$1.$2.$3";
        push @nets, $net unless grep { $_ eq $net } @nets;
    }

    my @hosts;
    for my $net (@nets) {
        push @hosts, map { "$net.$_" } ( 1 .. 254 );
    }

    return @hosts;
}

sub _serverAddresses {
    my @addrs;

    # Slim::Utils::IPDetect is the one LMS itself uses to answer "what address
    # do players reach me on"; hostAddr covers a multi-homed server.
    eval {
        require Slim::Utils::IPDetect;
        my $ip = Slim::Utils::IPDetect::IP();
        push @addrs, $ip if $ip;
    };

    eval {
        require Slim::Utils::Network;
        push @addrs, Slim::Utils::Network::hostAddr();
    };

    my %seen;
    return grep { $_ && !$seen{$_}++ } @addrs;
}

# ---------------------------------------------------------------------------
#  Sweep the network.  $cb->(\%found) when it finishes.
#
#  Single-flight: a second caller during a sweep gets the first sweep's result
#  rather than starting another one — a settings page reload should never put
#  a second 254-probe pass on the wire.
# ---------------------------------------------------------------------------
sub scan {
    my ($cb) = @_;

    if ($SCANNING) {
        push @WAITING, $cb if $cb;
        return;
    }

    my @queue = _candidates();

    if (!@queue) {
        $log->warn('Eversolo: could not work out the local subnet, so there is nothing to scan — set the address manually');
        $cb->({}) if $cb;
        return;
    }

    $SCANNING = 1;
    push @WAITING, $cb if $cb;

    my %found;
    my $port    = $prefs->get('scan_port') || 9529;
    my $pending = 0;
    my $step;

    main::INFOLOG && $log->is_info && $log->info(
        sprintf('Eversolo: scanning %d addresses on port %d for Eversolo devices', scalar(@queue), $port)
    );

    my $finish = sub {
        %FOUND     = %found;
        $LAST_SCAN = time();
        $SCANNING  = 0;

        my $n = scalar keys %found;
        if ($n) {
            $log->info(sprintf('Eversolo: scan found %d device(s): %s',
                $n, join(', ', map { "$_ ($found{$_})" } sort keys %found)));
        }
        else {
            $log->info('Eversolo: scan found no devices answering the Eversolo control API');
        }

        my @cbs = @WAITING;
        @WAITING = ();
        $_->({ %found }) for grep { $_ } @cbs;
    };

    $step = sub {
        while ( $pending < CONCURRENCY && @queue ) {
            my $ip = shift @queue;
            $pending++;

            Slim::Networking::SimpleAsyncHTTP->new(
                sub {
                    my $http = shift;
                    my $name = _identify( $http->content );
                    $found{ $http->params('ip') } = $name if $name;
                    $pending--;
                    $step->();
                },
                sub {
                    # Every address that is not a device lands here.  That is
                    # the normal case for 253 of 254 probes, so it must stay
                    # silent — no logging, no retry.
                    $pending--;
                    $step->();
                },
                {
                    timeout => PROBE_TIMEOUT,
                    ip      => $ip,
                },
            )->get("http://${ip}:${port}/ZidooControlCenter/getDeviceInfo");
        }

        $finish->() if !$pending && !@queue;
    };

    $step->();

    return;
}

# ---------------------------------------------------------------------------
#  Is this response an Eversolo?  Returns a display name, or undef.
#
#  Parsed by hand rather than through a JSON module: the answer is a flat
#  object and all we need from it is "did the control API answer" plus
#  something to show the user in the picker.
# ---------------------------------------------------------------------------
sub _identify {
    my $body = shift or return;

    return unless $body =~ /"status"\s*:\s*200/;

    for my $key (qw(name model device_name deviceName net_mac)) {
        if ( $body =~ /"\Q$key\E"\s*:\s*"([^"]+)"/ ) {
            return $1;
        }
    }

    # Answered the control API but named itself nothing we recognise.  Still a
    # device — the address is what matters.
    return 'Eversolo';
}

1;

__END__
