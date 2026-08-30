package Plugins::EversoloScreenControl::Discovery;

# Talking to an Eversolo over its HTTP control API.
#
# There is no device DISCOVERY here and there must not be.  Two attempts at it
# were removed on 2026-08-30: a /24 sweep (254 probes per subnet) took the
# server off the network by flooding its ARP table, and the SSDP search that
# replaced it was machinery for a problem the user does not have - the address
# of the Eversolo is known, and is typed in once.  What this module does is ask
# a device at a KNOWN address who it is and what it is doing.
#
# Every call is non-blocking (Slim::Networking::SimpleAsyncHTTP).  Never use a
# blocking HTTP call - it will stall the LMS event loop.


# Finds Eversolo devices on the local network by asking the same HTTP control
# API the plugin drives.  A device answers
#
#   http://<ip>:9529/ZidooControlCenter/getModel
#
# with a JSON body carrying status 200 plus model, net_mac, firmware and so on,
# so a responder on that port IS an Eversolo (or a Zidoo box speaking the same
# API) — no vendor discovery protocol, no extra modules, nothing to install on
# the server.
#
# getModel is the identification call in Zidoo's own API and in the reference
# client (wizmo2/zidoo-player); an earlier build here guessed at
# "getDeviceInfo", which no firmware serves, so every probe 404'd and the scan
# found nothing. Both paths live under the same ZidooControlCenter root as the
# sendkey call the plugin already relies on.
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
use Slim::Player::Client;


my $log   = logger('plugin.eversoloscreencontrol');
my $prefs = preferences('plugin.eversoloscreencontrol');

# Zidoo's identification call: status 200 + model, net_mac, firmware, language.
use constant PROBE_PATH    => '/ZidooControlCenter/getModel';

# These are hosts that have just answered a UPnP search, so they are up; a
# couple of seconds is plenty for the one HTTP question asked of each.
use constant PROBE_TIMEOUT => 2;



# ---------------------------------------------------------------------------
#  Ask a device what IT thinks it is doing.
#
#  /ZidooMusicControl/v2/getState answers {"status":200,"state":N,...} where the
#  state is 0 idle, 3 playing, 4 paused (Eversolo's own app and the Home
#  Assistant integration read the same field).  $cb->('play'|'pause'|'stop') on
#  a clear answer, $cb->(undef) when the device cannot be reached or says
#  something unrecognised — undef means "no opinion", never "stopped", because
#  a missed reply must not blank a screen mid-track.
#
#  This is the second half of a two-way check: LMS's idea of the player and the
#  device's own idea of itself, with the device winning when they disagree.
#  It is called sparingly by design — see _reconcile in Plugin.pm.
# ---------------------------------------------------------------------------
sub deviceState {
    my ($ip, $port, $cb) = @_;

    return $cb->(undef) unless $ip;
    $port ||= 9529;

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $body = shift->content || '';

            my ($state) = $body =~ /"state"\s*:\s*(\d+)/;

            if ( !defined $state ) {
                main::DEBUGLOG && $log->is_debug && $log->debug(
                    "Eversolo: $ip answered getState with no state field");
                return $cb->(undef);
            }

            my $mode = $state == 3 ? 'play'
                     : $state == 4 ? 'pause'
                     : $state == 0 ? 'stop'
                     :               undef;

            main::DEBUGLOG && $log->is_debug && $log->debug(
                "Eversolo: $ip reports state=$state (" . ( $mode || 'unrecognised' ) . ')');

            $cb->($mode);
        },
        sub {
            my (undef, $error) = @_;
            main::INFOLOG && $log->is_info && $log->info(
                "Eversolo: could not ask $ip what it is doing — " . ( $error || 'no answer' ));
            $cb->(undef);
        },
        { timeout => PROBE_TIMEOUT },
    )->get("http://${ip}:${port}/ZidooMusicControl/v2/getState");

    return;
}







