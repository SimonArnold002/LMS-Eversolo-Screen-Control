#!/usr/bin/env perl
#
# t_power.pl - the Wake-on-LAN packet, checked byte for byte.
#
#   perl tools/t_power.pl
#
# Powering the Eversolo ON cannot be an HTTP call: the device is off, so nothing
# is listening. It is a magic packet, and a magic packet that is one byte wrong
# is indistinguishable from a network that swallowed it - it just silently does
# nothing. So the bytes are built by a pure function and asserted here against
# the spec: six 0xFF, then the target MAC sixteen times, 102 bytes.
#
# magicPacket is extracted VERBATIM from Plugin.pm, so this tracks shipped code.
# ESC_PLUGIN points at a mutated copy to anti-test an assertion.
use strict;
use warnings;
use File::Spec;

my $ROOT = File::Spec->rel2abs(File::Spec->catdir((File::Spec->splitpath($0))[1], File::Spec->updir));
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

sub grab {
    my ($src, $name) = @_;
    $src =~ /^sub \Q$name\E\b\s*\{/mg or die "no sub $name in $PLUGIN\n";
    my $start = $-[0];
    my $i     = pos($src);
    my $depth = 1;
    while ($i < length($src) && $depth) {
        my $c = substr($src, $i++, 1);
        $depth++ if $c eq '{';
        $depth-- if $c eq '}';
    }
    die "unbalanced sub $name\n" if $depth;
    return substr($src, $start, $i - $start);
}

my $src = do { open(my $fh, '<', $PLUGIN) or die "$PLUGIN: $!"; local $/; <$fh> };
eval "package ESCPower;\nuse strict; use warnings;\n" . grab($src, 'magicPacket') . "\n1;\n"
    or die "could not load magicPacket: $@";

# Simon's DMP-A8, from getModel: "net_mac":"80:0a:80:5e:2b:7b"
my $MAC = '800a805e2b7b';
my $pkt = ESCPower::magicPacket($MAC);

print "\n-- the packet --\n";
is(length($pkt), 102, 'is 102 bytes (6 + 6*16)');
is(unpack('H12', substr($pkt, 0, 6)), 'ffffffffffff', 'opens with six 0xFF');
{
    my $ok = 1;
    for my $i ( 0 .. 15 ) {
        $ok = 0 if unpack('H12', substr($pkt, 6 + $i * 6, 6)) ne $MAC;
    }
    ok($ok, 'then the MAC, sixteen times, and nothing else');
}
is(unpack('H*', substr($pkt, 6, 6)), '800a805e2b7b', 'the MAC is the real bytes, not its text');

print "\n-- the forms a MAC arrives in --\n";
is(ESCPower::magicPacket('80:0a:80:5e:2b:7b'), $pkt, 'colon-separated, as getModel reports it');
is(ESCPower::magicPacket('80-0A-80-5E-2B-7B'), $pkt, 'dashes and upper case');
is(ESCPower::magicPacket('800A805E2B7B'),      $pkt, 'bare upper case');

print "\n-- rubbish must not become a packet --\n";
is(ESCPower::magicPacket(''),          '', 'empty');
is(ESCPower::magicPacket(undef),       '', 'undef');
is(ESCPower::magicPacket('800a805e'),  '', 'too short');
is(ESCPower::magicPacket('zzzzzzzzzzzz'), '', 'not hex');
is(ESCPower::magicPacket('800a805e2b7bff'), '', 'too long');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
