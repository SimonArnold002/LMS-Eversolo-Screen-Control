#!/usr/bin/env perl
#
# t_page.pl - renders the REAL power page (Power.pm) without a running LMS.
#
#   perl tools/t_page.pl
#
# The page is one non-interpolating heredoc with %%TOKEN%% labels, driven by two
# jsonrpc commands registered in Plugin.pm.  What can go wrong without anything
# failing loudly: a token left unfilled, a label that breaks out of its
# attribute, characters sent where the Content-Type promises UTF-8 octets, a
# missing status code (LMS then writes "HTTP/1.1  "), and the page asking for a
# command name the plugin never registered.  Each is checked here.
#
# ESC_POWER points at a mutated copy to anti-test an assertion.
use strict;
use warnings;
use File::Spec;

my $ROOT = File::Spec->rel2abs(
    File::Spec->catdir((File::Spec->splitpath($0))[1], File::Spec->updir)
);
my $POWER = $ENV{ESC_POWER}
    || File::Spec->catfile($ROOT, 'EversoloScreenControl', 'Power.pm');
my $PLUGIN = File::Spec->catfile($ROOT, 'EversoloScreenControl', 'Plugin.pm');
my $STRINGS = File::Spec->catfile($ROOT, 'EversoloScreenControl', 'strings.txt');

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $what) = @_;
    $cond ? ($pass++, print "  PASS  $what\n") : ($fail++, print "  FAIL  $what\n");
    return $cond ? 1 : 0;
}

our (@RAW, %SENT);

# The real strings, read the way LMS reads them (UTF-8, tab-separated), so a
# key the page names and strings.txt lacks shows up as a failure here.
our %STR;
{
    open my $fh, '<:encoding(UTF-8)', $STRINGS or die "$STRINGS: $!";
    my $key;
    while (<$fh>) {
        chomp;
        if (/^(\S+)$/)             { $key = $1; next }
        if (/^\tEN\t(.*)$/ && $key) { $STR{$key} = $1 }
    }
}

{
    package Slim::Utils::Strings;
    sub string { exists $main::STR{$_[0]} ? $main::STR{$_[0]} : "MISSING:$_[0]" }

    package Slim::Web::Pages;
    sub addRawFunction { push @main::RAW, [ $_[1], $_[2] ] }

    package Slim::Web::HTTP;
    sub addHTTPResponse { $main::SENT{body} = ${ $_[2] }; $main::SENT{response} = $_[1] }

    package Stub::HTTPClient;
    sub new { bless {}, shift }
    sub connected { 1 }

    package Stub::Response;
    sub new { bless { headers => {} }, shift }
    sub code         { $_[0]->{code} = $_[1] }
    sub content_type { $_[0]->{type} = $_[1] }
    sub header       { $_[0]->{headers}{ $_[1] } = $_[2] }
}

$INC{$_} = 1 for qw(Slim/Utils/Strings.pm Slim/Web/Pages.pm Slim/Web/HTTP.pm);

require $POWER;
my $P = 'Plugins::EversoloScreenControl::Power';

print "\n-- registration --\n";
$P->init('/eversolopower');
ok(@RAW == 1, 'one raw handler is registered');
ok($RAW[0] && '/eversolopower' =~ $RAW[0][0], 'on the path it was handed');

print "\n-- the page --\n";
my $html = $P->can('_page')->();
ok($html !~ /%%\w+%%/,   'every %%TOKEN%% is filled');
ok($html !~ /MISSING:/,  'every label the page names exists in strings.txt');
ok($html =~ m{<title>Eversolo Power</title>}, 'the title is the localised page name');
ok($html =~ /data-waking="Switching on\x{2026}"/, 'labels reach the script as data attributes');

# Every D.<key> the script reads must be a data-<key> on <body>.
my %data = map { $_ => 1 } $html =~ /\bdata-(\w+)=/g;
my @used = do { my %u; grep { !$u{$_}++ } $html =~ /\bD\.(\w+)/g };
my @missing = grep { !$data{$_} } @used;
ok(@used && !@missing, 'every label the script reads is on <body>'
    . (@missing ? "  [missing: @missing]" : ''));

# D[d.state] reads the states by name.
ok(!grep({ !$data{$_} } qw(on off waking stopping)), 'and every state the server answers has a label');

print "\n-- escaping --\n";
{
    local $STR{PLUGIN_EVERSOLO_PP_ON} = 'On" onmouseover="x<y>&';
    my $h = $P->can('_page')->();
    ok($h =~ /data-on="On&quot; onmouseover=&quot;x&lt;y&gt;&amp;"/, 'a label cannot break out of its attribute');
}

print "\n-- the commands exist --\n";
{
    my $plugin = do { open my $fh, '<', $PLUGIN or die $!; local $/; <$fh> };
    for my $cmd (qw(status set)) {
        ok($html =~ /'eversolopower', '$cmd'/, "the page calls eversolopower $cmd");
        ok($plugin =~ /\[ 'eversolopower', '$cmd' \]/, "and Plugin.pm registers it");
    }
    ok($plugin =~ /POWER_PAGE_PATH\s*=>\s*'\/eversolopower'/, 'Plugin.pm hands over the same path');
}

print "\n-- the response --\n";
{
    %SENT = ();
    $RAW[0][1]->(Stub::HTTPClient->new, Stub::Response->new);
    my $r = $SENT{response};
    ok($r && $r->{code} == 200, 'the status code is set - a raw handler owns it');
    ok($r && $r->{type} eq 'text/html; charset=utf-8', 'served as UTF-8 HTML');
    ok(defined $SENT{body} && !utf8::is_utf8($SENT{body}), 'the body is octets, not characters');
    ok(defined $SENT{body} && index($SENT{body}, "\xE2\x80\xA6") >= 0, 'the ellipsis goes out as UTF-8');
    ok($r && ($r->{headers}{'Cache-Control'} || '') =~ /no-store/, 'and is never cached');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