# ---------------------------------------------------------------------------
#  Who is at this address?
#
#  GET /ZidooControlCenter/getModel, which is Zidoo's identification call and
#  the one the plugin has always used to confirm a device is what it claims.
#  $cb->($rec) with a record, or $cb->(undef) if nothing there answered it.
#
#  A DMP-A8 on firmware v1.5.75 answers:
#
#    {"status":200,"model":"DMP-A8","deviceName":"ManCave",
#     "net_mac":"80:0a:80:5e:2b:7b","ableRemoteBoot":true, ...}
#
#  deviceName is the point of this call for the settings page: it is the name
#  the user gave the box on the box itself, so the page can say which device it
#  is talking to rather than echoing an address back at them.
# ---------------------------------------------------------------------------
sub identify {
    my ($ip, $port, $cb) = @_;

    return $cb->(undef) unless $ip;
    $port ||= 9529;

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            $cb->( _identify( shift->content, $ip ) );
        },
        sub {
            my (undef, $error) = @_;
            main::INFOLOG && $log->is_info && $log->info(
                "Eversolo: $ip did not answer getModel - " . ( $error || 'no answer' ));
            $cb->(undef);
        },
        { timeout => PROBE_TIMEOUT },
    )->get("http://${ip}:${port}" . PROBE_PATH);

    return;
}

# The name to show for a device: what it calls itself, and its model.
sub describe {
    my $rec = shift or return '';

    my $model = $rec->{'model'} || 'Eversolo';
    my $name  = $rec->{'name'};

    return $name ? "$model ($name)" : $model;
}

# ---------------------------------------------------------------------------
#  Power.
#
#  Eversolo's firmware adds a power group on top of Zidoo's API.  Asking the
#  DMP-A8 (firmware v1.5.75) what it can do:
#
#    GET /ZidooMusicControl/v2/getPowerOption
#    -> {"status":200,"data":[{"name":"Power off","tag":"poweroff"},
#                             {"name":"Reboot","tag":"reboot"},
#                             {"name":"Screen off","tag":"screen"},
#                             {"name":"Timed shutdown","tag":"timeshutdown"}]}
#
#  so powering DOWN is one HTTP call.  Powering UP cannot be: the device is off
#  and nothing is listening on 9529.  That is what the Wake-on-LAN packet in
#  Plugin.pm is for, and why getModel's net_mac is worth keeping.
# ---------------------------------------------------------------------------
sub setPowerOption {
    my ($ip, $port, $tag, $cb) = @_;

    return unless $ip && $tag;
    $port ||= 9529;

    $cb ||= sub { };

    Slim::Networking::SimpleAsyncHTTP->new(
        sub { $cb->(1) },
        sub {
            my (undef, $error) = @_;

            # The device pulls the power on itself the moment it accepts this,
            # so a dropped connection IS the success case as often as not.
            main::INFOLOG && $log->is_info && $log->info(
                "Eversolo: $ip did not answer setPowerOption($tag) - " . ( $error || 'no answer' ));
            $cb->(0);
        },
        { timeout => PROBE_TIMEOUT },
    )->get("http://${ip}:${port}/ZidooMusicControl/v2/setPowerOption?tag=${tag}");

    return;
}

# ---------------------------------------------------------------------------
#  MAC handling.
#
#  Devices and users write a MAC every way there is - colons, dashes, upper or
#  lower case - and the stored form has to match the discovered form exactly or
#  a picked device silently stops resolving.  So there is ONE canonical form,
#  twelve lower-case hex digits, and everything goes through here: what is
#  parsed off the wire, what is saved from the settings page, and what is read
#  back to compare.  Anything that is not twelve hex digits is not a MAC and
#  comes back empty rather than half-normalised.
# ---------------------------------------------------------------------------
sub normaliseMac {
    my $mac = shift;

    return '' unless defined $mac;

    $mac = lc $mac;
    $mac =~ s/[^0-9a-f]//g;

    return length($mac) == 12 ? $mac : '';
}





