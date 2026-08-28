package Plugins::EversoloScreenControl::PlayerSettings;

# Per-player settings page.  Because needsClient() returns 1 this page
# appears in the Player Settings menu (alongside DSD Player, etc.) rather
# than in the global Advanced menu.

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;

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
        qw(enabled auto_detect_ip eversolo_ip eversolo_port screen_off_delay));
}

sub handler {
    my ($class, $client, $params) = @_;

    # ---- Resolve this player's live IP (strip port if present) ----
    my $playerIP = '';
    if ($client) {
        $playerIP = $client->ip() || '';
        $playerIP =~ s/:.*$//;
    }

    if ($params->{'saveSettings'} && $client) {

        # --- Enabled (checkbox) ---
        $params->{'enabled'} = $params->{'enabled'} ? 1 : 0;

        # --- Auto-detect IP (checkbox, default on) ---
        $params->{'auto_detect_ip'} = $params->{'auto_detect_ip'} ? 1 : 0;

        # --- Manual Eversolo IP ---
        # Tolerate a pasted address bar: strip a scheme, any path, and lift a
        # trailing :port into the port field rather than storing an address
        # that can never resolve.
        my $ip = $params->{'eversolo_ip'} || '';
        $ip =~ s/^\s+|\s+$//g;
        $ip =~ s{^\w+://}{};
        $ip =~ s{/.*$}{};
        if ($ip =~ s/:(\d+)$//) {
            $params->{'eversolo_port'} = $1;
        }
        $params->{'eversolo_ip'} = $ip;

        # --- Port (must be a valid number 1-65535, default 9529) ---
        my $port = $params->{'eversolo_port'} || 9529;
        $port = 9529 if ($port !~ /^\d+$/ || $port < 1 || $port > 65535);
        $params->{'eversolo_port'} = int($port);

        # --- Screen-off delay (0-600 seconds, default 30) ---
        my $delay = $params->{'screen_off_delay'};
        $delay = 30 if (!defined $delay || $delay !~ /^\d+$/ || $delay < 0 || $delay > 600);
        $params->{'screen_off_delay'} = int($delay);
    }

    # Populate current per-player values for the template.  NOTE: the base
    # Slim::Web::Settings::handler only fills PREFIX-ed keys ($params->{prefs}
    # ->{pref_enabled} etc.), but this template reads the UNPREFIXED keys
    # (prefs.enabled, prefs.eversolo_ip, ...).  Without this block every field
    # renders blank/unchecked and the settings page appears broken, so we must
    # populate them here.
    if ($client) {
        $params->{'prefs'}->{'enabled'}          = $prefs->client($client)->get('enabled');
        $params->{'prefs'}->{'auto_detect_ip'}   = $prefs->client($client)->get('auto_detect_ip');
        $params->{'prefs'}->{'eversolo_ip'}      = $prefs->client($client)->get('eversolo_ip') || '';
        $params->{'prefs'}->{'eversolo_port'}    = $prefs->client($client)->get('eversolo_port');
        $params->{'prefs'}->{'screen_off_delay'} = $prefs->client($client)->get('screen_off_delay');

        # Pass the live player IP so the template can display it, plus whether
        # it is a real device address at all.  A bridged or virtual player
        # (HQPlayer Bridge, Groups, a UPnP bridge) has no socket and reports a
        # placeholder, so auto-detect has nothing to work with and the manual
        # address below is the only way to reach the hardware.
        $params->{'playerIP'}       = $playerIP;
        $params->{'playerBridged'}  =
            Plugins::EversoloScreenControl::Plugin::isPlaceholderIP($playerIP) ? 1 : 0;
        $params->{'effectiveIP'}    =
            Plugins::EversoloScreenControl::Plugin::_resolveIP($client) || '';
    }

    return $class->SUPER::handler($client, $params);
}

1;
