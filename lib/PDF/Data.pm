package PDF::Data;

# Require Perl v5.16; enable warnings and UTF-8.
use v5.16;
use warnings;
use utf8;

# Declare module version.  (Also in pod documentation below.)
use version; our $VERSION = version->declare('v1.2.0');

# Initialize modules.
use mro;
use Carp                qw[carp croak confess];;
use Clone;
use Compress::Raw::Zlib qw[:status :flush];
use Data::Dump          qw[dd dump];
use List::Util          qw[max];
use Math::Trig          qw[pi];
use POSIX               qw[mktime strftime];
use Scalar::Util        qw[blessed reftype];

# Use byte strings instead of Unicode character strings.
use bytes;

# Basic parsing regular expressions.
our $n  = qr/(?:\n|\r\n?)/o;             # Match a newline. (LF, CRLF or CR)
our $ss = '\x00\x09\x0a\x0c\x0d\x20';    # List of PDF whitespace characters.
our $s  = "[$ss]";                       # Match a single PDF whitespace character.
our $ws = qr/(?:$s*(?>%[^\r\n]*)?$s+)/o; # Match whitespace, including PDF comments.

# Declare prototypes.
sub is_hash ($);
sub is_array ($);
sub is_stream ($);

# Utility functions.
sub is_hash   ($) { ref $_[0] && reftype($_[0]) eq "HASH"; }
sub is_array  ($) { ref $_[0] && reftype($_[0]) eq "ARRAY"; }
sub is_stream ($) { &is_hash  && exists $_[0]{-data}; }

# Create a new PDF::Data object, representing a minimal PDF file.
sub new {
  my ($self, %args) = @_;

  # Get the class name.
  my $class = blessed $self || $self;

  # Create a new instance using the constructor arguments.
  my $pdf = bless \%args, $class;

  # Set creation timestamp.
  $pdf->{Info}{CreationDate} = $pdf->timestamp;

  # Create an empty document catalog and page tree.
  $pdf->{Root}{Pages} = { Kids => [], Count => 0 };

  # Validate the PDF structure if the -validate flag is set, and return the new instance.
  return $pdf->{-validate} ? $pdf->validate : $pdf;
}

# Get PDF filename, if any.
sub file {
  my ($self) = @_;

  return ref $self && $self->{-file} // ();
}

# Deep copy entire PDF::Data object.
sub clone {
  my ($self) = @_;
  return Clone::clone($self);
}

# Create a new page with the specified size.
sub new_page {
  my ($self, $x, $y) = @_;

  # Paper sizes.
  my %sizes = (
    LETTER => [  8.5,    11      ],
    LEGAL  => [  8.5,    14      ],
    A0     => [ 33.125,  46.8125 ],
    A1     => [ 23.375,  33.125  ],
    A2     => [ 16.5,    23.375  ],
    A3     => [ 11.75,   16.5    ],
    A4     => [  8.25,   11.75   ],
    A5     => [  5.875,  8.25    ],
    A6     => [  4.125,  5.875   ],
    A7     => [  2.9375, 4.125   ],
    A8     => [  2.0625, 2.9375  ],
  );

  # Default page size to US Letter (8.5" x 11").
  unless ($x and $y and $x > 0 and $y > 0) {
    $x ||= "LETTER";
    croak "Error: Unknown paper size \"$x\"!\n" unless $sizes{$x};
    ($x, $y) = @{$sizes{$x}};
  }

  # Make sure page size was specified.
  croak join(": ", $self->file || (), "Error: Paper size not specified!\n") unless $x and $y and $x > 0 and $y > 0;

  # Scale inches to default user space units (72 DPI).
  $x *= 72 if $x < 72;
  $y *= 72 if $y < 72;

  # Create and return a new page object.
  return {
    Type      => "/Page",
    MediaBox  => [0, 0, $x, $y],
    Contents  => { -data => "" },
    Resources => {
      ProcSet => ["/PDF", "/Text"],
    },
  };
}

# Deep copy the specified page object.
sub copy_page {
  my ($self, $page) = @_;

  # Temporarily hide parent reference.
  delete local $page->{Parent};

  # Clone the page object.
  my $copied_page = Clone::clone($page);

  # return cloned page object.
  return $copied_page;
}

# Append the specified page to the PDF.
sub append_page {
  my ($self, $page) = @_;

  # Increment page count for page tree root node.
  $self->{Root}{Pages}{Count}++;

  # Add page object to page tree root node for simplicity.
  push @{$self->{Root}{Pages}{Kids}}, $page;
  $page->{Parent} = $self->{Root}{Pages};

  # Return the page object.
  return $page;
}

