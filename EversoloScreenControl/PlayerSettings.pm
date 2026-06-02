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
    return ($prefs->client($client), qw(enabled eversolo_ip eversolo_port screen_off_delay));
}

sub handler {
    my ($class, $client, $params) = @_;

    # ---- Resolve this player's IP (strip port if present) ----
    my $playerIP = '';
    if ($client) {
        $playerIP = $client->ip() || '';
        # ip() should return just the IP, but guard against ip:port format
        $playerIP =~ s/:.*$//;
    }

    if ($params->{'saveSettings'} && $client) {

        # --- Enabled (checkbox) ---
        $params->{'enabled'} = $params->{'enabled'} ? 1 : 0;

        # --- Eversolo IP (trim whitespace; auto-fill from player IP if blank) ---
        my $ip = $params->{'eversolo_ip'} || '';
        $ip =~ s/^\s+|\s+$//g;
        $ip = $playerIP if ($ip eq '' && $playerIP ne '');
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

    # Pass current per-player values to the template
    if ($client) {
        my $savedIP = $prefs->client($client)->get('eversolo_ip') || '';

        # Auto-populate the saved pref from the player IP if it has never
        # been set.  This means the field is pre-filled the first time the
        # user opens the settings page for this player.
        if ($savedIP eq '' && $playerIP ne '') {
            $prefs->client($client)->set('eversolo_ip', $playerIP);
            $savedIP = $playerIP;
        }

        $params->{'prefs'}->{'enabled'}          = $prefs->client($client)->get('enabled');
        $params->{'prefs'}->{'eversolo_ip'}      = $savedIP;
        $params->{'prefs'}->{'eversolo_port'}    = $prefs->client($client)->get('eversolo_port');
        $params->{'prefs'}->{'screen_off_delay'} = $prefs->client($client)->get('screen_off_delay');

        # Also pass the detected player IP so the template can show it
        $params->{'playerIP'} = $playerIP;
    }

    return $class->SUPER::handler($client, $params);
}

1;
