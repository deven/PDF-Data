#!/usr/bin/env perl

use v5.10;
use strict;
use warnings;

use Cwd            qw[abs_path];
use File::Basename qw[dirname];

use lib dirname(dirname(abs_path(__FILE__))) . "/lib";

use Test2::V0;

use PDF::Data;

# Epoch-0 binary signature specification: 4 bytes, one 0xDC byte (initials "D" and "C" as hex nibbles), one companion
# surrogate-range byte 0b11011xxx carrying the high 3 bits of the middle initial "T", and two 0xE0-0xEF bytes carrying
# the remaining "T" bits and the version payload.  The position of the 0xDC byte identifies the implementation; the
# Perl implementation uses the mirrored arrangement "DC Ex Ex DD".  Version payload: 2-bit major version field ("10"
# for v2.x, "11" for v3.x, "00" for v4.x, "01" for v5.x, with an implied leading "1" for the wrapped values) in bits
# 3-2 of byte 2, minor version (0-63) split across bits 1-0 of byte 2 and bits 3-0 of byte 3.

# Map the 2-bit major version field back to the major version number.
my %major_for_field = (2 => 2, 3 => 3, 0 => 4, 1 => 5);

# Verify every encoding guarantee for a 4-byte signature; return a list of failure descriptions (empty on success).
sub invariant_failures {
  my ($signature) = @_;
  my @bytes    = map { ord } split //, $signature;
  my @failures = ();

  # Exactly 4 bytes.
  return ("signature is not exactly 4 bytes") unless @bytes == 4;

  # Guarantees 1-3: every byte has both high-order bits set (0b11xxxxxx), making the signature high-bit binary data
  # and an invalid UTF-8 encoding (initial bytes of multi-byte sequences with no continuation bytes).
  push @failures, "byte values are not all UTF-8 leader bytes (0b11xxxxxx)" if grep { ($_ & 0xC0) != 0xC0 } @bytes;

  # Structural invariants: exactly one 0xDC byte, exactly two surrogate-range bytes (0xD8-0xDF) at opposite byte
  # parities, and exactly two 0xE0-0xEF bytes at opposite byte parities (the basis of guarantee 7).
  my @dc        = grep { $bytes[$_] == 0xDC                       } 0 .. 3;
  my @surrogate = grep { $bytes[$_] >= 0xD8 && $bytes[$_] <= 0xDF } 0 .. 3;
  my @pua       = grep { $bytes[$_] >= 0xE0 && $bytes[$_] <= 0xEF } 0 .. 3;
  push @failures, "0xDC byte count is not exactly 1"                     unless @dc == 1;
  push @failures, "surrogate-range byte count is not exactly 2"          unless @surrogate == 2;
  push @failures, "0xE0-0xEF byte count is not exactly 2"                unless @pua == 2;
  push @failures, "surrogate-range bytes are not at opposite parities"   unless @surrogate == 2 and $surrogate[0] % 2 != $surrogate[1] % 2;
  push @failures, "0xE0-0xEF bytes are not at opposite parities"         unless @pua == 2       and $pua[0]       % 2 != $pua[1]       % 2;

  # Guarantees 4-5 and 7: for both endiannesses, the two aligned 16-bit values consist of exactly one unpaired low
  # surrogate (U+DC00 to U+DFFF, invalid UTF-16) and one Private Use Area value (U+E000 to U+EFFF, nonsensical UCS-2).
  my @big_endian    = (($bytes[0] << 8) | $bytes[1], ($bytes[2] << 8) | $bytes[3]);
  my @little_endian = (($bytes[1] << 8) | $bytes[0], ($bytes[3] << 8) | $bytes[2]);
  for ([BE => @big_endian], [LE => @little_endian]) {
    my ($endian, @values) = @{$_};
    push @failures, "$endian low surrogate count is not exactly 1" unless 1 == grep { $_ >= 0xDC00 && $_ <= 0xDFFF } @values;
    push @failures, "$endian PUA value count is not exactly 1"     unless 1 == grep { $_ >= 0xE000 && $_ <= 0xEFFF } @values;
  }

  # Guarantee 6: for both endiannesses, the 32-bit value is far outside the valid code point range (U+0000 to U+10FFFF).
  push @failures, "big-endian UTF-32 value is a valid code point"
    unless (($bytes[0] << 24) | ($bytes[1] << 16) | ($bytes[2] << 8) | $bytes[3]) > 0x10FFFF;
  push @failures, "little-endian UTF-32 value is a valid code point"
    unless (($bytes[3] << 24) | ($bytes[2] << 16) | ($bytes[1] << 8) | $bytes[0]) > 0x10FFFF;

  return @failures;
}