# Read and parse PDF file.
sub read_pdf {
  my ($self, $file, %args) = @_;

  # Read entire file at once.
  local $/;

  # Contents of entire PDF file.
  my $data;

  # Check for standard input.
  if (($file // "-") eq "-") {
    # Read all data from standard input.
    $file = "<standard input>";
    binmode STDIN or croak "$file: $!\n";
    $data = <STDIN>;
    close STDIN or croak "$file: $!\n";
  } else {
    # Read the entire file.
    open my $IN, '<', $file or croak "$file: $!\n";
    binmode $IN or croak "$file: $!\n";
    $data = <$IN>;
    close $IN or croak "$file: $!\n";
  }

  # Parse PDF file data and return new instance.
  return $self->parse_pdf($data, -file => $file, %args);
}

# Parse PDF file data.
sub parse_pdf {
  my ($self, $data, %args) = @_;

  # Get the class name.
  my $class = blessed $self || $self;

  # Create a new instance using the provided arguments.
  $self = bless \%args, $class;

  # Validate minimal PDF file structure starting with %PDF and ending with %%EOF, possibly surrounded by garbage.
  my ($pdf_version, $binary_signature) = $data =~ /%PDF-(\d+\.\d+)$s*?$n(?:$s*%$s*([\x80-\xff]{4,}).*?$n)?.*%%EOF/so
    or croak join(": ", $self->file || (), "File does not contain a valid PDF document!\n");

  # Get starting offset of %PDF line.
  my $offset = $-[0];

  # Check PDF version.
  warn join(": ", $self->file || (), "Warning: PDF version $pdf_version not supported!\n")
    unless $pdf_version =~ /^1\.[0-7]$/o;

  # Save parsed PDF version number and binary signature (if any).
  $self->{-pdf_version}      = $pdf_version;
  $self->{-binary_signature} = $binary_signature if $binary_signature;

  # Parsed indirect objects.
  $self->{-indirect_objects} = {};

  # Unresolved references to indirect objects.
  $self->{-unresolved_refs} = {};

  # Trailer dictionaries and cross-reference streams.
  $self->{-trailers} = [];

  # All stream objects.
  $self->{-streams} = [];

  # Parse PDF objects.
  my @objects = $self->parse_objects(\$data, \$offset);

  # Check for startxref value.
  my $startxref;
  if (@objects and $objects[-1]{type} eq "startxref") {
    $startxref = pop(@objects)->{data};
    pop @objects;
  }

  # Warn if startxref value is missing.
  unless ($startxref) {
    carp join(": ", $self->file || (), "Required \"startxref\" value missing!\n");
    $startxref = length $data;
  }

  # Trailer dictionaries to process.
  my @trailers;

  # Determine list of trailer dictionaries to process, in priority order.
  my $trailers = delete $self->{-trailers};
  while ($startxref) {
    # Find trailer dictionary or cross-reference stream nearest to the startxref offset.
    my $trailer = (sort { $a->[0] <=> $b->[0] } map [abs($_->{offset} - $startxref), $_], @{$trailers})[0][1]{data};

    # Add the selected trailer dictionary to the list.
    push @trailers, $trailer;

    # Continue with previous trailer, if any.
    $startxref = $trailer->{Prev} // "";
  }

  # Make sure trailer dictionary was found.
  croak join(": ", $self->file || (), "PDF trailer dictionary not found!\n") unless @trailers;

  # Loop across trailer dictionaries.
  foreach my $trailer (@trailers) {
    # Copy trailer dictionary entries.
    foreach my $key (keys %{$trailer}) {
      # Copy new keys, but skip keys specific to cross-reference streams.
      $self->{$key} //= $trailer->{$key} unless $key =~ /^(?:Length|Filter|DecodeParms|F|FFilter|FDecodeParms|DL|Index|Prev|W)$/;
    }
  }

  # Check for unresolved references.
  my $unresolved_refs = delete $self->{-unresolved_refs};
  my @ids = sort { $a <=> $b } keys %{$unresolved_refs};
  foreach my $id (@ids) {
    ($id, my $gen) = split /-/, $id;
    $gen ||= "0";
    warn join(": ", $self->file || (), "Warning: $id $gen R: Referenced indirect object not found!\n");
  }

  # Process all streams.
  foreach my $stream (@{$self->{-streams}}) {
    if (length($stream->{-data}) == $stream->{-length}) {
      substr($stream->{-data}, $stream->{Length}) =~ s/\A$s+\z// if $stream->{Length} and length($stream->{-data}) > $stream->{Length};
      my $len = length $stream->{-data};
      $stream->{Length} ||= $len;
      $len == $stream->{Length}
        or warn join(": ", $self->file || (), "Warning: Object #$stream->{-id}: Stream length does not match metadata! ($len != $stream->{Length})\n");
    }

    # Extend object collections.
    if (my $extends = $stream->{Extends}) {
      if (ref $extends and reftype($extends) eq "SCALAR") {
        my $id   = ${$extends};
        $extends = $self->{-indirect_objects}{$extends}
          or croak join(": ", $self->file || (), "Byte offset $stream->{-offset}: Stream #$stream->{-id}: Extends argument in object stream metadata refers to non-existent indirect object #$id!\n");
      }
      push @{$extends->{-objects}}, @{delete $stream->{-objects}};
      $stream->{Extends} = $extends;
    }
  }

  # Discard parsing metadata.
  delete $self->{-indirect_objects};
  delete $self->{-unresolved_refs};
  delete $self->{-trailers};
  delete $self->{-streams};

  # Validate the PDF structure if the -validate flag is set, and return the new instance.
  return $self->{-validate} ? $self->validate : $self;
}

# Generate and write a new PDF file.
sub write_pdf {
  my ($self, $file, $time) = @_;

  # Default missing timestamp to current time, but keep a zero time as a flag.
  $time //= time;

  # Generate PDF file data.
  my $pdf_data = $self->pdf_file_data($time);

  # Check if standard output is wanted.
  if (($file // "-") eq "-") {
    # Write PDF file data to standard output.
    $file = "<standard output>";
    binmode STDOUT           or croak "$file: $!\n";
    print   STDOUT $pdf_data or croak "$file: $!\n";
  } else {
    # Write PDF file data to specified output file.
    open my $OUT, ">", $file or croak "$file: $!\n";
    binmode $OUT             or croak "$file: $!\n";
    print   $OUT $pdf_data   or croak "$file: $!\n";
    close   $OUT             or croak "$file: $!\n";

    # Set modification time to the specified or current timestamp, unless zero.
    utime $time, $time, $file if $time;

    # Print success message.
    print STDERR "Wrote new PDF file \"$file\".\n\n";
  }
}

# Generate PDF file data suitable for writing to an output PDF file.
sub pdf_file_data {
  my ($self, $time) = @_;

  # Default missing timestamp to current time, but keep a zero time as a flag.
  $time //= time;

  # Set PDF modification timestamp, unless zero.
  $self->{Info}{ModDate} = $self->timestamp($time) if $time;

  # Set PDF producer.
  $self->{Info}{Producer} = sprintf "(%s)", join " ", __PACKAGE__, $VERSION;

  # Validate the PDF structure, unless the -novalidate flag is set.
  $self->validate unless $self->{-novalidate};

  # Array of indirect objects, with lookup hash as first element.
  $self->{-indirect_objects} = [{}];

  # Objects seen while generating the PDF file data.
  my $seen = {};

  # Use PDF version 1.4 by default.
  $self->{-pdf_version} ||= 1.4;

  # Determine whether or not to use object streams.
  $self->{-use_object_streams} ||= ($self->{-pdf_version} >= 1.5);

  # PDF version 1.5 is required to use object streams.
  $self->{-pdf_version} = 1.5 if $self->should_use_object_streams && $self->{-pdf_version} < 1.5;

  # Start with PDF header.
  my $pdf_file_data = sprintf "%%PDF-%3.1f\n%%%s\n\n", $self->{-pdf_version}, $self->binary_signature;

  # Write all indirect objects.
  $self->write_indirect_objects(\$pdf_file_data, $seen);

  # End of PDF file data.
  $pdf_file_data .= "%%EOF\n";

  # Return PDF file data.
  return $pdf_file_data;
}

# Construct PDF::Data binary signature.
sub binary_signature {
  my ($self) = @_;

  # Typical binary signature used by Adobe's PDF library.
  my $adobe_binary_signature = "\xBF\xF7\xA2\xFE";

  # Check for -preserve_binary_signature option to suppress normal PDF::Data binary signature.
  if ($self->{-preserve_binary_signature}) {
    # Default to Adobe binary signature if none is set.
    $self->{-binary_signature} ||= $adobe_binary_signature;
  } else {
    # Carefully encode the author's initials into the PDF::Data binary signature.  This only works for THIS author!
    my $author_initials = "DTC";
    my @initials        = split //, $author_initials;
    my $middle_initial  = splice @initials, 1, 1;
    my ($xxx, $y, $z)   = unpack "A3AA", sprintf("%05b", ord($middle_initial) - 64);

    # Encode the PDF::Data major/minor version numbers, within encoding limits (between v1.0 and v8.63).
    my ($major, $minor) = $PDF::Data::VERSION->normal =~ /(\d+)\.(\d+)/;
    $major = 8  if $major > 8;
    $minor = 63 if $major > 8 or $minor > 63;

    #
    # Construct the 4-byte binary signature using a carefully-designed bit pattern which guarantees:
    #
    # 1. Each byte has the high-order bit set, as recommended by the PDF specification to aid binary file detection.
    # 2. Interpreting the bytes as Latin-1 encoding would result in a nonsensical string.
    # 3. Interpreting the bytes as UTF-8 would be invalid because because all four bytes have both high-order bits set,
    #    which would indicate initial bytes of a multi-byte sequence.  Since every valid multi-byte sequence requires
    #    one or more continuation bytes (with bit 6 clear) to follow the initial byte, this byte sequence constitutes
    #    an invalid encoding for UTF-8.
    # 4. Interpreting the bytes as UTF-16 would also be invalid, because one of the two 16-bit values would be a low
    #    surrogate code in the U+DC00 to U+DFFF range, and the other 16-bit value would not be a surrogate code.  Since
    #    surrogate codes must be used in pairs, that makes this byte sequence an invalid encoding for UTF-16 as well.
    # 5. Interpreting the bytes as UCS-2 would also be invalid, because the surrogate code point is not a valid Unicode
    #    character code point, and the other 16-bit value would be a code point in the range of U+E000 to U+EFFF, which
    #    is entirely contained within the Unicode Private Use Area code point range of U+E000 to U+F8FF.
    # 6. Interpreting the bytes as UTF-32 or UCS-4 would also be invalid, because it would represent a code point far
    #    outside the range of valid character code points from U+0000 to U+10FFFF.
    # 7. All of these guarantees for 2-byte encodings (UTF-16 and UCS-2) and 4-byte encodings (UTF-32 and UCS-4) still
    #    hold true for both big-endian and little-endian interpretations, and regardless of byte alignment, because the
    #    high-order bytes of each of the special code point ranges (U+DC00 to U+DFFF and U+E000 to U+EFFF) occur twice,
    #    at both even and odd byte offsets.  That makes this algorithm agnostic to endianness.
    #
    # However, note that this algorithm was carefully designed to meet the above guarantees for THIS particular author.
    # Attempting to use this exact algorithm with different author initials would almost certainly fail.
    #
    my $signature = pack "B32", sprintf "11011%3s111%1s%02b%02b111%1s%04b%04b%04b",
      $xxx, $y, $major & 0x03, $minor >> 4, $z, $minor & 0x0f, map hex, @initials;

    # Swap bytes for major version numbers higher than version 4, effectively encoding a third bit for major version.
    $signature = pack "vv", unpack "nn", $signature if $major > 4;

    # Save the final PDF::Data binary signature in the PDF::Data object.
    $self->{-binary_signature} = $signature;
  }

  # Return the saved binary signature for this PDF.
  return $self->{-binary_signature};
}

# Dump internal structure of PDF file.
sub dump_pdf {
  my ($self, $file, $mode) = @_;

  # Default to standard output.
  $file = "-" if not defined $file or $file eq "";

  # Default to dumping full PDF internal structure.
  $mode //= "";

  # Use "<standard output>" instead of "-" to describe standard output.
  my $filename = ($file // "") =~ s/^-?$/<standard output>/r;

  # Open output file.
  open my $OUT, ">$file" or croak "$filename: $!\n";

  # Data structures already seen.
  my $seen = {};

  # Dump PDF structures.
  printf $OUT "\$pdf = %s;\n", $self->dump_object($self, '$pdf', $seen, 0, $mode) or croak "$filename: $!\n";

  # Close output file.
  close $OUT or croak "$filename: $!\n";

  # Print success message.
  if ($mode eq "outline") {
    print STDERR "Dumped outline of PDF internal structure to file \"$file\".\n\n" unless $file eq "-";
  } else {
    print STDERR "Dumped PDF internal structure to file \"$file\".\n\n" unless $file eq "-";
  }
}

# Dump outline of internal structure of PDF file.
sub dump_outline {
  my ($self, $file) = @_;

  # Call dump_pdf() with outline parameter.
  return $self->dump_pdf($file // "-", "outline");
}

# Merge content streams.
sub merge_content_streams {
  my ($self, $streams) = @_;

  # Make sure content is an array.
  return $streams unless is_array $streams;

  # Remove extra trailing space from streams.
  foreach my $stream (@{$streams}) {
    die unless is_stream $stream;
    $stream->{-data} //= "";
    $stream->{-data} =~ s/(?<=$s) \z//;
  }

  # Concatenate stream data and calculate new length.
  my $merged = { -data => join("", map { $_->{-data}; } @{$streams}) };
  $merged->{Length} = length($merged->{-data});

  # Return merged content stream.
  return $merged;
}

# Find bounding box for a content stream.
sub find_bbox {
  my ($self, $content_stream, $new) = @_;

  # Get data from stream, if necessary.
  $content_stream = $content_stream->{-data} // "" if is_stream $content_stream;

  # Split content stream into lines.
  my @lines = grep { $_ ne ""; } split /\n/, $content_stream;

  # Bounding box.
  my ($left, $bottom, $right, $top);

  # Regex to match a number.
  my $num = qr/-?\d+(?:\.\d+)?/;

  # Determine bounding box from content stream.
  foreach (@lines) {
    # Skip neutral lines.
    next if m{^(?:/Figure <</MCID \d >>BDC|/PlacedGraphic /MC\d BDC|EMC|/GS\d gs|BX /Sh\d sh EX Q|[Qqh]|W n|$num $num $num $num $num $num cm)$s*$}o;

    # Capture coordinates from drawing operations to calculate bounding box.
    my (@x, @y);
    if (my ($x1, $y1, $x2, $y2, $x3, $y3) = /^($num) ($num) (?:[ml]|($num) ($num) (?:[vy]|($num) ($num) c))$/) {
      @x = ($x1, $x2, $x3);
      @y = ($y1, $y2, $y3);
    } elsif (my ($x, $y, $width, $height) = /^($num) ($num) ($num) ($num) re$/) {
      @x = ($x, $x + $width);
      @y = ($y, $y + $height);
    } else {
      croak "Parse error: Content line \"$_\" not recognized!\n";
    }

    foreach my $x (@x) {
      $left  = $x if not defined $left  or $x < $left;
      $right = $x if not defined $right or $x > $right;
    }

    foreach my $y (@y) {
      $bottom = $y if not defined $bottom or $y < $bottom;
      $top    = $y if not defined $top    or $y > $top;
    }
  }

  # Print bounding box and rectangle.
  my $width  = $right - $left;
  my $height = $top   - $bottom;
  print STDERR "Bounding Box: $left $bottom $right $top\nRectangle: $left $bottom $width $height\n\n";

  # Return unless generating a new bounding box.
  return unless $new;

  # Update content stream.
  for ($content_stream) {
    # Update coordinates in drawing operations.
    s/^($num) ($num) ([ml])$/join " ", $self->round($1 - $left, $2 - $bottom), $3/egm;
    s/^($num) ($num) ($num) ($num) ([vy])$/join " ", $self->round($1 - $left, $2 - $bottom, $3 - $left, $4 - $bottom), $5/egm;
    s/^($num) ($num) ($num) ($num) ($num) ($num) (c)$/join " ", $self->round($1 - $left, $2 - $bottom, $3 - $left, $4 - $bottom, $5 - $left, $6 - $bottom), $7/egm;
    s/^($num $num $num $num) ($num) ($num) (cm)$/join " ", $1, $self->round($2 - $left, $3 - $bottom), $4/egm;
  }

  # Return content stream.
  return $content_stream;
}

# Make a new bounding box for a content stream.
sub new_bbox {
  my ($self, $content_stream) = @_;

  # Call find_bbox() with "new" parameter.
  $self->find_bbox($content_stream, 1);
}

# Generate timestamp in PDF internal format.
sub timestamp {
  my ($self, $time) = @_;

  $time //= time;
  my @time = localtime $time;
  my $tz = $time[8] * 60 - mktime(gmtime 0) / 60;
  return sprintf "(D:%s%+03d'%02d')", strftime("%Y%m%d%H%M%S", @time), $tz / 60, abs($tz) % 60;
}

# Round numeric values to 12 significant digits to avoid floating-point rounding error and remove trailing zeroes.
sub round {
  my ($self, @numbers) = @_;

  @numbers = map { sprintf("%.12f", sprintf("%.12g", $_ || 0)) =~ s/\.?0+$//r; } @numbers;
  return wantarray ? @numbers : $numbers[0];
}

# Concatenate a transformation matrix with an original matrix, returning a new matrix.
sub concat_matrix {
  my ($self, $transform, $orig) = @_;

  return [$self->round(
    $transform->[0] * $orig->[0] + $transform->[1] * $orig->[2],
    $transform->[0] * $orig->[1] + $transform->[1] * $orig->[3],
    $transform->[2] * $orig->[0] + $transform->[3] * $orig->[2],
    $transform->[2] * $orig->[1] + $transform->[3] * $orig->[3],
    $transform->[4] * $orig->[0] + $transform->[5] * $orig->[2] + $orig->[4],
    $transform->[4] * $orig->[1] + $transform->[5] * $orig->[3] + $orig->[5],
  )];
}

# Calculate the inverse of a matrix, if possible.
sub invert_matrix {
  my ($self, $matrix) = @_;

  # Calculate the determinant of the matrix.
  my $det = $self->round($matrix->[0] * $matrix->[3] - $matrix->[1] * $matrix->[2]);

  # If the determinant is zero, then the matrix is not invertible.
  return if $det == 0;

  # Return the inverse matrix.
  return [$self->round(
     $matrix->[3] / $det,
    -$matrix->[1] / $det,
    -$matrix->[2] / $det,
     $matrix->[0] / $det,
    ($matrix->[2] * $matrix->[5] - $matrix->[3] * $matrix->[4]) / $det,
    ($matrix->[1] * $matrix->[4] - $matrix->[0] * $matrix->[5]) / $det,
  )];
}

# Create a transformation matrix to translate the origin of the coordinate system to the specified coordinates.
sub translate {
  my ($self, $x, $y) = @_;

  # Return a translate matrix.
  return [$self->round(1, 0, 0, 1, $x, $y)];
}

# Create a transformation matrix to scale the coordinate space by the specified horizontal and vertical scaling factors.
sub scale {
  my ($self, $x, $y) = @_;

  # Return a scale matrix.
  return [$self->round($x, 0, 0, $y, 0, 0)];
}

# Create a transformation matrix to rotate the coordinate space counterclockwise by the specified angle (in degrees).
sub rotate {
  my ($self, $angle) = @_;

  # Calculate the sine and cosine of the angle.
  my $sin = sin($angle * pi / 180);
  my $cos = cos($angle * pi / 180);

  # Return a rotate matrix.
  return [$self->round($cos, $sin, -$sin, $cos, 0, 0)];
}

# Validate PDF structure.
sub validate {
  my ($self) = @_;

  # Catch validation errors.
  eval {
    # Make sure document catalog exists and has the correct type.
    $self->validate_key("Root", "Type", "/Catalog", "document catalog");

    # Make sure page tree root node exists, has the correct type, and has no parent.
    $self->validate_key("Root/Pages", "Type", "/Pages", "page tree root");
    $self->validate_key("Root/Pages", "Parent", undef,  "page tree root");

    # Validate page tree.
    $self->validate_page_tree("Root/Pages", $self->{Root}{Pages});
  };

  # Check for validation errors.
  if ($@) {
    # Make validation errors fatal if -validate flag is set.
    if ($self->{-validate}) {
      croak $@;
    } else {
      carp $@;
    }
  }

  # Return this instance.
  return $self;
}

# Validate page tree.
sub validate_page_tree {
  my ($self, $path, $page_tree_node) = @_;

  # Count of leaf nodes (page objects) under this page tree node.
  my $count = 0;

  # Validate children.
  is_array(my $kids = $page_tree_node->{Kids}) or croak join(": ", $self->file || (), "Error: $path\->{Kids} must be an array!\n");
  for (my $i = 0; $i < @{$kids}; $i++) {
    is_hash(my $kid = $kids->[$i]) or croak join(": ", $self->file || (), "Error: $path\[$i] must be be a hash!\n");
    $kid->{Type} or croak join(": ", $self->file || (), "Error: $path\[$i]->{Type} is a required field!\n");
    if ($kid->{Type} eq "/Pages") {
      $count += $self->validate_page_tree("$path\[$i]", $kid);
    } elsif ($kid->{Type} eq "/Page") {
      $self->validate_page("$path\[$i]", $kid);
      $count++;
    } else {
      croak join(": ", $self->file || (), "Error: $path\[$i]->{Type} must be /Pages or /Page!\n");
    }
  }

  # Validate resources, if any.
  $self->validate_resources("$path\->{Resources}", $page_tree_node->{Resources}) if is_hash($page_tree_node->{Resources});

  # Fix leaf node count if wrong.
  if (($page_tree_node->{Count} || 0) != $count) {
    warn join(": ", $self->file || (), "Warning: Fixing: $path\->{Count} = $count\n");
    $page_tree_node->{Count} = $count;
  }

  # Return leaf node count.
  return $count;
}

# Validate page object.
sub validate_page {
  my ($self, $path, $page) = @_;

  if (my $contents = $page->{Contents}) {
    $contents = $self->merge_content_streams($contents) if is_array($contents);
    is_stream($contents) or croak join(": ", $self->file || (), "Error: $path\->{Contents} must be an array or stream!\n");
    $contents->{-data} //= "";
    $self->validate_content_stream("$path\->{Contents}", $contents);
  }

  # Validate resources, if any.
  $self->validate_resources("$path\->{Resources}", $page->{Resources}) if is_hash($page->{Resources});
}

# Validate resources.
sub validate_resources {
  my ($self, $path, $resources) = @_;

  # Validate XObjects, if any.
  $self->validate_xobjects("$path\{XObject}", $resources->{XObject}) if is_hash($resources->{XObject});
}

# Validate form XObjects.
sub validate_xobjects {
  my ($self, $path, $xobjects) = @_;

  # Validate each form XObject.
  foreach my $name (sort keys %{$xobjects}) {
    $self->validate_xobject("$path\{$name}", $xobjects->{$name});
  }
}

# Validate a single XObject.
sub validate_xobject {
  my ($self, $path, $xobject) = @_;

  # Make sure the XObject is a stream.
  is_stream($xobject) or croak join(": ", $self->file || (), "Error: $path must be a content stream!\n");
  $xobject->{-data} //= "";

  # Validate the content stream, if this is a form XObject.
  $self->validate_content_stream($path, $xobject) if $xobject->{Subtype} eq "/Form";

  # Validate resources, if any.
  $self->validate_resources("$path\{Resources}", $xobject->{Resources}) if is_hash($xobject->{Resources});
}

# Validate content stream.
sub validate_content_stream {
  my ($self, $path, $stream) = @_;

  # Make sure the content stream can be parsed.
  local($self->{-indirect_objects}) = {};
  my @objects = eval { $self->parse_objects(\($stream->{-data} //= ""), 0); };
  croak join(": ", $self->file || (), "Error: $path: $@") if $@;

  # Minify content stream if requested.
  if ($self->should_minify($stream)) {
    # Enable top-level minify flag for stream-level minify flag.
    local $self->{-minify} = 1;
    $self->minify_content_stream($stream, \@objects);
  }
}

# Minify content stream.
sub minify_content_stream {
  my ($self, $stream, $objects) = @_;

  # Parse object stream if necessary.
  local($self->{-indirect_objects}) = {};
  $objects ||= [ $self->parse_objects(\($stream->{-data} //= ""), 0) ];

  # Generate new content stream from objects.
  $stream->{-data} = $self->generate_content_stream($objects);

  # Recalculate stream length.
  $stream->{Length} = length $stream->{-data};

  # Sanity check.
  die "Content stream serialization failed"
    if dump([map {$_->{data}} @{$objects}]) ne
       dump([map {$_->{data}} $self->parse_objects(\($stream->{-data} //= ""), 0)]);
}

# Generate new content stream from objects.
sub generate_content_stream {
  my ($self, $objects) = @_;

  # Generated content stream.
  my $stream = "";

  # Loop across parsed objects.
  foreach my $object (@{$objects}) {
    # Check parsed object type.
    if ($object->{type} eq "dict") {
      # Serialize dictionary.
      $self->serialize_dictionary(\$stream, $object->{data});
    } elsif ($object->{type} eq "array") {
      # Serialize array.
      $self->serialize_array(\$stream, $object->{data});
    } elsif ($object->{type} eq "image") {
      # Serialize inline image data.
      $self->serialize_image(\$stream, $object->{data});
    } else {
      # Serialize string or other token.
      $self->serialize_object(\$stream, $object->{data});
    }
  }

  # Return generated content stream.
  return $stream;
}

# Serialize a hash as a dictionary object.
sub serialize_dictionary {
  my ($self, $stream, $hash) = @_;

  # Serialize the hash key-value pairs.
  my @pairs = %{$hash};
  ${$stream} .= "<<";
  for (my $i = 0; $i < @pairs; $i++) {
    if ($i % 2) {
      if (is_hash($pairs[$i])) {
        $self->serialize_dictionary($stream, $pairs[$i]);
      } elsif (is_array($pairs[$i])) {
        $self->serialize_array($stream, $pairs[$i]);
      } else {
        $self->serialize_object($stream, $pairs[$i]);
      }
    } else {
      ${$stream} .= "/$pairs[$i]";
    }
  }
  ${$stream} .= ">>";
}

# Serialize an array.
sub serialize_array {
  my ($self, $stream, $array) = @_;

  # Serialize the array values.
  ${$stream} .= "[";
  foreach my $obj (@{$array}) {
    if (is_hash($obj)) {
      $self->serialize_dictionary($stream, $obj);
    } elsif (is_array($obj)) {
      $self->serialize_array($stream, $obj);
    } else {
      $self->serialize_object($stream, $obj);
    }
  }
  ${$stream} .= "]";
}

# Append the serialization of inline image data to the generated content stream.
sub serialize_image {
  my ($self, $stream, $image) = @_;

  # Append inline image data between ID (Image Data) and EI (End Image) operators.
  ${$stream} .= "\nID\n$image\nEI\n";
}

# Append the serialization of an object to the generated content stream.
sub serialize_object {
  my ($self, $stream, $object) = @_;

  # Strip leading/trailing whitespace from object if minifying.
  if ($self->{-minify}) {
    $object =~ s/^$s+//;
    $object =~ s/$s+$//;
  }

  # Wrap the line if line length would exceed 255 characters.
  ${$stream} .= "\n" if length(${$stream}) - (rindex(${$stream}, "\n") + 1) + length($object) >= 255;

  # Add a space if necessary.
  ${$stream} .= " " unless ${$stream} =~ /(^|[$ss)>\[\]{}])$/ or $object =~ /^[$ss()<>\[\]{}\/%]/;

  # Add the serialized object.
  ${$stream} .= $object;
}

# Validate the specified hash key value.
sub validate_key {
  my ($self, $hash, $key, $value, $label) = @_;

  # Create the hash if necessary.
  $hash = $_[1] = {} unless $hash;

  # Get the hash node from the PDF structure by path, if necessary.
  $hash = $self->get_hash_node($hash) unless is_hash $hash;

  # Make sure the hash key has the correct value.
  if (defined $value and (not defined $hash->{$key} or $hash->{$key} ne $value)) {
    warn join(": ", $self->file || (), "Warning: Fixing $label: {$key} $hash->{$key} -> $value\n") if $hash->{$key};
    $hash->{$key} = $value;
  } elsif (not defined $value and exists $hash->{$key}) {
    warn join(": ", $self->file || (), "Warning: Deleting $label: {$key} $hash->{$key}\n") if $hash->{$key};
    delete $hash->{$key};
  }

  # Return this instance.
  return $self;
}

# Get a hash node from the PDF structure by path.
sub get_hash_node {
  my ($self, $path) = @_;

  # Split the path.
  my @path = split /\//, $path;

  # Find the hash node with the specified path, creating nodes if necessary.
  my $hash = $self;
  foreach my $key (@path) {
    $hash->{$key} ||= {};
    $hash = $hash->{$key};
  }

  # Return the hash node.
  return $hash;
}

# Parse PDF objects into Perl representations.
sub parse_objects {
  my ($self, $data, $offset_arg) = @_;
  my $length;
  our $offset;

  # Alias local $_ variable to $data or ${$data}.
  local($_) = "";
  *_ = ref($data) eq "SCALAR" ? $data : \$data;

  # Alias local $offset variable to $offset_arg or ${$offset_arg}.
  local($offset) = "";
  *offset = ref $offset_arg ? $offset_arg : \$offset_arg;

  # Parsed PDF objects.
  my @objects;

  # Set starting position for matching \G in regular expressions.
  pos = $offset;

  # Parse PDF objects in input string.
  while (m{\G((?>$ws*))(?:                                  # Leading whitespace/comments, if any.                        ($1)
    (/((?:[^$ss()<>\[\]{}/%\#]+|\#(?!00)[0-9A-Fa-f]{2})*))  # Name object:                           /Name                ($2, $3)
    |(([+-]?(?=\.?\d)\d*)\.?\d*)                            # Real number:                           [+-]999.999          ($4)
                                                            # Integer:                               [+-]999              ($5)
    (?:$ws+(\d)$ws+(?:(R)|(obj)))?                          # Indirect reference:                    999 0 R              ($5, $6, $7)
                                                            # Indirect object:                       999 0 obj            ($5, $6, $8)
    |(>>|\])                                                # End of dictionary/array:               >> or ]              ($9)
    |(<<)                                                   # Dictionary:                            <<...>>              ($10)
    |(\[)                                                   # Array:                                 [...]                ($11)
    |(\((?:(?>[^\\()]+)|\\.|(?-1))*\))                      # String literal (with nested parens):   (...)                ($12)
    |startxref$ws+(\d+)                                     # Start of cross-reference table/stream: startxref 999        ($13)
    |(endobj)                                               # Indirect object definition:            999 0 obj ... endobj ($14)
    |(stream)                                               # Stream content:                        stream ... endstream ($15)
    |(ID)(?s:$s(.*?)(?:\r\n|$s)?EI$s)?                      # Inline image data:                     ID ... EI            ($16, $17)
    |(xref)                                                 # Cross-reference table:                 xref                 ($18)
    |(true|false)                                           # Boolean:                               true or false        ($19)
    |(null)                                                 # Null object:                           null                 ($20)
    |([^$ss()<>\[\]{}/%]+)                                  # Other token:                           TOKEN                ($21)
    |<([0-9A-Fa-f$ss]*)>                                    # Hexadecimal string literal:            <...>                ($22)
    |(\z)                                                   # End of file.                                                ($23)
    |([^\r\n]*))                                            # Parse error.                                                ($24)
  }xgco) {
    # Determine offset and length of match.
    ($offset, $length) = ($+[1], $+[0] - $+[1]);

    # Process matching regular expression captures.
    if (defined $2) {                                         # Name object: /Name ($2, $3)
      my ($token, $name) = ($2, $3);
      $name =~ s/\#([0-9A-Fa-f]{2})/chr(hex($1))/geo if $self->{-pdf_version} >= 1.2;

      push @objects, {
        data   => $token,
        type   => "name",
        name   => $name,
        offset => $offset,
        length => $length,
      };
    } elsif (defined $4 and not defined $6) {                 # Integer/real number: [+-]999[.999] ($4, $5)
      push @objects, {
        data   => $4,
        type   => ($4 eq $5 ? "int" : "real"),
        offset => $offset,
        length => $length,
      };
    } elsif (defined $7) {                                    # Indirect reference: 999 0 R ($5, $6, $7)
      my ($type, $id) = ($7, join("-", $5, $6 || ()));
      my $object = $self->{-indirect_objects}{$id};

      if ($object) {
        $object = { %{$object} };
      } else {
        $object = {
          data   => \$id,
          type   => "R",
          offset => $offset,
          length => $length,
        };
        push @{$self->{-unresolved_refs}{$id}}, \$object->{data};
      }

      push @objects, $object;
    } elsif (defined $8) {                                    # Indirect object: 999 0 obj ($5, $6, $8)
      my ($type, $id) = ($8, join("-", $5, $6 || ()));

      push @objects, {
        data   => $id,
        type   => $type,
        offset => $offset,
        length => $length,
      };
    } elsif (defined $9) {                                    # End of dictionary/array: >> or ] ($9)
      $offset = pos;

      push @objects, {
        data   => $9,
        type   => "token",
        offset => $offset,
        length => $length,
      };

      last;
    } elsif (defined $10) {                                   # Dictionary: <<...>> ($10)
      my $dict_offset = $offset;

      $offset = pos;
      my @pairs = $self->parse_objects($data, \$offset);

      my $token = pop @pairs
        or croak join(": ", $self->file || (), "Byte offset $dict_offset: Parse error: \"<<\" token found without matching \">>\" token!\n");
      $token->{data} eq ">>"
        or croak join(": ", $self->file || (), "Byte offset $dict_offset: Parse error: \">>\" token found without matching \"<<\" token!\n");

      my %dict;
      for (my $i = 0; $i < @pairs; $i += 2) {
        my ($key, $value) = ($pairs[$i]{name}, $pairs[$i + 1]{data});
        $key   // croak join(": ", $self->file || (), "Byte offset $pairs[$i]{offset}: Dictionary key \"$pairs[$i]{data}\" is not a name!\n");
        $value // croak join(": ", $self->file || (), "Byte offset $dict_offset: Parse error: Missing value before \">>\" token!\n");

        $dict{$key} = $value;

        push @{$self->{-unresolved_refs}{${$value}}}, \$dict{$key} if ref $value and reftype($value) eq "SCALAR";
      }

      my $object = {
        data   => \%dict,
        type   => "dict",
        offset => $dict_offset,
        length => pos() - $dict_offset,
      };

      if (@objects and $objects[-1]{type} eq "token" and $objects[-1]{data} eq "trailer") {
        $object->{type} = "trailer";
        pop @objects;
        push @{$self->{-trailers}}, $object;
      }

      push @objects, $object;
    } elsif (defined $11) {                                   # Array: [...] ($11)
      my $array_offset = $offset;

      $offset = pos;
      my @array_objects = $self->parse_objects($data, \$offset);

      my $token = pop @array_objects
        or croak join(": ", $self->file || (), "Byte offset $array_offset: Parse error: \"[\" token found without matching \"]\" token!\n");
      $token->{data} eq "]"
        or croak join(": ", $self->file || (), "Byte offset $array_offset: Parse error: \"]\" token found without matching \"[\" token!\n");

      my @array = map $_->{data}, @array_objects;

      for (my $i = 0; $i < @array; $i++) {
        push @{$self->{-unresolved_refs}{${$array[$i]}}}, \$array[$i] if ref $array[$i] and reftype($array[$i]) eq "SCALAR";
      }

      push @objects, {
        data   => \@array,
        type   => "array",
        offset => $array_offset,
        length => pos() - $array_offset,
      };
    } elsif (defined $12) {                                   # String literal (with nested parens): (...) ($12)
      my $string = $12;
      $string =~ s/\\$n//go;
      $string =~ s/$n/\n/go;

      push @objects, {
        data   => $string,
        type   => "string",
        offset => $offset,
        length => $length,
      };
    } elsif (defined $13) {                                   # Start of cross-reference table/stream: startxref 999 ($13)
      push @objects, {
        data   => $13,
        type   => "startxref",
        offset => $offset,
        length => $length,
      };
    } elsif (defined $14) {                                   # Indirect object definition: 999 0 obj ... endobj ($14)
      my ($id, $object) = splice @objects, -2;

      $id->{type} eq "obj" or croak join(": ", $self->file || (), "Byte offset $offset: Invalid indirect object definition!\n");
      $object->{id}                                     = $id->{data};
      $self->{-indirect_objects}{$id->{data}}           = $object;
      $self->{-indirect_objects}{offset}{$id->{offset}} = $object;
      push @objects, $object;

      if (my $refs = delete $self->{-unresolved_refs}{$id->{data}}) {
        foreach my $ref (@{$refs}) {
          ${$ref} = $object->{data};
        }
      }
    } elsif (defined $15) {                                   # Stream content: stream ... endstream ($15)
      my ($id, $stream) = @objects[-2,-1];

      $stream->{type} eq "dict" or croak join(": ", $self->file || (), "Byte offset $offset: Stream dictionary missing!\n");
      $stream->{type} = "stream";
      $id->{type} eq "obj" or croak join(": ", $self->file || (), "Byte offset $offset: Invalid indirect object definition!\n");

      # Save cross-reference streams with trailer dictionaries.
      push @{$self->{-trailers}}, $stream if ($stream->{data}{Type} // "") eq "/XRef";

      $_ = $_->{data} for $id, $stream;
      defined(my $length = $stream->{Length})
        or carp join(": ", $self->file || (), "Byte offset $offset: Stream #$id: Stream length not found in metadata!\n");
      /\G\r?\n/gc
        or die join(": ", $self->file || (), "Byte offset " . pos . ": Stream #$id: Parsing error!\n");

      # Save the starting offset for the stream.
      my $pos = pos;

      # If the stream length is declared, make sure it is valid.
      if (defined $length && !ref($length)) {
        pos = $pos + $length;
        undef $length unless /\G($s*endstream$ws+)/gco;
        pos = $pos;
      }

      # If the declared stream length is missing or invalid, determine the shortest possible length to make the stream valid.
      unless (defined($length) && !ref($length)) {
        if (/\G((?>(?:[^e]+|(?!endstream$s)e)*))endstream$s/gc) {
          $length = $+[1] - $-[1];
        } else {
          croak join(": ", $self->file || (), "Byte offset $offset: Stream #$id: Invalid stream definition!\n");
        }
      }

      $stream->{-data}    = substr($_, $pos, $length) // "";
      $stream->{-id}      = $id;
      $stream->{-offset}  = $offset;
      $stream->{-length}  = $length;
      $stream->{Length} //= $length;

      push @{$self->{-streams}}, $stream;

      $offset = pos = $pos + $length;
      /\G$s*endstream$ws+/gco
        or die join(": ", $self->file || (), "Byte offset $offset: Stream #$id: Parsing error!\n");

      $self->filter_stream($stream) if $stream->{Filter};

      # Parse object streams.
      $self->parse_object_stream($stream) if ($stream->{Type} // "") eq "/ObjStm";
    } elsif (defined $16) {                                   # Inline image data: ID ... EI ($16, $17)
      my $image = $17 or croak join(": ", $self->file || (), "Byte offset $offset: Invalid inline image data!\n");

      # TODO: Apply encoding filters?

      push @objects, {
        data   => $image,
        type   => "image",
        offset => $offset,
        length => $length,
      };
    } elsif (defined $18) {                                   # Cross-reference table: xref ($18)
      # Parse one or more cross-reference subsections.
      while (/\G$ws*(\d+)$ws+(\d+)$n/gco) {
        my ($first, $count) = ($1, $2);

        for (my $i = 0; $i < $count; $i++) {
          if (/\G(\d{10})\ (\d{5})\ ([fn])(?:\ [\r\n]|\r\n)/gco) {
            # my ($offset, $generation, $keyword) = ($1, $2, $3);
            # my $id = $first + $i
            # my $id = join("-", $first + $i, $generation || ());
            # $xref->{$id} = int($offset);
          } else {
            carp join(": ", $self->file || (), "Byte offset " . pos . ": Invalid cross-reference table!\n");
          }
        }
      }
    } elsif (defined $19) {                                   # Boolean: true or false ($19)
      push @objects, {
        data   => $19,
        type   => "bool",
        bool   => $19 eq "true",
        offset => $offset,
        length => $length,
      };
    } elsif (defined $20) {                                   # Null object: null ($20)
      push @objects, {
        data   => $20,
        type   => "null",
        offset => $offset,
        length => $length,
      };
    } elsif (defined $21) {                                   # Other token: TOKEN ($21)
      push @objects, {
        data   => $21,
        type   => "token",
        offset => $offset,
        length => $length,
      };
    } elsif (defined $22) {                                   # Hexadecimal string literal: <...> ($22)
      my $hex_string = lc($22);

      $hex_string =~ s/$s+//go;
      $hex_string .= "0" if length($hex_string) % 2 == 1;

      push @objects, {
        data   => "<$hex_string>",
        type   => "hex",
        offset => $offset,
        length => $length,
      };
    } elsif (defined $23) {                                   # End of file. ($23)
      last;
    } else {                                                  # Parse error: ??? ($24)
      croak join(": ", $self->file || (), "Byte offset $offset: Parse error on input: \"$24\"\n");
    }
  }

  # Return parsed PDF objects.
  return @objects;
}

# Parse PDF objects from standalone PDF data.
sub parse_data {
  my ($self, $data) = @_;

  # Parse PDF objects from data.
  local($self->{-indirect_objects}) = {};
  my @objects = $self->parse_objects(\($data //= ""), 0);

  # Discard parser metadata.
  @objects = map { $_->{data}; } @objects;

  # Return parsed objects.
  return wantarray ? @objects : $objects[0];
}

# Parse an object stream.
sub parse_object_stream {
  my ($self, $stream) = @_;

  # Alias local $_ variable to the stream data.
  local($_) = "";
  *_ = \$stream->{-data};

  my $n = $stream->{N}
    or croak join(": ", $self->file || (), "Byte offset $stream->{-offset}: Stream #$stream->{-id}: Object count not found in object stream metadata!\n");
  $n =~ /^\d+$/
    or croak join(": ", $self->file || (), "Byte offset $stream->{-offset}: Stream #$stream->{-id}: Object count \"$n\" in object stream metadata is not an integer!\n");
  my $first = $stream->{First}
    or croak join(": ", $self->file || (), "Byte offset $stream->{-offset}: Stream #$stream->{-id}: First object offset not found in object stream metadata!\n");
  $first =~ /^\d+$/
    or croak join(": ", $self->file || (), "Byte offset $stream->{-offset}: Stream #$stream->{-id}: First object offset \"$first\" in object stream metadata is not an integer!\n");
  my $extends = $stream->{Extends};
  not defined $extends or (ref $extends and reftype($extends) eq "SCALAR") or is_stream($extends)
    or croak join(": ", $self->file || (), "Byte offset $stream->{-offset}: Stream #$stream->{-id}: Extends argument in object stream metadata is invalid!\n");

  pos = 0;
  my @pairs;
  while (@pairs < $n) {
    my $stream_offset = pos;
    if (/\G(\d+)$s+(\d+)$s+/gco) {
      push @pairs, [$1, $2];
    } else {
      croak join(": ", $self->file || (), "Byte offset $stream->{-offset}: Stream #$stream->{-id}: Stream byte offset $stream_offset",
        sprintf("Object stream should start with %d pair%s of integers; found %d pair%s of integers!\n", $n, $n == 1 ? "" : "s", scalar @pairs, @pairs == 1 ? "" : "s"));
    }
  }

  $first //= pos;
  my @objects = $self->parse_objects(\$stream->{-data}, $first);

  foreach my $pair (@pairs) {
    my ($id, $offset) = @{$pair};
    $offset += $first;
    my $object = shift @objects
      or croak join(": ", $self->file || (), "Byte offset $stream->{-offset}: Stream #$stream->{-id}: Object stream data is truncated; object #$id at stream offset $offset not found!\n");

    $offset = $object->{offset};
    $object->{type} ne "R"
      or carp join(": ", $self->file || (), "Byte offset $stream->{-offset}: Stream #$stream->{-id}: Compressed object #$id at stream offset $offset is an illegal indirect object reference!\n");

    $object->{id} = $id;
    $self->{-indirect_objects}{$id} = $object;

    if (my $refs = delete $self->{-unresolved_refs}{$id}) {
      foreach my $ref (@{$refs}) {
        ${$ref} = $object->{data};
      }
    }

    push @{$stream->{-objects}}, $object;
  }
}

# Filter stream data.
sub filter_stream {
  my ($self, $stream) = @_;

  # Get stream filters, if any.
  my @filters = $stream->{Filter} ? is_array $stream->{Filter} ? @{$stream->{Filter}} : ($stream->{Filter}) : ();

  # Decompress stream data if necessary.
  if ($filters[0] eq "/FlateDecode") {
    # Remember that this stream was compressed.
    $stream->{-compress} = 1;

    # Decompress the stream.
    my $zlib = new Compress::Raw::Zlib::Inflate;
    my $output;
    my $status = $zlib->inflate($stream->{-data}, $output);
    if ($status == Z_OK or $status == Z_STREAM_END) {
      $stream->{-data}  = $output;
      $stream->{Length} = length $output;
    } else {
      croak join(": ", $self->file || (), "Object #$stream->{-id}: Stream inflation failed! ($zlib->msg)\n");
    }

    # Stream is no longer compressed; remove /FlateDecode filter.
    shift @filters;

    # Preserve remaining filters, if any.
    if (@filters > 1) {
      $stream->{Filter} = \@filters;
    } elsif (@filters) {
      $stream->{Filter} = shift @filters;
    } else {
      delete $stream->{Filter};
    }
  }
}

# Compress stream data.
sub compress_stream {
  my ($self, $stream) = @_;

  # Get stream filters, if any.
  my @filters = $stream->{Filter} ? is_array $stream->{Filter} ? @{$stream->{Filter}} : ($stream->{Filter}) : ();

  # Return a new stream so the in-memory copy remains uncompressed to work with.
  my $new_stream = { %{$stream} };
  $new_stream->{-data} = "";
  my ($zlib, $status) = Compress::Raw::Zlib::Deflate->new(-Level => 9, -Bufsize => 65536, AppendOutput => 1);
  $zlib->deflate($stream->{-data}, $new_stream->{-data}) == Z_OK or croak join(": ", $self->file || (), "Object #$stream->{-id}: Stream deflation failed! ($zlib->msg)\n");
  $zlib->flush($new_stream->{-data}, Z_FINISH)           == Z_OK or croak join(": ", $self->file || (), "Object #$stream->{-id}: Stream deflation failed! ($zlib->msg)\n");
  $new_stream->{Length} = length $new_stream->{-data};
  $new_stream->{Filter} = @filters ? ["/FlateDecode", @filters] : "/FlateDecode";
  return $new_stream;
}

# Write a single indirect object to PDF file data.
sub write_indirect_object {
  my ($self, $pdf_file_data, $seen, $id, $object) = @_;

  # Save startxref value.
  my $startxref = length(${$pdf_file_data});

  # Write the indirect object header.
  ${$pdf_file_data} .= "$id 0 obj\n";

  # Write the object itself.
  $self->write_object($pdf_file_data, $seen, $object, 0);

  # Write the indirect object trailer.
  ${$pdf_file_data} =~ s/\n?\z/\n/;
  ${$pdf_file_data} .= "endobj\n\n";

  # Return startxref value to use for cross-reference stream.
  return $startxref;
}

# Write all indirect objects to PDF file data.
sub write_indirect_objects {
  my ($self, $pdf_file_data, $seen) = @_;

  # Cache result of helper function.
  my $use_object_streams = $self->should_use_object_streams;

  # Enumerate all indirect objects.
  $self->enumerate_indirect_objects;

  # Cross-reference table data; start with free entry for object number 0.
  my $xrefs = "0000000000 65535 f \n";

  # Create object streams, if enabled.
  $xrefs = $self->create_object_streams($seen) if $use_object_streams;

  # Loop across indirect objects.
  for (my $i = 1; $i <= $#{$self->{-indirect_objects}}; $i++) {
    # Get the indirect object.
    my $object = $self->{-indirect_objects}[$i];

    # Check if using object streams.
    if ($use_object_streams) {
      # Check if this indirect object should be saved as a regular uncompressed object.
      if (substr($xrefs, $i * 7, 1) eq pack('C', 1)) {
        # Update cross-reference stream data for this uncompressed object.
        substr($xrefs, $i * 7 + 1, 4) = pack('N', length(${$pdf_file_data}));
      } else {
        # Skip indirect objects already saved in object streams as compressed objects.
        next;
      }
    } else {
      # Add file offset to cross-reference table.
      $xrefs .= sprintf "%010d 00000 n \n", length(${$pdf_file_data});
    }

    # Write the indirect object itself.
    $self->write_indirect_object($pdf_file_data, $seen, $i, $object) unless $seen->{$object};
  }

  # Check if using object streams.
  if ($use_object_streams) {
    # Write cross-reference stream.
    $self->write_xref_stream($pdf_file_data, $seen, $xrefs);
  } else {
    # Write cross-reference table.
    $self->write_xref_table($pdf_file_data, $seen, $xrefs);
  }

  # Return cross-reference file offsets.
  return $xrefs;
}

# Write cross-reference table.
sub write_xref_table {
  my ($self, $pdf_file_data, $seen, $xrefs) = @_;

  # Add cross-reference table.
  my $size           = @{$self->{-indirect_objects}};
  my $startxref      = length(${$pdf_file_data});
  ${$pdf_file_data} .= "xref\n0 $size\n$xrefs";

  # Save correct size in trailer dictionary.
  $self->{Size} = $size;

  # Write trailer dictionary.
  ${$pdf_file_data} .= "trailer ";
  $self->write_object($pdf_file_data, $seen, $self, 0);

  # Write startxref value.
  ${$pdf_file_data} =~ s/\n?\z/\n/;
  ${$pdf_file_data} .= "startxref\n$startxref\n";
}

# Write cross-reference stream.
sub write_xref_stream {
  my ($self, $pdf_file_data, $seen, $xrefs) = @_;

  # Cross-reference stream data.
  my $id        = @{$self->{-indirect_objects}};
  my $size      = $id + 1;
  my $data      = $xrefs . pack('CNn', 1, length(${$pdf_file_data}), 0);
  my $length    = length $data;

  # Cross-reference stream object doubles as trailer dictionary.
  $self->{-id}       = $id;
  $self->{-data}     = $data;
  $self->{-length}   = $length;
  $self->{-compress} = 1;
  $self->{Length}    = $length;
  $self->{Type}      = "/XRef";
  $self->{Size}      = $size;
  $self->{Index}     = [0, $size];
  $self->{W}         = [1, 4, 2];

  # Save the cross-reference stream object.
  push @{$self->{-indirect_objects}}, $self;

  # Write the cross-reference stream object.
  my $startxref = $self->write_indirect_object($pdf_file_data, $seen, $id, $self);

  # Write startxref value.
  ${$pdf_file_data} =~ s/\n?\z/\n/;
  ${$pdf_file_data} .= "startxref\n$startxref\n";
}

# Create object streams.
sub create_object_streams {
  my ($self, $seen) = @_;

  # Always use minify mode to serialize object streams.
  local $self->{-minify} = 1;

  # Cross-reference stream data; start with free entry for object number 0.
  my $xrefs = pack('CNn', 0, 0, 65535);

  # Object stream data.
  my $pairs   = "";
  my $objects = "";
  my $count   = 0;
  my $extends;

  # Loop across indirect objects.
  for (my $i = 1; $i <= $#{$self->{-indirect_objects}}; $i++) {
    # Get the indirect object.
    my $object = $self->{-indirect_objects}[$i];

    # Skip stream objects and the encryption dictionary (if any).  For Linearized PDF, also skip document catalog and page objects.
    if (is_stream($object) || $object eq ($self->{Encrypt} // "") || ($self->{-linearized} && ($object->{Type} // "") =~ m{^/(Catalog|Pages)$}o)) {
      # Reserve space for cross-reference stream data for this uncompressed object.
      $xrefs .= pack('CNn', 1, 0, 0);

      # Continue to the next indirect object.
      next;
    }

    # Determine object offset from first object.
    my $offset = length $objects;

    # Object stream pair of integers for this object.
    my $pair = "$i $offset";

    # Serialize the object.
    $self->write_object(\$objects, $seen, $object, 0);

    # Check if including this object would cause the uncompressed object stream to exceed 1 MB or index numbers to exceed 16 bits.
    if ($count == 65535 || $count > 0 && length($pairs) + length($pair) + length($objects) + 2 > 1048576) {
      # Finish the current object stream.
      $extends ||= $self->add_object_stream($pairs, substr($objects, 0, $offset), $count, $extends);

      # Save cross-reference stream data for this compressed object.
      $xrefs .= pack('CNn', 2, scalar(@{$self->{-indirect_objects}}), 0);

      # Start a new object stream.
      $pairs   = $pair;
      $objects = substr($objects, $offset + (substr($objects, $offset, 1) eq " " ? 1 : 0));
      $count   = 1;
    } else {
      # Save cross-reference stream data for this compressed object.
      $xrefs .= pack('CNn', 2, scalar(@{$self->{-indirect_objects}}), $count);

      # Add the indirect object to the current object stream.
      $pairs .= " " if $pairs;
      $pairs .= $pair;
      $count++;
    }
  }

  # Add the final object stream, if any.
  if ($count > 0) {
    # Add the object stream.
    $self->add_object_stream($pairs, $objects, $count, $extends);

    # Reserve space for cross-reference stream data for this uncompressed object.
    $xrefs .= pack('CNn', 1, 0, 0);
  }

  # Return cross-reference stream data.
  return $xrefs;
}

# Add a new object stream.
sub add_object_stream {
  my ($self, $pairs, $objects, $count, $extends) = @_;

  # Object stream data.
  my $id     = @{$self->{-indirect_objects}};
  my $data   = "$pairs\n$objects";
  my $length = length $data;

  # Add the new object stream.
  push @{$self->{-indirect_objects}}, {
    -id       => $id,
    -data     => $data,
    -length   => $length,
    -compress => 1,
    Length    => $length,
    Type      => "/ObjStm",
    N         => $count,
    First     => length($pairs) + 1,
    ($extends ? (Extends => $extends) : ()),
  };

  # Return the indirect object ID number of the new object stream.
  return $id;
}

# Enumerate all indirect objects.
sub enumerate_indirect_objects {
  my ($self) = @_;

  # Add top-level PDF indirect objects.
  $self->add_indirect_objects(
    $self->{Root}                 ? $self->{Root}                 : (), # Document catalog
    $self->{Info}                 ? $self->{Info}                 : (), # Document information dictionary (if any)
    $self->{Root}{Dests}          ? $self->{Root}{Dests}          : (), # Named destinations (if any)
    $self->{Root}{Metadata}       ? $self->{Root}{Metadata}       : (), # Document metadata (if any)
    $self->{Root}{Outlines}       ? $self->{Root}{Outlines}       : (), # Document outline hierarchy (if any)
    $self->{Root}{Pages}          ? $self->{Root}{Pages}          : (), # Document page tree
    $self->{Root}{Threads}        ? $self->{Root}{Threads}        : (), # Articles (if any)
    $self->{Root}{StructTreeRoot} ? $self->{Root}{StructTreeRoot} : (), # Document structure tree (if any)
  );

  # Add optional content groups, if any.
  $self->add_indirect_objects(@{$self->{Root}{OCProperties}{OCGs}}) if $self->{Root}{OCProperties};

  # Enumerate shared objects.
  $self->enumerate_shared_objects({}, $self->{Root});

  # Add referenced indirect objects.
  for (my $i = 1; $i <= $#{$self->{-indirect_objects}}; $i++) {
    # Get object.
    my $object = $self->{-indirect_objects}[$i];

    # Check object type.
    if (is_hash $object) {
      # Objects to add.
      my @objects;

      # Hashes to scan.
      my @hashes = $object;

      # Iteratively recurse through hash tree.
      while (@hashes) {
        # Get the next hash.
        $object = shift @hashes;

        # Check each hash key.
        foreach my $key (sort { fc($a) cmp fc($b) || $a cmp $b; } keys %{$object}) {
          if (($object->{Type} // "") eq "/ExtGState" and $key eq "Font" and is_array $object->{Font} and is_hash $object->{Font}{data}) {
            push @objects, $object->{Font}{data};
          } elsif ($key =~ /^(?:Data|First|ID|Last|Next|Obj|Parent|ParentTree|Popup|Prev|Root|StmOwn|Threads|Widths)$/
              or $key =~ /^(?:AN|Annotation|B|C|CI|DocMDP|F|FontDescriptor|I|IX|K|Lock|N|P|Pg|RI|SE|SV|V)$/ and ref $object->{$key} and is_hash $object->{$key}
              or is_hash $object->{$key} and ($object->{$key}{-data} or $object->{$key}{Kids} or ($object->{$key}{Type} // "") =~ /^\/(?:Filespec|Font)$/)
              or ($object->{S} // "") eq "/Thread" and $key eq "D"
              or ($object->{S} // "") eq "/Hide"   and $key eq "T"
          ) {
            push @objects, $object->{$key};
          } elsif ($key =~ /^(?:Annots|B|C|CO|Fields|K|Kids|O|Pages|TrapRegions)$/ and is_array $object->{$key}) {
            push @objects, grep { is_hash $_; } @{$object->{$key}};
          } elsif (is_hash $object->{$key}) {
            push @hashes, $object->{$key};
          }
        }
      }

      # Add the objects found, if any.
      $self->add_indirect_objects(@objects) if @objects;
    }
  }
}

# Enumerate shared objects.
sub enumerate_shared_objects {
  my ($self, $seen, $object) = @_;

  # Add shared indirect objects.
  if ($seen->{$object}++) {
    $self->add_indirect_objects($object) unless $self->{-indirect_objects}[0]{$object};
  } else {
    # Recurse to check entire object tree.
    if (is_hash $object) {
      foreach my $key (sort { fc($a) cmp fc($b) || $a cmp $b; } keys %{$object}) {
        $self->enumerate_shared_objects($seen, $object->{$key}) if ref $object->{$key};
      }
    } elsif (is_array $object) {
      foreach my $obj (@{$object}) {
        $self->enumerate_shared_objects($seen, $obj) if ref $obj;
      }
    }
  }
}

# Add indirect objects.
sub add_indirect_objects {
  my ($self, @objects) = @_;

  # Loop across specified objects.
  foreach my $object (@objects) {
    # Make sure content streams are defined.
    $object->{-data} //= "" if is_stream $object;

    # Check if object exists and is not in the lookup hash yet.
    if (defined $object and not $self->{-indirect_objects}[0]{$object}) {
      # Add the new indirect object to the array.
      push @{$self->{-indirect_objects}}, $object;

      # Save the object ID in the lookup hash, keyed by the object.
      $self->{-indirect_objects}[0]{$object} = $#{$self->{-indirect_objects}};
    }
  }
}

# Check if compression should be used.
sub should_compress {
  my ($self, $stream) = @_;

  $stream ||= {};
  ($self->{-compress} || $stream->{-compress} || $self->{-optimize} || $stream->{-optimize})
    && !($self->{-decompress} || $stream->{-decompress} || $self->{-no_compress} || $stream->{-no_compress} || $self->{-no_optimize} || $stream->{-no_optimize})
}

# Check if minification should be used.
sub should_minify {
  my ($self, $stream) = @_;

  $stream ||= {};
  ($self->{-minify} || $stream->{-minify} || $self->{-optimize} || $stream->{-optimize})
    && !($self->{-no_minify} || $stream->{-no_minify} || $self->{-no_optimize} || $stream->{-no_optimize})
}

# Check if object streams should be used.
sub should_use_object_streams {
  my ($self) = @_;

  ($self->{-use_object_streams} || $self->{-optimize}) && !($self->{-no_object_streams} || $self->{-no_use_object_streams} || $self->{-no_optimize})
}

# Write a direct object to the string of PDF file data.
sub write_object {
  my ($self, $pdf_file_data, $seen, $object, $indent) = @_;

  # Make sure the same object isn't written twice.
  if (ref $object and $seen->{$object}++) {
    croak join(": ", $self->file || (), "Object $object written more than once!\n");
  }

  # Check object type.
  if (not defined $object) {
    die join(": ", $self->file || (), "Object is undefined!\n");
  } elsif (is_hash $object) {
    # For streams, compress the stream or update the length metadata.
    if (is_stream $object) {
      $object->{-data} //= "";
      if ($self->should_compress($object)) {
        $object = $self->compress_stream($object);
      } else {
        $object->{Length} = length $object->{-data};
      }
    }

    # Dictionary object.
    $self->serialize_object($pdf_file_data, "<<\n");
    foreach my $key (sort { fc($a) cmp fc($b) || $a cmp $b; } keys %{$object}) {
      next if $key =~ /^-/;
      my $obj = $object->{$key};
      $self->add_indirect_objects($obj) if is_stream $obj;
      $self->serialize_object($pdf_file_data, join("", " " x ($indent + 2), "/$key "));
      if (not ref $obj) {
        $self->serialize_object($pdf_file_data, "$obj\n");
      } elsif ($self->{-indirect_objects}[0]{$obj}) {
        $self->serialize_object($pdf_file_data, "$self->{-indirect_objects}[0]{$obj} 0 R\n");
      } else {
        $self->write_object($pdf_file_data, $seen, $object->{$key}, ref $object ? $indent + 2 : 0);
      }
    }
    $self->serialize_object($pdf_file_data, join("", " " x $indent, ">>\n"));

    # For streams, write the stream data.
    if (is_stream $object) {
      croak join(": ", $self->file || (), "Stream written as direct object!\n") if $indent;
      my $newline = substr($object->{-data}, -1) eq "\n" ? "" : "\n";
      ${$pdf_file_data} =~ s/\n?\z/\n/;
      ${$pdf_file_data} .= "stream\n$object->{-data}${newline}endstream\n";
    }
  } elsif (is_array $object and not grep { ref $_; } @{$object}) {
    # Array of simple objects.
    if ($self->{-minify}) {
      $self->serialize_array($pdf_file_data, $object);
    } else {
      ${$pdf_file_data} .= "[ @{$object} ]\n";
    }
  } elsif (is_array $object) {
    # Array object.
    $self->serialize_object($pdf_file_data, "[\n");
    my $spaces = " " x ($indent + 2);
    foreach my $obj (@{$object}) {
      $self->add_indirect_objects($obj) if is_stream $obj;
      ${$pdf_file_data} .= $spaces unless $self->{-minify};
      if (not ref $obj) {
        $self->serialize_object($pdf_file_data, $obj);
        $spaces = " ";
      } elsif ($self->{-indirect_objects}[0]{$obj}) {
        $self->serialize_object($pdf_file_data, "$self->{-indirect_objects}[0]{$obj} 0 R\n");
        $spaces = " " x ($indent + 2);
      } else {
        $self->write_object($pdf_file_data, $seen, $obj, $indent + 2);
        $spaces = " " x ($indent + 2);
      }
    }
    ${$pdf_file_data} .= "\n" if $spaces eq " " and not $self->{-minify};
    $self->serialize_object($pdf_file_data, join("", " " x $indent, "]\n"));
  } elsif (ref $object and reftype($object) eq "SCALAR") {
    # Unresolved indirect reference.
    my ($id, $gen) = split /-/, ${$object};
    $gen ||= "0";
    $self->serialize_object($pdf_file_data, join("", " " x $indent, "($id $gen R)\n"));
  } else {
    # Simple object.
    $self->serialize_object($pdf_file_data, join("", " " x $indent, "$object\n"));
  }
}

# Dump PDF object.
sub dump_object {
  my ($self, $object, $label, $seen, $indent, $mode) = @_;

  # Dump output.
  my $output = "";

  # Hash key sort priority.
  my %priority = (
    Type           => -2,
    Version        => -1,
    Root           => 1,
    Pages          => 2,
    PageLabels     => 3,
    Names          => 4,
    Dests          => 5,
    Outlines       => 6,
    Threads        => 7,
    StructTreeRoot => 8,
  );

  # Check mode and object type.
  if ($mode eq "outline") {
    if (ref $object and $seen->{$object}) {
      # Previously-seen object; dump the label.
      $output = "$seen->{$object}";
    } elsif (is_hash $object) {
      # Hash object.
      $seen->{$object} = $label;
      if (is_stream $object and not $object->{Root}) {
        $output = "(Stream)";
      } else {
        $label =~ s/(?<=\w)$/->/;
        my @keys = sort { ($priority{$a} // 0) <=> ($priority{$b} // 0) || fc($a) cmp fc($b) || $a cmp $b; } keys %{$object};
        my $key_len = max map length $_, @keys;
        foreach my $key (@keys) {
          my $obj = $object->{$key};
          next unless ref $obj;
          $output .= sprintf "%s%-${key_len}s => ", " " x ($indent + 2), $key;
          if ($key eq "Annots") {
            $output .= "(Annotations),\n";
          } elsif ($key eq "IDTree") {
            $output .= "(ID Name Tree),\n";
          } elsif ($key eq "Names") {
            $output .= "(Name Tree),\n";
          } elsif ($key eq "Outlines") {
            $output .= "(Document Outline),\n";
          } elsif ($key eq "StructTreeRoot") {
            $output .= "(Structure Hierarchy),\n";
          } else {
            $output .= $self->dump_object($object->{$key}, "$label\{$key\}", $seen, ref $object ? $indent + 2 : 0, $mode) . ",\n";
          }
        }
        if ($output) {
          $output = join("", "{ # $label\n", $output, (" " x $indent), "}");
        } else {
          $output = "{...}";
        }
        $output =~ s/\{ \# \$pdf->\n/\{\n/;
      }
    } elsif (is_array $object and not grep { ref $_; } @{$object}) {
      # Array of simple objects.
      $output = @{$object} > 4 || grep(!/^\d+(?:\.\d+)?$/, @{$object}) ? "[...]" : sprintf "[%s]", join(", ", @{$object});
    } elsif (is_array $object) {
      # Array object.
      for (my $i = 0; $i < @{$object}; $i++) {
        $output .= sprintf "%s%s,\n", " " x ($indent + 2), $self->dump_object($object->[$i], "$label\[$i\]", $seen, $indent + 2, $mode) if ref $object->[$i];
      }
      if ($output =~ /\A$s+(.*?),\n\z/o) {
        $output = "[... $1]";
      } elsif ($output =~ /\n/) {
        $output = join("", "[ # $label\n", $output, (" " x $indent), "]");
      } else {
        $output = "[$output]";
      }
    } elsif (reftype($object) eq "SCALAR") {
      # Unresolved indirect reference.
      my ($id, $gen) = split /-/, ${$object};
      $gen ||= "0";
      $output .= "\"$id $gen R\"";
    }
  } elsif (ref $object and $seen->{$object}) {
    # Previously-seen object; dump the label.
    $output = $seen->{$object};
  } elsif (is_hash $object) {
    # Hash object.
    $seen->{$object} = $label;
    $output = "{ # $label\n";
    $label =~ s/(?<=\w)$/->/;
    my @keys = sort { ($priority{$a} // 0) <=> ($priority{$b} // 0) || fc($a) cmp fc($b) || $a cmp $b; } keys %{$object};
    my $key_len = max map length $_, @keys;
    foreach my $key (@keys) {
      my $obj = $object->{$key};
      $output .= sprintf "%s%-${key_len}s => ", " " x ($indent + 2), $key;
      if ($key eq -data) {
        chomp $obj;
        $output .= $obj =~ /\A(?:<\?xpacket|[\n\t -~]*\z)/ ? "<<'EOF',\n$obj\nEOF\n" : dump($obj) . "\n";
      } elsif (not ref $obj) {
        $output .= dump($obj) . ",\n";
      } else {
        $output .= $self->dump_object($object->{$key}, "$label\{$key\}", $seen, ref $object ? $indent + 2 : 0, $mode) . ",\n";
      }
    }
    $output .= (" " x $indent) . "}";
    $output =~ s/\{ \# \$pdf\n/\{\n/;
  } elsif (is_array $object and not grep { ref $_; } @{$object}) {
    # Array of simple objects.
    $output = sprintf "[%s]", join(", ", map { /^\d+(?:\.\d+)?$/ ? $_ : dump($_); } @{$object});
  } elsif (is_array $object) {
    # Array object.
    $output .= "[ # $label\n";
    my $spaces = " " x ($indent + 2);
    for (my $i = 0; $i < @{$object}; $i++) {
      my $obj = $object->[$i];
      if (ref $obj) {
        $output .= sprintf "%s%s,\n", $spaces, $self->dump_object($obj, "$label\[$i\]", $seen, $indent + 2, $mode);
        $spaces = " " x ($indent + 2);
      } else {
        $output .= $spaces . dump($obj) . ",";
        $spaces = " ";
      }
    }
    $output .= ",\n" if $spaces eq " ";
    $output .= (" " x $indent) . "]";
  } elsif (reftype($object) eq "SCALAR") {
    # Unresolved indirect reference.
    my ($id, $gen) = split /-/, ${$object};
    $gen ||= "0";
    $output .= "\"$id $gen R\"";
  } else {
    # Simple object.
    $output = sprintf "%s%s\n", " " x $indent, dump($object);
  }

  # Return generated output.
  return $output;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

PDF::Data - Manipulate PDF files and objects as data structures

=head1 VERSION

version v1.2.0

=head1 SYNOPSIS

  use PDF::Data;

=head1 DESCRIPTION

This module can read and write PDF files, and represents PDF objects as data
structures that can be readily manipulated.

=head1 METHODS

=head2 new

  my $pdf = PDF::Data->new(-compress => 1, -minify => 1);

Constructor to create an empty PDF::Data object instance.  Any arguments passed
to the constructor are treated as key/value pairs, and included in the C<$pdf>
hash object returned from the constructor.  When the PDF file data is generated,
this hash is written to the PDF file as the trailer dictionary.  However, hash
keys starting with "-" are ignored when writing the PDF file, as they are
considered to be flags or metadata.

For example, C<$pdf-E<gt>{-compress}> is a flag which controls whether or not
streams will be compressed when generating PDF file data.  This flag can be set
in the constructor (as shown above), or set directly on the object.

The C<$pdf-E<gt>{-minify}> flag controls whether or not to save space in the
generated PDF file data by removing comments and extra whitespace from content
streams.  This flag can be used along with C<$pdf-E<gt>{-compress}> to make the
generated PDF file data even smaller, but this transformation is not reversible.

=head2 file

  my $filename = $pdf->file;

Get PDF filename, if any.  Used by many methods for error reporting.

=head2 clone

  my $pdf_clone = $pdf->clone;

Deep copy the entire PDF::Data object itself.

=head2 new_page

  my $page = $pdf->new_page;
  my $page = $pdf->new_page('LETTER');
  my $page = $pdf->new_page(8.5, 11);

Create a new page object with the specified size (in inches).  Alternatively,
certain page sizes may be specified using one of the known keywords: "LETTER"
for U.S. Letter size (8.5" x 11"), "LEGAL" for U.S. Legal size (8.5" x 14"), or
"A0" through "A8" for ISO A-series paper sizes.  The default page size is U.S.
Letter size (8.5" x 11").

=head2 copy_page

  my $copied_page = $pdf->copy_page($page);

Deep copy a single page object.

=head2 append_page

  $page = $pdf->append_page($page);

Append the specified page object to the end of the PDF page tree.

=head2 read_pdf

  my $pdf = PDF::Data->read_pdf($file, %args);

Read a PDF file and parse it with C<$pdf-E<gt>parse_pdf()>, returning a new
object instance.  Any streams compressed with the /FlateDecode filter will be
automatically decompressed.  Unless the C<$pdf-E<gt>{-decompress}> flag is set,
the same streams will also be automatically recompressed again when generating
PDF file data.

=head2 parse_pdf

  my $pdf = PDF::Data->parse_pdf($data, %args);

Used by C<$pdf-E<gt>read_pdf()> to parse the raw PDF file data and create a new
object instance.  This method can also be called directly instead of calling
C<$pdf-E<gt>read_pdf()> if the PDF file data comes another source instead of a
regular file.

=head2 write_pdf

  $pdf->write_pdf($file, $time);

Generate and write a new PDF file from the current state of the PDF::Data
object.

The C<$time> parameter is optional; if not defined, it defaults to the current
time.  If C<$time> is defined but false (zero or empty string), no timestamp
will be set.

The optional C<$time> parameter may be used to specify the modification
timestamp to save in the PDF metadata and to set the file modification timestamp
of the output file.  If not specified, it defaults to the current time.  If a
false value is specified, this method will skip setting the modification time in
the PDF metadata, and skip setting the timestamp on the output file.

=head2 pdf_file_data

  my $pdf_file_data = $document->pdf_file_data($time);

Generate PDF file data from the current state of the PDF data structure,
suitable for writing to an output PDF file.  This method is used by the
C<$pdf-E<gt>write_pdf()> method to generate the raw string of bytes to be
written to the output PDF file.  This data can be directly used (e.g. as a MIME
attachment) without the need to actually write a PDF file to disk.

The optional C<$time> parameter may be used to specify the modification
timestamp to save in the PDF metadata.  If not specified, it defaults to the
current time.  If a false value is specified, this method will skip setting the
modification time in the PDF metadata.

=head2 dump_pdf

  $pdf->dump_pdf($file, $mode);

Dump the PDF internal structure and data for debugging.  If the C<$mode>
parameter is "outline", dump only the PDF internal structure without the data.

=head2 dump_outline

  $pdf->dump_outline($file);

Dump an outline of the PDF internal structure for debugging.  (This method
simply calls the C<$pdf-E<gt>dump_pdf()> method with the C<$mode> parameter
specified as "outline".)

=head2 merge_content_streams

  my $stream = $pdf->merge_content_streams($array_of_streams);

Merge multiple content streams into a single content stream.

=head2 find_bbox

  $pdf->find_bbox($content_stream, $new);

Analyze a content stream to determine the correct bounding box for the content
stream.  The current implementation was purpose-built for a specific use case
and should not be expected to work correctly for most content streams.

The C<$content_stream> parameter may be a stream object or a string containing
the raw content stream data.

The current algorithm breaks the content stream into lines, skips over various
"neutral" lines and examines the coordinates specified for certain PDF drawing
operators: "m" (moveto), "l" (lineto), "v" (curveto, initial point replicated),
"y" (curveto, final point replicated), and "c" (curveto, all points specified).

The minimum and maximum X and Y coordinates seen for these drawing operators are
used to determine the bounding box (left, bottom, right, top) for the content
stream.  The bounding box and equivalent rectangle (left, bottom, width, height)
are printed.

If the C<$new> boolean parameter is set, an updated content stream is generated
with the coordinates adjusted to move the lower left corner of the bounding box
to (0, 0).  This would be better done by translating the transformation matrix.

=head2 new_bbox

  $new_content = $pdf->new_bbox($content_stream);

This method simply calls the C<$pdf-E<gt>find_bbox()> method above with C<$new>
set to 1.

=head2 timestamp

  my $timestamp = $pdf->timestamp($time);
  my $now       = $pdf->timestamp;

Generate timestamp in PDF internal format.

=head1 UTILITY METHODS

=head2 round

  my @numbers = $pdf->round(@numbers);

Round numeric values to 12 significant digits to avoid floating-point rounding
error and remove trailing zeroes.

=head2 concat_matrix

  my $matrix = $pdf->concat_matrix($transformation_matrix, $original_matrix);

Concatenate a transformation matrix with an original matrix, returning a new
matrix.  This is for arrays of 6 elements representing standard 3x3
transformation matrices as used by PostScript and PDF.

=head2 invert_matrix

  my $inverse = $pdf->invert_matrix($matrix);

Calculate the inverse of a matrix, if possible.  Returns C<undef> if the matrix
is not invertible.

=head2 translate

  my $matrix = $pdf->translate($x, $y);

Returns a 6-element transformation matrix representing translation of the origin
to the specified coordinates.

=head2 scale

  my $matrix = $pdf->scale($x, $y);

Returns a 6-element transformation matrix representing scaling of the coordinate
space by the specified horizontal and vertical scaling factors.

=head2 rotate

  my $matrix = $pdf->rotate($angle);

Returns a 6-element transformation matrix representing counterclockwise rotation
of the coordinate system by the specified angle (in degrees).

=head1 INTERNAL METHODS

=head2 file

Used by many methods to get the PDF filename (if any) for error reporting.

=head2 binary_signature

Used by C<$pdf-E<gt>pdf_file_data()> to determine the 4-byte binary signature
to use on the comment line immediately following the %PDF header line.

By default, PDF::Data generates custom binary signature which carefully encodes
the author's initials (DTC) and the major/minor version number of PDF::Data
(from v1.0 to v8.63), in such a way that the binary signature is guaranteed to
be invalid for all Unicode encodings: UTF-8, UTF-16, UTF-16BE, UTF-16LE, UTF-32,
UTF-32BE and UTF-32LE.  (It will also be nonsensical if interpreted as Latin-1.)

The C<$pdf-E<gt>{-preserve_binary_signature}> flag can be used to suppress this
PDF::Data binary signature.  If this flag is set, the algorithm described above
will be skipped and the generated PDF data will use the binary signature already
stored in the PDF::Data object (if any), defaulting to the typical Adobe binary
signature used by Adobe's PDF library.

=head2 validate

  $pdf->validate;

Used by C<$pdf-E<gt>new()>, C<$pdf-E<gt>parse_pdf()> and
C<$pdf-E<gt>write_pdf()> to validate some parts of the PDF structure.
Currently, C<$pdf-E<gt>validate()> uses C<$pdf-E<gt>validate_key()> to verify
that the document catalog and page tree root node exist and have the correct
type, and that the page tree root node has no parent node.  Then it calls
C<$pdf-E<gt>validate_page_tree()> to validate the entire page tree.

By default, if a validation error occurs, it will be output as warnings, but
the C<$pdf-E<gt>{-validate}> flag can be set to make the errors fatal.

=head2 validate_page_tree

  my $count = $pdf->validate_page_tree($path, $page_tree_node);

Used by C<$pdf-E<gt>validate()>, and called by itself recursively, to validate
the PDF page tree and its subtrees.  The C<$path> parameter specifies the
logical path from the root of the PDF::Data object to the page subtree, and the
C<$page_tree_node> parameter specifies the actual page tree node data structure
represented by that logical path.  C<$pdf-E<gt>validate()> initially calls
C<$pdf-E<gt>validate_page_tree()> with "Root/Pages" for C<$path> and
C<$pdf-E<gt>{Root}{Pages}> for C<$page_tree_node>.

Each child of the page tree node (in C<$page_tree_node-E<gt>{Kids}>) should be
another page tree node for a subtree or a single page node.  In either case, the
parameters used for the next method call will be C<"$path\[$i]"> for C<$path>
(e.g. "Root/Pages[0][1]") and C<$page_tree_node-E<gt>{Kids}[$i]> for
C<$page_tree_node> (e.g.  C<$pdf-E<gt>{Root}{Pages}{Kids}[0]{Kids}[1]>).  These
parameters are passed to either C<$pdf-E<gt>validate_page_tree()> recursively
(if the child is a page tree node) or to C<$pdf-E<gt>validate_page()> (if the
child is a page node).

After validating the page tree, C<$pdf-E<gt>validate_resources()> will be called
to validate the page tree's resources, if any.

If the count of pages in the page tree is incorrect, it will be fixed.  This
method returns the total number of pages in the specified page tree.

=head2 validate_page

  $pdf->validate_page($path, $page);

Used by C<$pdf-E<gt>validate_page_tree()> to validate a single page of the PDF.
The C<$path> parameter specifies the logical path from the root of the PDF::Data
object to the page, and the C<$page> parameter specifies the actual page data
structure represented by that logical path.

This method will call C<$pdf-E<gt>merge_content_streams()> to merge the content
streams into a single content stream (if C<$page-E<gt>{Contents}> is an array),
then it will call C<$pdf-E<gt>validate_content_stream()> to validate the page's
content stream.

After validating the page, C<$pdf-E<gt>validate_resources()> will be called to
validate the page's resources, if any.

=head2 validate_resources

  $pdf->validate_resources($path, $resources);

Used by C<$pdf-E<gt>validate_page_tree()>, C<$pdf-E<gt>validate_page()> and
C<$pdf-E<gt>validate_xobject()> to validate associated resources.  The C<$path>
parameter specifies the logical path from the root of the PDF::Data object to
the resources, and the C<$resources> parameter specifies the actual resources
data structure represented by that logical path.

This method will call C<validate_xobjects> for C<$resources-E<gt>{XObject}>, if
set.

=head2 validate_xobjects

  $pdf->validate_xobjects($path, $xobjects);

Used by C<$pdf-E<gt>validate_resources()> to validate form XObjects in the
resources.  The C<$path> parameter specifies the logical path from the root of
the PDF::Data object to the hash of form XObjects, and the C<$xobjects>
parameter specifies the actual hash of form XObjects represented by that logical
path.

This method simply loops across all the form XObjects in C<$xobjects> and calls
C<$pdf-E<gt>validate_xobject()> for each of them.

=head2 validate_xobject

  $pdf->validate_xobject($path, $xobject);

Used by C<$pdf-E<gt>validate_xobjects()> to validate a form XObject.  The
C<$path> parameter specifies the logical path from the root of the PDF::Data
object to the form XObject, and the C<$xobject> parameter specifies the actual
form XObject represented by that logical path.

This method verifies that C<$xobject> is a stream and C<$xobject-E<gt>{Subtype}>
is "/Form", then calls C<$pdf-E<gt>validate_content_stream()> with C<$xobject>
to validate the form XObject content stream, then calls
C<$pdf-E<gt>validate_resources()> to validate the form XObject's resources, if
any.

=head2 validate_content_stream

  $pdf->validate_content_stream($path, $stream);

Used by C<$pdf-E<gt>validate_page()> and C<$pdf-E<gt>validate_xobject()> to
validate a content stream.  The C<$path> parameter specifies the logical path
from the root of the PDF::Data object to the content stream, and the C<$stream>
parameter specifies the actual content stream represented by that logical path.

This method calls C<$pdf-E<gt>parse_objects()> to make sure that the content
stream can be parsedi, and C<$pdf-E<gt>should_minify()> to check flags to
decide whether to call C<$pdf-E<gt>minify_content_stream()> will be called with
the array of parsed objects to minify the content stream.

=head2 minify_content_stream

  $pdf->minify_content_stream($stream, $objects);

Used by C<$pdf-E<gt>validate_content_stream()> to minify a content stream.  The
C<$stream> parameter specifies the content stream to be modified, and the
optional C<$objects> parameter specifies a reference to an array of parsed
objects as returned by C<$pdf-E<gt>parse_objects()>.

This method calls C<$pdf-E<gt>parse_objects()> to populate the C<$objects>
parameter if unspecified, then it calls C<$pdf-E<gt>generate_content_stream()>
to generate a minimal content stream for the array of objects, with no comments
and only the minimum amount of whitespace necessary to parse the content stream
correctly.  (Obviously, this means that this transformation is not reversible.)

Currently, this method also performs a sanity check by running the replacement
content stream through C<$pdf-E<gt>parse_objects()> and comparing the entire
list of objects returned against the original list of objects to ensure that the
replacement content stream is equivalent to the original content stream.

=head2 generate_content_stream

  my $data = $pdf->generate_content_stream($objects);

Used by C<$pdf-E<gt>minify_content_stream()> to generate a minimal content
stream to replace the original content stream.  The C<$objects> parameter
specifies a reference to an array of parsed objects as returned by
C<$pdf-E<gt>parse_objects()>.  These objects will be used to generate the new
content stream.

For each object in the array, this method will call an appropriate serialization
method: C<$pdf-E<gt>serialize_dictionary()> for dictionary objects,
C<$pdf-E<gt>serialize_array()> for array objects, or
C<$pdf-E<gt>serialize_object()> for other objects.  After serializing all the
objects, the newly-generated content stream data is returned.

=head2 serialize_dictionary

  $pdf->serialize_dictionary($stream, $hash);

Used by C<$pdf-E<gt>generate_content_stream()>,
C<$pdf-E<gt>serialize_dictionary()> (recursively) and
C<$pdf-E<gt>serialize_array()> to serialize a hash as a dictionary object.  The
C<$stream> parameter specifies a reference to a string containing the data for
the new content stream being generated, and the C<$hash> parameter specifies the
hash reference to be serialized.

This method will serialize all the key-value pairs of C<$hash>, prefixing each
key in the hash with "/" to serialize the key as a name object, and calling an
appropriate serialization routine for each value in the hash:
C<$pdf-E<gt>serialize_dictionary()> for dictionary objects (recursive call),
C<$pdf-E<gt>serialize_array()> for array objects, or
C<$pdf-E<gt>serialize_object()> for other objects.

=head2 serialize_array

  $pdf->serialize_array($stream, $array);

Used by C<$pdf-E<gt>generate_content_stream()>,
C<$pdf-E<gt>serialize_dictionary()> and C<$pdf-E<gt>serialize_array()>
(recursively) to serialize an array.  The C<$stream> parameter specifies a
reference to a string containing the data for the new content stream being
generated, and the C<$array> parameter specifies the array reference to be
serialized.

This method will serialize all the array elements of C<$array>, calling an
appropriate serialization routine for each element of the array:
C<$pdf-E<gt>serialize_dictionary()> for dictionary objects,
C<$pdf-E<gt>serialize_array()> for array objects (recursive call), or
C<$pdf-E<gt>serialize_object()> for other objects.

=head2 serialize_object

  $pdf->serialize_object($stream, $object);

Used by C<$pdf-E<gt>write_object()>, C<$pdf-E<gt>generate_content_stream()>,
C<$pdf-E<gt>serialize_dictionary()> and C<$pdf-E<gt>serialize_array()>
to serialize a simple object.  The C<$stream> parameter specifies a reference to
a string containing the data for the new content stream being generated, and the
C<$object> parameter specifies the pre-serialized object to be serialized to the
specified content stream data.

This method will strip leading and trailing whitespace from the pre-serialized
object if the C<$pdf-E<gt>{-minify}> flag is set, then append a newline
to C<${$stream}> if appending the pre-serialized object would exceed 255
characters for the last line, then append a space to C<${$stream}> if necessary
to parse the object correctly, then append the pre-serialized object to
C<${$stream}>.

=head2 validate_key

  $pdf->validate_key($hash, $key, $value, $label);

Used by C<$pdf-E<gt>validate()> to validate specific hash key values.

=head2 get_hash_node

  my $hash = $pdf->get_hash_node($path);

Used by C<$pdf-E<gt>validate_key()> to get a hash node from the PDF structure by
path.

=head2 parse_objects

  my @objects = $pdf->parse_objects($data, $offset);

Used by C<$pdf-E<gt>parse_pdf()>, C<$pdf-E<gt>parse_object_stream()>,
C<$pdf-E<gt>parse_data()>, C<$pdf-E<gt>validate_content_stream()> and
C<$pdf-E<gt>minify_content_stream()>, and called by itself recursively, to parse
PDF objects into Perl representations.

=head2 parse_data

  my @objects = $pdf->parse_data($data);

Uses C<$pdf-E<gt>parse_objects()> to parse PDF objects from standalone PDF data.

=head2 parse_object_stream

  $pdf->parse_object_stream($stream);

Used by C<$pdf-E<gt>parse_objects()> to parse PDF 1.5 object streams.

=head2 filter_stream

  $pdf->filter_stream($stream);

Used by C<$pdf-E<gt>parse_objects()> to inflate compressed streams.

=head2 compress_stream

  $new_stream = $pdf->compress_stream($stream);

Used by C<$pdf-E<gt>write_object()> to compress streams if enabled.  This is
controlled by the C<$pdf-E<gt>{-compress}> flag, which is set automatically when
reading a PDF file with compressed streams, but must be set manually for PDF
files created from scratch, either in the constructor arguments or after the
fact.

=head2 write_indirect_object

  my $startxref = $pdf->write_indirect_object($pdf_file_data, $seen, $id, $object);

Uses C<$pdf-E<gt>write_object> to write a single indirect object to a string of
new PDF file data; used by C<$pdf-E<gt>write_indirect_objects> and
C<$pdf-E<gt>write_xref_stream>.

=head2 write_indirect_objects

  my $xrefs = $pdf->write_indirect_objects($pdf_file_data, $seen);

Used by C<$pdf-E<gt>write_pdf()> to write all indirect objects to a string of
new PDF file data.

=head2 write_xref_table

  $pdf->write_xref_table($pdf_file_data, $seen, $xrefs);

Used by C<$pdf-E<gt>write_indirect_objects()> to write a standard
cross-reference table to a string of new PDF file data.

=head2 write_xref_stream

  $pdf->write_xref_stream($pdf_file_data, $seen, $xrefs);

Uses C<$pdf-E<gt>write_indirect_object()> to write a PDF 1.5 cross-reference
stream to a string of new PDF file data; used by
C<$pdf-E<gt>write_indirect_objects()>.

=head2 create_object_streams

  my $xrefs = $pdf->create_object_streams($seen);

Uses C<$pdf-E<gt>write_object()> and C<$pdf-E<gt>add_object_stream()> to create
PDF 1.5 object streams and write them to a string of new PDF file data; used by
C<$pdf-E<gt>write_indirect_objects()>.

=head2 add_object_stream

  my $id = $pdf->add_object_stream($pairs, $objects, $count, $extends);

Used by C<$pdf-E<gt>create_object_streams()> to add a new object stream to the
list of indirect objects to be written out.

=head2 enumerate_indirect_objects

  $pdf->enumerate_indirect_objects;

Used by C<$pdf-E<gt>write_indirect_objects()> to identify which objects in the
PDF data structure need to be indirect objects.

=head2 enumerate_shared_objects

  $pdf->enumerate_shared_objects($seen, $object);

Used by C<$pdf-E<gt>enumerate_indirect_objects()> to find objects which are
already shared (referenced from multiple objects in the PDF data structure).

=head2 add_indirect_objects

  $pdf->add_indirect_objects(@objects);

Used by C<$pdf-E<gt>enumerate_indirect_objects()>,
C<$pdf-E<gt>enumerate_shared_objects()> and C<$pdf-E<gt>write_object()> to add
objects to the list of indirect objects to be written out.

=head2 should_compress

  my $should_compress = $pdf->should_compress($stream);

Used by C<$pdf-E<gt>write_object()> to check for C<-compress>, C<-decompress>,
C<-no_compress>, C<-optimize> and C<-no_optimize> flags on the PDF object and
the stream itself to decide whether or not compression should be used for that
stream when writing PDF data.

=head2 should_minify

  my $should_minify = $pdf->should_minify($stream);

Used by C<$pdf-E<gt>validate_content_stream()> to check for C<-minify>,
C<-no_minify>, C<-optimize> and C<-no_optimize> flags on the PDF object and
the stream itself to decide whether or not minification should be used for that
stream when writing PDF data.

=head2 should_use_object_streams

  my $should_use_object_streams = $pdf->should_use_object_streams;

Used by C<$pdf-E<gt>pdf_file_data()> and C<$pdf-E<gt>write_indirect_objects()>
to check for C<$pdf-E<gt>{-use_object_streams}>,
C<$pdf-E<gt>{-no_object_streams}>, C<$pdf-E<gt>{-no_use_object_streams}>,
C<$pdf-E<gt>{-optimize}> and C<$pdf-E<gt>{-no_optimize}> flags to decide whether
or not PDF 1.5 object streams should be used when writing PDF data.

=head2 write_object

  $pdf->write_object($pdf_file_data, $seen, $object, $indent);

Used by C<$pdf-E<gt>write_indirect_objects()>,
C<$pdf-E<gt>write_indirect_object()>, C<$pdf-E<gt>write_xref_table()> and
C<$pdf-E<gt>create_object_streams()>, and called by itself recursively, to write
direct objects out to the string of new PDF file data; uses
C<$pdf-E<gt>should_compress()>, C<$pdf-E<gt>compress_stream()>,
C<$pdf-E<gt>serialize_array()>, C<$pdf-E<gt>serialize_object()> and
C<$pdf-E<gt>add_indirect_objects()>.

=head2 dump_object

  my $output = $pdf->dump_object($object, $label, $seen, $indent, $mode);

Used by C<$pdf-E<gt>dump_pdf()>, and called by itself recursively, to dump (or
outline) the specified PDF object.

=cut