# ---------------------------------------------------------------------------
#  Finding devices: ASK, don't sweep.
#
#  This used to walk the whole /24 - 254 HTTP probes per subnet.  That is a
#  hostile thing to do to a network, and it took down the server it was meant
#  to be helping: probing addresses where nothing exists makes the kernel ARP
#  for every one of them, and a few hundred unresolved neighbour entries is
#  enough to wedge a box's networking.  LMS went unreachable and had to be
#  restarted.  Do not reintroduce a sweep, however gentle the concurrency looks.
#
#  It was never necessary.  The Eversolo is a UPnP MediaRenderer and answers an
#  SSDP M-SEARCH like everything else on the network:
#
#    LOCATION: http://192.168.1.197:1212/description.xml
#    SERVER:   UPnP/1.0 DLNADOC/1.50 Platinum/1.0.5.13
#    <friendlyName>DMP-A8(ManCave)</friendlyName> <manufacturer>EVERSOLO</...>
#
#  So: one multicast datagram, a couple of seconds of listening, and the answer
#  is a handful of addresses (14 on the network this was built against) rather
#  than 254 guesses.  Each responder is then asked getModel - the same proof as
#  before, that a device is only a device if the control API answers - just
#  asked of the few addresses that spoke up.
#
#  This also removes the whole question of "which subnet are we on", which is
#  what broke discovery before: multicast goes where it goes, and nothing has
#  to work out the server's own address (which can be 127.0.0.1 - see the notes
#  in CLAUDE.md).
# ---------------------------------------------------------------------------






# ---------------------------------------------------------------------------
#  Is this response an Eversolo?  Returns a device record, or undef.
#
#  Parsed by hand rather than through a JSON module: the answer is a flat
#  object and everything wanted from it is a scalar one regex away.
#
#  Deliberately tolerant about the shape.  The documented answer is
#  {"status":200,"model":"...","net_mac":"...",...}, but Eversolo's firmware is
#  a fork of Zidoo's and the plugin cannot be rebuilt every time a field moves:
#  a JSON body on this path from this port is the device, whatever else it
#  says.  Anything that is not JSON is somebody else's web server and is
#  rejected - the port is not exclusive.  By the same rule every field below is
#  optional; a record with nothing but an address still identifies a device the
#  user can pick, it just has less to say about it.
# ---------------------------------------------------------------------------
sub _identify {
    my ($body, $ip) = @_;

    return unless $body;
    return unless $body =~ /^\s*\{/;                       # JSON object, or not ours
    return if     $body =~ /"status"\s*:\s*(?!200)\d+/;    # answered, but not with success

    my %rec = ( ip => $ip );

    # What the device calls itself: DMP-A8, DMP-A6, and so on.
    for my $key (qw(model modelName device_model)) {
        if ( $body =~ /"\Q$key\E"\s*:\s*"([^"]+)"/ ) {
            $rec{model} = $1;
            last;
        }
    }

    # A user-set name, if this firmware serves one.  Zidoo's documented getModel
    # does not, so this will usually be empty and describe() falls through to an
    # LMS player at the same address - but the field costs one regex to look for
    # and is the best label there is when a network holds two of the same model.
    for my $key (qw(deviceName device_name friendlyName name)) {
        if ( $body =~ /"\Q$key\E"\s*:\s*"([^"]+)"/ ) {
            $rec{name} = $1;
            last;
        }
    }

    # The wired MAC.  This is the identity a picked device is remembered by, and
    # it is also the address a Wake-on-LAN packet has to be sent to, so it is
    # worth capturing even though nothing wakes the device today.
    if ( $body =~ /"net_mac"\s*:\s*"([^"]*)"/ ) {
        $rec{mac} = normaliseMac($1);
    }

    # The device's own word on whether it can be booted over the network.
    if ( $body =~ /"ableRemoteBoot"\s*:\s*(true|false|\d+)/ ) {
        my $v = $1;
        $rec{remoteBoot} = ( $v eq 'false' || $v eq '0' ) ? 0 : 1;
    }

    # Answered the control API but named itself nothing we recognise.  Still a
    # device - the address is what matters.
    $rec{model} ||= 'Eversolo';

    return \%rec;
}

1;

__END__
