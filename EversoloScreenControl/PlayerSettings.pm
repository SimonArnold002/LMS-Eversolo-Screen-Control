package Plugins::EversoloScreenControl::PlayerSettings;

# Per-player settings page.  Because needsClient() returns 1 this page appears
# in the Player Settings menu (alongside DSD Player, etc.) rather than in the
# global Advanced menu.
#
# There is ONE thing to configure: the address of the Eversolo this player
# drives.  You type it in once.
#
# There is no device discovery and there must not be.  Two attempts were
# removed on 2026-08-30: a /24 sweep, which took the server off the network by
# ARP-flooding it, and an SSDP search, which was machinery for a problem nobody
# has - the address is known, and typing it is less work than any of it.
#
# What the page DOES do with the address is ask the device who it is, over the
# same HTTP API the plugin already uses to drive the screen, so the page can
# say "DMP-A8 (ManCave)" rather than echoing an address back at you.  That
# lookup is asynchronous: it cannot fill in the page that triggered it, so the
# name is stored and appears from then on.
#
# This module deliberately calls NOTHING in Plugin.pm.  It used to, and when
# that module was not loaded the call died half way through building the page -
# LMS still rendered what had been filled in by then, so the page came back
# looking merely wrong (nothing selected, nothing saved) instead of visibly
# broken.  A settings page that cannot save is worse than one that errors.

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;

use Plugins::EversoloScreenControl::Discovery;

my $prefs = preferences('plugin.eversoloscreencontrol');
my $log   = logger('plugin.eversoloscreencontrol');

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_EVERSOLO_SCREEN_CONTROL');
}

sub getDisplayName {
    return 'PLUGIN_EVERSOLO_SCREEN_CONTROL';
}

# ---- This is the key method: returning 1 places the page in Player Settings ----
sub needsClient {
    return 1;
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI(
        'plugins/EversoloScreenControl/settings/basic.html'
    );
}

sub prefs {
    my ($class, $client) = @_;
    return ($prefs->client($client),
        qw(enabled power_control eversolo_ip eversolo_port screen_off_delay));
}

sub handler {
    my ($class, $client, $params) = @_;

    if ( $params->{'saveSettings'} && $client ) {

        my $cprefs = $prefs->client($client);

        # --- Enabled ---
        # A checkbox with a hidden 0 partner posts BOTH values when ticked, and
        # LMS hands that over as an arrayref.  Stored raw it becomes ['0','1'],
        # which is truthy for ever after - a toggle that can never be turned
        # off.  Collapse it, and repair a pref already in that state.
        $params->{'pref_enabled'}       = _checkbox( $params->{'pref_enabled'} );
        $params->{'pref_power_control'} = _checkbox( $params->{'pref_power_control'} );

        # --- The Eversolo's address ---
        my $was = _address( $cprefs->get('eversolo_ip') );
        my $now = _address( $params->{'pref_eversolo_ip'} );

        $params->{'pref_eversolo_ip'} = $now;

        # --- Port (a valid number 1-65535, default 9529) ---
        my $port = $params->{'pref_eversolo_port'} || 9529;
        $port = 9529 if ( $port !~ /^\d+$/ || $port < 1 || $port > 65535 );
        $params->{'pref_eversolo_port'} = int($port);

        # --- Screen-off delay (0-600 seconds, default 30) ---
        my $delay = $params->{'pref_screen_off_delay'};
        $delay = 30 if ( !defined $delay || $delay !~ /^\d+$/ || $delay < 0 || $delay > 600 );
        $params->{'pref_screen_off_delay'} = int($delay);

        # Store the address now rather than leaving it to SUPER::handler at the
        # end of this method, because the rest of this method reads it back.
        $cprefs->set('eversolo_ip',    $now);
        $cprefs->set('eversolo_port',  $params->{'pref_eversolo_port'});
        $cprefs->set('enabled',        $params->{'pref_enabled'});
        $cprefs->set('power_control',  $params->{'pref_power_control'});

        # A new address knows nothing about itself yet.  Drop the old name so
        # the page cannot show one device's name beside another's address.
        if ( $now ne $was ) {
            $cprefs->set('eversolo_name', '');
            $cprefs->set('eversolo_mac',  '');
        }

        _lookup( $client, $now, $params->{'pref_eversolo_port'} );
    }

    if ($client) {
        my $cprefs = $prefs->client($client);

        my $ip   = _address( $cprefs->get('eversolo_ip') );
        my $port = $cprefs->get('eversolo_port') || 9529;

        $params->{'prefs'}->{'enabled'}          = _checkbox( $cprefs->get('enabled') );
        $params->{'prefs'}->{'power_control'}    = _checkbox( $cprefs->get('power_control') );
        $params->{'prefs'}->{'eversolo_ip'}      = $ip;
        $params->{'prefs'}->{'eversolo_port'}    = $port;
        $params->{'prefs'}->{'screen_off_delay'} = $cprefs->get('screen_off_delay');

        my $name = $cprefs->get('eversolo_name');
        $params->{'deviceName'} = defined $name ? $name : '';

        # Wake-on-LAN needs the device's MAC, and the device only tells us while
        # it is ON. Show whether we have it, so "power on does nothing" has a
        # visible cause rather than being a mystery.
        $params->{'deviceMAC'} = $cprefs->get('eversolo_mac') || '';

        # Ask until both the display identity and the MAC needed for Wake-on-LAN
        # are known.  The answer appears on the next view.
        _lookup($client, $ip, $port)
            if $ip ne ''
            && ( $params->{'deviceName'} eq '' || $params->{'deviceMAC'} eq '' );
    }
    else {
        $params->{'deviceName'} = '';
    }

    return $class->SUPER::handler($client, $params);
}

