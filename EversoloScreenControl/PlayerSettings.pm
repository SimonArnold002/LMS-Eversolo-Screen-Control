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

        # --- Manual Eversolo IP (trim whitespace) ---
        my $ip = $params->{'eversolo_ip'} || '';
        $ip =~ s/^\s+|\s+$//g;
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

    # Pass the live player IP so the template can display it.  The per-player
    # pref values themselves are populated into $params->{prefs} by
    # SUPER::handler (after it saves), so we don't set them here.
    if ($client) {
        $params->{'playerIP'} = $playerIP;
    }

    return $class->SUPER::handler($client, $params);
}

1;