# Decode a Perl-arrangement signature; return (implementation position, middle initial, major, minor).
sub decode_signature {
  my ($signature) = @_;
  my @bytes = map { ord } split //, $signature;

  # Locate the 0xDC byte to determine the implementation position (byte 1 of 4 for Perl).
  my ($position) = grep { $bytes[$_] == 0xDC } 0 .. 3;

  # Reassemble the middle initial from its scattered bits: "xxx" from the companion surrogate byte, "y" and "z" from
  # bit 4 of each 0xE0-0xEF byte, then decode the 5-bit value back to a letter.
  my $xxx            = $bytes[3] & 0x07;
  my $y              = ($bytes[1] >> 4) & 0x01;
  my $z              = ($bytes[2] >> 4) & 0x01;
  my $middle_initial = chr((($xxx << 2) | ($y << 1) | $z) + 64);

  # Extract the major version field and minor version bits.
  my $major = $major_for_field{($bytes[1] >> 2) & 0x03};
  my $minor = (($bytes[1] & 0x03) << 4) | ($bytes[2] & 0x0F);

  return ($position, $middle_initial, $major, $minor);
}

# Test count: 4 live-signature tests + (4 majors x 64 minors x 3 tests) + 3 clamping tests + 3 preserve-mode tests.
plan(4 + 4 * 64 * 3 + 3 + 3);

# Verify the live signature for the current PDF::Data version.
my $pdf  = PDF::Data->new;
my @live = invariant_failures($pdf->binary_signature);
ok(!@live, "live signature satisfies all encoding guarantees") or diag(join "; ", @live);

my ($position, $middle_initial, $major, $minor) = decode_signature($pdf->binary_signature);
is($position,       0,   "live signature uses the Perl arrangement (0xDC in byte 1 of 4)");
is($middle_initial, "T", "live signature middle initial verifies");

my ($expected_major, $expected_minor) = $pdf->version =~ /^v(\d+)\.(\d+)\./;
is([$major, $minor], [$expected_major, $expected_minor], "live signature version matches " . $pdf->version)
  or diag(sprintf "decoded v%d.%d", $major, $minor);

# Sweep every encodable version (v2.0 through v5.63): verify the encoding guarantees and round-trip the version.
for my $sweep_major (2 .. 5) {
  for my $sweep_minor (0 .. 63) {
    no warnings qw[redefine];
    local *PDF::Data::version = sub { return sprintf "v%d.%d.0", $sweep_major, $sweep_minor; };
    my $signature = $pdf->binary_signature;
    my @failures  = invariant_failures($signature);
    ok(!@failures, sprintf "v%d.%-2d signature satisfies all encoding guarantees", $sweep_major, $sweep_minor)
      or diag(join "; ", @failures);
    my ($sweep_position, $sweep_initial, $decoded_major, $decoded_minor) = decode_signature($signature);
    is([$sweep_position, $sweep_initial], [0, "T"],
       sprintf "v%d.%-2d signature arrangement and middle initial verify", $sweep_major, $sweep_minor);
    is([$decoded_major, $decoded_minor], [$sweep_major, $sweep_minor],
       sprintf "v%d.%-2d version round-trips", $sweep_major, $sweep_minor);
  }
}

# Verify clamping behavior for versions outside the encodable range.  (Reaching these clamps in a real release is the
# signal to define a new encoding via the reserved expansion mechanisms, not to extend the clamping.)
for ([ "v1.5.0", 2, 5 ], [ "v6.0.0", 5, 63 ], [ "v2.99.0", 2, 63 ]) {
  my ($version, $clamped_major, $clamped_minor) = @{$_};
  no warnings qw[redefine];
  local *PDF::Data::version = sub { return $version; };
  my (undef, undef, $decoded_major, $decoded_minor) = decode_signature($pdf->binary_signature);
  is([$decoded_major, $decoded_minor], [$clamped_major, $clamped_minor],
     "out-of-range $version clamps to v$clamped_major.$clamped_minor");
}

# Verify -preserve_binary_signature: defaults to the Adobe signature, preserves a captured signature verbatim, and
# ignores the PDF::Data signature algorithm entirely.
my $adobe = PDF::Data->new(-preserve_binary_signature => 1);
is($adobe->binary_signature, "\xBF\xF7\xA2\xFE", "preserve mode defaults to the Adobe binary signature");

my $legacy_signature = "\xDD\xE4\xE2\xDC";
my $preserved = PDF::Data->new(-preserve_binary_signature => 1, -binary_signature => $legacy_signature);
is($preserved->binary_signature, $legacy_signature, "preserve mode returns a captured signature verbatim");
is($preserved->binary_signature, $legacy_signature, "preserve mode is stable across repeated calls");