# ---------------------------------------------------------------------------
#  Ask the device at this address who it is, and remember the answer.
#
#  Asynchronous, so it cannot fill in the page that asked for it - the name
#  appears on the next view.  That is the honest trade for not blocking the
#  event loop.  The answer is stored, so it is not asked again once both the
#  display identity and Wake-on-LAN MAC are known.
# ---------------------------------------------------------------------------
sub _lookup {
    my ($client, $ip, $port) = @_;

    return unless $client && $ip;

    $ip   = _address($ip);
    $port = 9529 unless defined $port && $port =~ /^\d+$/;

    Plugins::EversoloScreenControl::Discovery::identify($ip, $port, sub {
        my $rec = shift or return;

        my $cprefs = $prefs->client($client);

        # The lookup is asynchronous.  Do not let an answer from an address the
        # user has since replaced attach its name or, more importantly, its MAC
        # to the newly selected device.
        my $current_ip   = _address( $cprefs->get('eversolo_ip') );
        my $current_port = $cprefs->get('eversolo_port') || 9529;
        return unless $current_ip eq $ip && $current_port == $port;

        my $name = Plugins::EversoloScreenControl::Discovery::describe($rec);
        $cprefs->set('eversolo_name', $name) if $name;

        # Learned here and nowhere else: the device only answers while it is on,
        # and by the time it needs waking it is too late to ask.
        $cprefs->set('eversolo_mac', $rec->{'mac'}) if $rec->{'mac'};

        $log->info(sprintf('Eversolo: %s is %s%s', $ip, $name || 'an Eversolo',
            $rec->{'mac'} ? ' (' . $rec->{'mac'} . ')' : ''));
    });

    return;
}

# An address as it should be stored: no scheme, no path, no port, no spaces.
# Tolerates a pasted address bar rather than storing something unusable.
sub _address {
    my $ip = shift;

    return '' unless defined $ip;

    $ip = $ip->[-1] if ref $ip eq 'ARRAY';

    $ip =~ s/^\s+|\s+$//g;
    $ip =~ s{^\w+://}{};
    $ip =~ s{/.*$}{};
    $ip =~ s/:\d+$//;

    return $ip;
}

# A checkbox value as 0 or 1.  LMS hands over an arrayref when a hidden field
# and a ticked box share a name, and a pref already stored in that state has to
# read back as a boolean too.
sub _checkbox {
    my $v = shift;

    $v = $v->[-1] if ref $v eq 'ARRAY';

    return $v ? 1 : 0;
}

1;
