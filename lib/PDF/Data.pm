package PDF::Data;

# Require Perl v5.16; enable fatal warnings and UTF-8.
use v5.16;
use warnings FATAL => 'all';
use utf8;

# Declare module version.  (Also in pod documentation below.)
use version; our $VERSION = version->declare('v0.1.0');

# Initialize modules.
use mro;
use namespace::autoclean;
use Carp                qw[carp croak confess];;
use Clone;
use Compress::Raw::Zlib qw[:status];
use Data::Dump          qw[dd dump];
use List::MoreUtils     qw[minmax];
use List::Util          qw[max];
use POSIX               qw[mktime strftime];
use Scalar::Util        qw[blessed reftype];

# Use byte strings instead of Unicode character strings.
use bytes;

# Basic parsing regular expressions.
our $n = qr/(?:\n|\r\n?)/;                        # Match a newline. (LF, CRLF or CR)
our $ws = qr/(?:(?:(?>%[^\r\n]*)?\s+)+)/;         # Match whitespace, including PDF comments.

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
  my ($self) = @_;

  # Get the class name.
  my $class = blessed $self || $self;

  # Create a new instance.
  my $pdf = bless {}, $class;

  # Set creation timestamp.
  $pdf->{Info}{CreationDate} = $pdf->timestamp;

  # Create an empty document catalog and page tree.
  $pdf->{Root}{Pages} = { Kids => [], Count => 0 };

  # Validate the PDF structure and return the new instance.
  return $pdf->validate;
}

# Deep copy entire PDF::Data object.
sub clone {
  my ($self) = @_;
  return Clone::clone($self);
}

# Create a new page with the specified size.
sub new_page {
  my ($self, $x, $y) = @_;

  # Default page size to US Letter (8.5" x 11").
  ($x, $y) = (8.5, 11) if @_ == 1;

  # Make sure page size was specified.
  croak "Error: Paper size not specified!\n" unless $x and $y and $x > 0 and $y > 0;

  # Scale inches to default user space units (72 DPI).
  $x *= 72 if $x < 72;
  $y *= 72 if $y < 72;

  # Create and return a new page object.
  return {
    Type      => "/Page",
    MediaBox  => [0, 0, $x, $y],
    Contents  => { -data  => "" },
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
  my ($class, $file) = @_;

  # Get class name if called as an instance method.
  $class = blessed $class if blessed $class;

  # Read entire file at once.
  local $/;

  # Contents of entire PDF file.
  my $data;

  # Check for standard input.
  if (($file // "-") eq "-") {
    # Read all data from standard input.
    binmode STDIN or croak "stdin: $!\n";
    $data = <STDIN>;
    close STDIN or croak "stdin: $!\n";
  } else {
    # Read the entire file.
    open my $IN, '<', $file or croak "$file: $!\n";
    binmode $IN or croak "$file: $!\n";
    $data = <$IN>;
    close $IN or croak "$file: $!\n";
  }

  # Validate PDF file structure.
  my ($pdf_version, $startxref) = $data =~ /\A(%PDF-(1\.[0-7])$n.*$n)startxref$n(\d+)$n%%EOF$n?\z/s
    or croak "$file: File is not a valid PDF document!\n";

  # Parsed indirect objects.
  my $objects = {};

  # Parse PDF objects.
  my @objects = $class->parse_objects($objects, $data, 0);

  # PDF trailer dictionary.
  my $trailer;

  # Find trailer dictionary.
  for (my $i = 0; $i < @objects; $i++) {
    if ($objects[$i][0] eq "trailer") {
      $i < $#objects and $objects[$i + 1][1]{type} eq "dict" or croak "Byte offset $objects[$i][1]{offset}: Invalid trailer dictionary!\n";
      $trailer = $objects[$i + 1][0];
      last;
    }
  }

  # Make sure trailer dictionary was found.
  defined $trailer or croak "$file: PDF trailer dictionary not found!\n";

  # Resolve indirect object references.
  $class->resolve_references($objects, $trailer);

  # Create a new instance from the parsed data.
  my $pdf = bless $trailer, $class;

  # Validate the PDF structure and return the new instance.
  return $pdf->validate;
}

# Generate and write a new PDF file.
sub write_pdf {
  my ($self, $file, $time) = @_;

  # Default missing timestamp to current time, but keep a zero time as a flag.
  $time //= time;

  # Generate PDF file data.
  my $pdf_data = $self->pdf_file_data($time);

  # Check if standard output is wanted.
  if ($file eq "-") {
    # Write PDF file data to standard output.
    binmode STDOUT           or croak "<standard output>: $!\n";
    print   STDOUT $pdf_data or croak "<standard output>: $!\n";
  } else {
    # Write PDF file data to specified output file.
    open my $OUT, ">", $file or croak "$file $!\n";
    binmode $OUT             or croak "$file $!\n";
    print   $OUT $pdf_data   or croak "$file $!\n";
    close   $OUT             or croak "$file $!\n";

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

  # Validate the PDF structure.
  $self->validate;

  # Array of indirect objects, with lookup hash as first element.
  my $objects = [{}];

  # Objects seen while generating the PDF file data.
  my $seen = {};

  # Start with PDF header.
  my $pdf_file_data = "%PDF-1.4\n%\xBF\xF7\xA2\xFE\n\n";

  # Write all indirect objects.
  my $xrefs = $self->write_indirect_objects(\$pdf_file_data, $objects, $seen);

  # Add cross-reference table.
  my $startxref   = length($pdf_file_data);
  $pdf_file_data .= sprintf "xref\n0 %d\n", scalar @{$xrefs};
  $pdf_file_data .= join "", @{$xrefs};

  # Save correct size in trailer dictionary.
  $self->{Size} = scalar @{$xrefs};

  # Write trailer dictionary.
  $pdf_file_data .= "trailer ";
  $self->write_object(\$pdf_file_data, $objects, $seen, $self, 0);

  # Write startxref value.
  $pdf_file_data .= "startxref\n$startxref\n";

  # End of PDF file data.
  $pdf_file_data .= "%%EOF\n";

  # Return PDF file data.
  return $pdf_file_data;
}

# Dump internal structure of PDF file.
sub dump_pdf {
  my ($self, $file, $mode) = @_;

  # Use "stdout" instead of "-" to describe standard input.
  my $filename = $file =~ s/^-$/stdout/r;

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
    croak unless exists $stream->{-data};
    $stream->{-data} =~ s/(?<=\s) \z//;
  }

  # Concatenate stream data and calculate new length.
  my $merged = { -data => join "", map { $_->{-data}; } @{$streams} };

  # Return merged content stream.
  return $merged;
}

# Find bounding box for a content stream.
sub find_bbox {
  my ($self, $content_stream, $new) = @_;

  # Get data from stream, if necessary.
  $content_stream = $content_stream->{-data} if is_stream $content_stream;

  # Split content stream into lines.
  my @lines = grep { $_ ne ""; } split /\n/, $content_stream;

  # Bounding box.
  my ($left, $bottom, $right, $top);

  # Regex to match a number.
  my $n = qr/-?\d+(?:\.\d+)?/;

  # Determine bounding box from content stream.
  foreach (@lines) {
    # Skip neutral lines.
    next if m{^(?:/Figure <</MCID \d >>BDC|/PlacedGraphic /MC\d BDC|EMC|/GS\d gs|BX /Sh\d sh EX Q|[Qqh]|W n|$n $n $n $n $n $n cm)\s*$};

    # Capture coordinates from drawing operations to calculate bounding box.
    if (my ($x1, $y1, $x2, $y2, $x3, $y3) = /^($n) ($n) (?:[ml]|($n) ($n) (?:[vy]|($n) ($n) c))$/) {
      ($left, $right) = minmax grep { defined $_; } $left, $right, $x1, $x2, $x3;
      ($bottom, $top) = minmax grep { defined $_; } $bottom, $top, $y1, $y2, $y3;
    } elsif (my ($x, $y, $width, $height) = /^($n) ($n) ($n) ($n) re$/) {
      ($left, $right) = minmax grep { defined $_; } $left, $right, $x, $x + $width;
      ($bottom, $top) = minmax grep { defined $_; } $bottom, $top, $y, $y + $height;
    } else {
      croak "Parse error: Content line \"$_\" not recognized!\n";
    }
  }

  # Print bounding box and rectangle.
  my $width  = $right - $left;
  my $height = $top   - $bottom;
  print STDERR "Bounding Box: $left $bottom $right $top\nRectangle: $left $bottom $width $height\n\n";

  # Return unless generating a new bounding box.
  return unless $new;

  # Update content stream.
  my $xy = "%.12g %.12g";
  for ($content_stream) {
    # Update coordinates in drawing operations.
    s/^($n) ($n) ([ml])$/sprintf "$xy %s", $1 - $left, $2 - $bottom, $3/egm;
    s/^($n) ($n) ($n) ($n) ([vy])$/sprintf "$xy $xy %s", $1 - $left, $2 - $bottom, $3 - $left, $4 - $bottom, $5/egm;
    s/^($n) ($n) ($n) ($n) ($n) ($n) (c)$/sprintf "$xy $xy $xy %s", $1 - $left, $2 - $bottom, $3 - $left, $4 - $bottom, $5 - $left, $6 - $bottom, $7/egm;
    s/^($n $n $n $n) ($n) ($n) (cm)$/sprintf "%s $xy %s", $1, $2 - $left, $3 - $bottom, $4/egm;
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
  return sprintf "(D:%s%+03d'%02d)", strftime("%Y%m%d%H%M%S", @time), $tz / 60, abs($tz) % 60;
}

# Validate PDF structure.
sub validate {
  my ($self) = @_;

  # Make sure document catalog exists and has the correct type.
  $self->validate_key("Root", "Type", "/Catalog", "document catalog");

  # Make sure page tree root node exists, has the correct type, and has no parent.
  $self->validate_key("Root/Pages", "Type", "/Pages", "page tree root");
  $self->validate_key("Root/Pages", "Parent", undef,  "page tree root");

  # Return this instance.
  return $self;
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
    carp "Warning: Fixing $label: {$key} $hash->{$key} -> $value\n" if $hash->{$key};
    $hash->{$key} = $value;
  } elsif (not defined $value and exists $hash->{$key}) {
    carp "Warning: Deleting $label: {$key} $hash->{$key}\n" if $hash->{$key};
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
  my ($self, $objects, $data, $offset) = @_;

  # Parsed PDF objects.
  my @objects;

  # Calculate EOF offset.
  my $eof = $offset + length $data;

  # Copy data for parsing.
  local $_ = $data;

  # Parse PDF objects in input string.
  while ($_ ne "") {
    # Update the file offset.
    $offset = $eof - length $_;

    # Parse the next PDF object.
    if (s/\A$ws//) {                                                            # Strip leading whitespace/comments.
      next;
    } elsif (s/\A(<<((?:[^<>]+|<[^<>]+>|(?1))*)$ws?>>)//) {                     # Dictionary: <<...>> (including nested dictionaries)
      my @pairs = $self->parse_objects($objects, $2, $offset);
      for (my $i = 0; $i < @pairs; $i++) {
        $pairs[$i] = $i % 2 ? $pairs[$i][0] : $pairs[$i][1]{name} // croak;
      }
      push @objects, [ { @pairs }, { type => "dict" } ];
    } elsif (s/\A(\[((?:(?>[^\[\]]+)|(?1))*)\])//) {                            # Array: [...] (including nested arrays)
      my $array = [ map $_->[0], $self->parse_objects($objects, $2, $offset) ];
      push @objects, [ $array, { type => "array" }];
    } elsif (s/\A(\((?:(?>[^\\()]+)|\\.|(?1))*\))//) {                          # String literal: (...) (including nested parens)
      push @objects, [ $1, { type => "string" } ];
    } elsif (s/\A(<[0-9A-Fa-f\s]*>)//) {                                        # Hexadecimal string literal: <...>
      push @objects, [ lc($1) =~ s/\s+//gr, { type => "hex" } ];
    } elsif (s/\A(\/?[^\s()<>\[\]{}\/%]+)//) {                                  # /Name, number or other token
      # Check for tokens of special interest.
      my $token = $1;
      if ($token eq "obj" or $token eq "R") {                                   # Indirect object/reference: 999 0 obj or 999 0 R
        my ($id, $gen) = splice @objects, -2;
        my $type = $token eq "R" ? "reference" : "definition";
        "$id->[1]{type} $gen->[1]{type}" eq "int int"
          or croak "$id->[0] $gen->[0] $token: Invalid indirect object $type!\n";
        my $new_id = join "-", $id->[0], $gen->[0] || ();
        push @objects, [
          ($token eq "R" ? \$new_id : $new_id),
          { type => $token, offset => $id->[1]{offset} }
        ];
      } elsif ($token eq "stream") {                                            # Stream content: stream ... endstream
        my ($id, $stream) = @objects[-2,-1];
        $stream->[1]{type} eq "dict" or croak "Stream dictionary missing!\n";
        $id->[1]{type} eq "obj" or croak "Invalid indirect object definition!\n";
        $_ = $_->[0] for $id, $stream;
        defined $stream->{Length}
          or carp "Object #$id: Stream length not found in metadata!\n";
        s/\A$n((?>(?!endstream\s)[^\r\n]*$n)*)endstream$ws//
          or croak "Invalid stream definition!\n";
        $stream->{-data}    = $1;
        $stream->{-id}      = $id;
        $stream->{Length} //= length $1;
        $self->filter_stream($stream) if $stream->{Filter};
      } elsif ($token eq "endobj") {                                            # Indirect object definition: 999 0 obj ... endobj
        my ($id, $object) = splice @objects, -2;
        $id->[1]{type} eq "obj" or croak "Invalid indirect object definition!\n";
        $object->[1]{id} = $id->[0];
        $objects->{$id->[0]} = $object;
        $objects->{offset}{$object->[1]{offset} // $offset} = $object;
        push @objects, $object;
      } elsif ($token eq "xref") {                                              # Cross-reference table
        s/\A$ws\d+$ws\d+$n(?>\d{10}\ \d{5}\ [fn](?:\ [\r\n]|\r\n))+//
          or croak "Invalid cross-reference table!\n";
      } elsif ($token =~ /^[+-]?\d+$/) {                                        # Integer: [+-]999
        push @objects, [ $token, { type => "int" } ];
      } elsif ($token =~ /^[+-]?(?:\d+\.\d*|\.\d+)$/) {                         # Real number: [+-]999.999
        push @objects, [ $token, { type => "real" } ];
      } elsif ($token =~ /^\/(.*)$/) {                                          # Name: /Name
        push @objects, [ $token, { type => "name", name => $1 } ];
      } elsif ($token =~ /^(?:true|false)$/) {                                  # Boolean: true or false
        push @objects, [ $token, { type => "bool", bool => $token eq "true" } ];
      } else {                                                                  # Other token
        push @objects, [ $token, { type => "token" } ];
      }
    } else {
      s/\A([^\r\n]*).*\z/$1/s;
      croak "Byte offset $offset: Parse error on input: \"$_\"\n";
    }

    # Update offset/length of last object.
    $objects[-1][1]{offset} //= $offset;
    $objects[-1][1]{length}   = $eof - length($_) - $objects[-1][1]{offset};
  }

  # Return parsed PDF objects.
  return @objects;
}

# Filter stream data.
sub filter_stream {
  my ($self, $stream) = @_;

  # Decompress stream data if necessary.
  if ($stream->{Filter} eq "/FlateDecode") {
    my $zlib = new Compress::Raw::Zlib::Inflate;
    my $output;
    my $status = $zlib->inflate($stream->{-data}, $output);
    if ($status == Z_OK or $status == Z_STREAM_END) {
      $stream->{-data}  = $output;
      $stream->{Length} = length $output;
    } else {
      croak "Object #$stream->{-id}: Stream inflation failed! ($zlib->msg)\n";
    }
  }
}

# Resolve indirect object references.
sub resolve_references {
  my ($self, $objects, $object) = @_;

  # Replace indirect object references with a reference to the actual object.
  if (ref $object and reftype($object) eq "SCALAR") {
    my $id = ${$object};
    if ($objects->{$id}) {
      ($object, my $metadata) = @{$objects->{$id}};
      return $object if $metadata->{resolved}++;
    } else {
      ($id, my $gen) = split /-/, $id;
      $gen ||= "0";
      carp "Warning: $id $gen R: Referenced indirect object not found!\n";
    }
  }

  # Check object type.
  if (is_hash $object) {
    # Resolve references in hash values.
    foreach my $key (sort { fc($a) cmp fc($b) || $a cmp $b; } keys %{$object}) {
      $object->{$key} = $self->resolve_references($objects, $object->{$key}) if ref $object->{$key};
    }

    # For streams, validate the length metadata.
    if (exists $object->{-data}) {
      substr($object->{-data}, $object->{Length}) =~ s/\A\s+\z// if $object->{Length} and length($object->{-data}) > $object->{Length};
      my $len = length $object->{-data};
      $object->{Length} ||= $len;
      $len == $object->{Length} or carp "Warning: Object #$object->{-id}: Stream length does not match metadata! ($len != $object->{Length})\n";
    }
  } elsif (is_array $object) {
    # Resolve references in array values.
    foreach my $i (0 .. $#{$object}) {
      $object->[$i] = $self->resolve_references($objects, $object->[$i]) if ref $object->[$i];
    }
  }

  # Return object with resolved references.
  return $object;
}

# Write all indirect objects to PDF file data.
sub write_indirect_objects {
  my ($self, $pdf_file_data, $objects, $seen) = @_;

  # Enumerate all indirect objects.
  $self->enumerate_indirect_objects($objects);

  # Cross-reference file offsets.
  my $xrefs = ["0000000000 65535 f \n"];

  # Loop across indirect objects.
  for (my $i = 1; $i <= $#{$objects}; $i++) {
    # Save file offset for cross-reference table.
    push @{$xrefs}, sprintf "%010d 00000 n \n", length(${$pdf_file_data});

    # Write the indirect object header.
    ${$pdf_file_data} .= "$i 0 obj\n";

    # Write the object itself.
    $self->write_object($pdf_file_data, $objects, $seen, $objects->[$i], 0);

    # Write the indirect object trailer.
    ${$pdf_file_data} .= "endobj\n\n";
  }

  # Return cross-reference file offsets.
  return $xrefs;
}

# Enumerate all indirect objects.
sub enumerate_indirect_objects {
  my ($self, $objects) = @_;

  # Add top-level PDF indirect objects.
  $self->add_indirect_objects($objects,
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
  $self->add_indirect_objects($objects, @{$self->{Root}{OCProperties}{OCGs}}) if $self->{Root}{OCProperties};

  # Enumerate shared objects.
  $self->enumerate_shared_objects($objects, {}, {}, $self->{Root});

  # Add referenced indirect objects.
  for (my $i = 1; $i <= $#{$objects}; $i++) {
    # Get object.
    my $object = $objects->[$i];

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
          if (($object->{Type} // "") eq "/ExtGState" and $key eq "Font" and is_array $object->{Font} and is_hash $object->{Font}[0]) {
            push @objects, $object->{Font}[0];
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
      $self->add_indirect_objects($objects, @objects) if @objects;
    }
  }
}

# Enumerate shared objects.
sub enumerate_shared_objects {
  my ($self, $objects, $seen, $ancestors, $object) = @_;

  # Add shared indirect objects.
  if ($seen->{$object}++) {
    $self->add_indirect_objects($objects, $object) unless $objects->[0]{$object};
    return;
  }

  # Return if this object is an ancestor of itself.
  return if $ancestors->{$object};

  # Add this object to the lookup hash of ancestors.
  $ancestors->{$object}++;

  # Recurse to check entire object tree.
  if (is_hash $object) {
    foreach my $key (sort { fc($a) cmp fc($b) || $a cmp $b; } keys %{$object}) {
      $self->enumerate_shared_objects($objects, $seen, $ancestors, $object->{$key}) if ref $object->{$key};
    }
  } elsif (is_array $object) {
    foreach my $obj (@{$object}) {
      $self->enumerate_shared_objects($objects, $seen, $ancestors, $obj) if ref $obj;
    }
  }

  # Remove this object from the lookup hash of ancestors.
  delete $ancestors->{$object};
}

# Add indirect objects.
sub add_indirect_objects {
  my ($self, $objects, @objects) = @_;

  # Loop across specified objects.
  foreach my $object (@objects) {
    # Check if object exists and is not in the lookup hash yet.
    if (defined $object and not $objects->[0]{$object}) {
      # Add the new indirect object to the array.
      push @{$objects}, $object;

      # Save the object ID in the lookup hash, keyed by the object.
      $objects->[0]{$object} = $#{$objects};
    }
  }
}

# Write a direct object to the string of PDF file data.
sub write_object {
  my ($self, $pdf_file_data, $objects, $seen, $object, $indent) = @_;

  # Make sure the same object isn't written twice.
  if (ref $object and $seen->{$object}++) {
    croak "Object $object written more than once!\n";
  }

  # Check object type.
  if (is_hash $object) {
    # For streams, update length in metadata.
    $object->{Length} = length $object->{-data} if exists $object->{-data};

    # Dictionary object.
    ${$pdf_file_data} .= "<<\n";
    foreach my $key (sort { fc($a) cmp fc($b) || $a cmp $b; } keys %{$object}) {
      next if $key =~ /^-/;
      my $obj = $object->{$key};
      $self->add_indirect_objects($objects, $obj) if is_stream $obj;
      ${$pdf_file_data} .= join "", " " x ($indent + 2), "/$key ";
      if (not ref $obj) {
        ${$pdf_file_data} .= "$obj\n";
      } elsif ($objects->[0]{$obj}) {
        ${$pdf_file_data} .= "$objects->[0]{$obj} 0 R\n";
      } else {
        $self->write_object($pdf_file_data, $objects, $seen, $object->{$key}, ref $object ? $indent + 2 : 0);
      }
    }
    ${$pdf_file_data} .= join "", " " x $indent, ">>\n";

    # For streams, write the stream data.
    if (exists $object->{-data}) {
      croak "Stream written as direct object!\n" if $indent;
      my $newline = substr($object->{-data}, -1) eq "\n" ? "" : "\n";
      ${$pdf_file_data} .= "stream\n$object->{-data}${newline}endstream\n";
    }
  } elsif (is_array $object and not grep { ref $_; } @{$object}) {
    # Array of simple objects.
    ${$pdf_file_data} .= "[ @{$object} ]\n";
  } elsif (is_array $object) {
    # Array object.
    ${$pdf_file_data} .= "[\n";
    my $spaces = " " x ($indent + 2);
    foreach my $obj (@{$object}) {
      $self->add_indirect_objects($objects, $obj) if is_stream $obj;
      ${$pdf_file_data} .= $spaces;
      if (not ref $obj) {
        ${$pdf_file_data} .= $obj;
        $spaces = " ";
      } elsif ($objects->[0]{$obj}) {
        ${$pdf_file_data} .= "$objects->[0]{$obj} 0 R\n";
        $spaces = " " x ($indent + 2);
      } else {
        $self->write_object($pdf_file_data, $objects, $seen, $obj, $indent + 2);
        $spaces = " " x ($indent + 2);
      }
    }
    ${$pdf_file_data} .= "\n" if $spaces eq " ";
    ${$pdf_file_data} .= join "", " " x $indent, "]\n";
  } elsif (reftype($object) eq "SCALAR") {
    # Unresolved indirect reference.
    my ($id, $gen) = split /-/, ${$object};
    $gen ||= "0";
    ${$pdf_file_data} .= join "", " " x $indent, "($id $gen R)\n";
  } else {
    # Simple object.
    ${$pdf_file_data} .= join "", " " x $indent, "$object\n";
  }
}

# Dump PDF object.
sub dump_object {
  my ($self, $object, $label, $seen, $indent, $mode) = @_;

  # Dump output.
  my $output = "";

  # Check mode and object type.
  if ($mode eq "outline") {
    if (ref $object and $seen->{$object}) {
      # Previously-seen object; dump the label.
      $output = "$seen->{$object}";
    } elsif (is_hash $object) {
      # Hash object.
      $seen->{$object} = $label;
      if (exists $object->{-data}) {
        $output = "(STREAM)";
      } else {
        $label =~ s/(?<=\w)$/->/;
        my @keys = sort { fc($a) cmp fc($b) || $a cmp $b; } keys %{$object};
        my $key_len = max map length $_, @keys;
        foreach my $key (@keys) {
          my $obj = $object->{$key};
          next unless ref $obj;
          $output .= sprintf "%s%-${key_len}s => ", " " x ($indent + 2), $key;
          $output .= $self->dump_object($object->{$key}, "$label\{$key\}", $seen, ref $object ? $indent + 2 : 0, $mode) . ",\n";
        }
        if ($output) {
          $output = join "", "{ # $label\n", $output, (" " x $indent), "}";
        } else {
          $output = "{...}";
        }
        $output =~ s/\{ \# \$pdf->\n/\{\n/;
      }
    } elsif (is_array $object and not grep { ref $_; } @{$object}) {
      # Array of simple objects.
      $output = "[...]";
    } elsif (is_array $object) {
      # Array object.
      for (my $i = 0; $i < @{$object}; $i++) {
        $output .= sprintf "%s%s,\n", " " x ($indent + 2), $self->dump_object($object->[$i], "$label\[$i\]", $seen, $indent + 2, $mode) if ref $object->[$i];
      }
      if ($output =~ /\A\s+(.*?),\n\z/) {
        $output = "[... $1]";
      } elsif ($output =~ /\n/) {
        $output = join "", "[ # $label\n", $output, (" " x $indent), "]";
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
    my @keys = sort { fc($a) cmp fc($b) || $a cmp $b; } keys %{$object};
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
    $output = sprintf "[%s]", join ", ", map { /^\d+\.\d+$/ ? $_ : dump($_); } @{$object};
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

version v0.1.0

=head1 SYNOPSIS

  use PDF::Data;

=head1 DESCRIPTION

This module can read and write PDF files, and represents PDF objects as data
structures that can be readily manipulated.

=head1 METHODS

=head2 new

  my $pdf = PDF::Data->new;

Constructor to create an empty PDF::Data object instance.

=head2 clone

  my $pdf_clone = $pdf->clone;

Deep copy the entire PDF::Data object itself.

=head2 new_page

  my $page = $pdf->new_page(8.5, 11);

Create a new page object with the specified size.

=head2 copy_page

  my $copied_page = $pdf->copy_page($page);

Deep copy a single page object.

=head2 append_page

  $page = $pdf->append_page($page);

Append the specified page object to the end of the PDF page tree.

=head2 read_pdf

  my $pdf = PDF::Data->read_pdf($file);

Read and parse a PDF file, returning a new object instance.

=head2 write_pdf

  $pdf->write_pdf($file, $time);

Generate and write a new PDF file from the current state of the PDF data.

The C<$time> parameter is optional; if not defined, it defaults to the
current time.  If C<$time> is defined but false (zero or empty string),
no timestamp will be set.

The optional C<$time> parameter may be used to specify the modification
timestamp to save in the PDF metadata and to set the file modification
timestamp of the output file.  If not specified, it defaults to the
current time.  If a false value is specified, this method will skip
setting the modification time in the PDF metadata, and skip setting the
timestamp on the output file.

=head2 pdf_file_data

  my $pdf_file_data = $document->pdf_file_data($time);

Generate PDF file data from the current state of the PDF data structure,
suitable for writing to an output PDF file.  This method is used by the
C<write_pdf()> method to generate the raw string of bytes to be written
to the output PDF file.  This data can be directly used (e.g. as a MIME
attachment) without the need to actually write a PDF file to disk.

The optional C<$time> parameter may be used to specify the modification
timestamp to save in the PDF metadata.  If not specified, it defaults to
the current time.  If a false value is specified, this method will skip
setting the modification time in the PDF metadata.

=head2 dump_pdf

  $pdf->dump_pdf($file);

Dump the PDF internal structure and data for debugging.

=head2 dump_outline

  $pdf->dump_outline($file);

Dump an outline of the PDF internal structure for debugging.

=head2 merge_content_streams

  $pdf->merge_content_streams($array_of_streams);

Merge multiple content streams into a single content stream.

=head2 find_bbox

  $pdf->find_bbox($content_stream);

Find bounding box by analyzing a content stream.  This is only partially implemented.

=head2 new_bbox

  $new_content = $pdf->new_bbox($content_stream);

Find bounding box by analyzing a content stream.  This is only partially implemented.

=head2 timestamp

  my $timestamp = $pdf->timestamp($time);
  my $now       = $pdf->timestamp;

Generate timestamp in PDF internal format.

=head1 INTERNAL METHODS

=head2 validate

  $pdf->validate;

Used by new(), read_pdf() and write_pdf() to validate some parts of the PDF structure.

=head2 validate_key

  $pdf->validate_key($hash, $key, $value, $label);

Used by validate() to validate specific hash key values.

=head2 get_hash_node

  my $hash = $pdf->get_hash_node($path);

Used by validate_key() to get a hash node from the PDF structure by path.

=head2 parse_objects

  my @objects = $pdf->parse_objects($objects, $data, $offset);

Used by read_pdf() to parse PDF objects into Perl representations.

=head2 filter_stream

  $pdf->filter_stream($stream);

Used by parse_objects() to inflate compressed streams.

=head2 resolve_references

  $object = $pdf->resolve_references($objects, $object);

Used by read_pdf() to replace parsed indirect object references with
direct references to the objects in question.

=head2 write_indirect_objects

  my $xrefs = $pdf->write_indirect_objects($pdf_file_data, $objects, $seen);

Used by write_pdf() to write all indirect objects to a string of new
PDF file data.

=head2 enumerate_indirect_objects

  $pdf->enumerate_indirect_objects($objects);

Used by write_indirect_objects() to identify which objects in the PDF
data structure need to be indirect objects.

=head2 enumerate_shared_objects

  $pdf->enumerate_shared_objects($objects, $seen, $ancestors, $object);

Used by enumerate_indirect_objects() to find objects which are already
shared (referenced from multiple objects in the PDF data structure).

=head2 add_indirect_objects

  $pdf->add_indirect_objects($objects, @objects);

Used by enumerate_indirect_objects() and enumerate_shared_objects() to
add objects to the list of indirect objects to be written out.

=head2 write_object

  $pdf->write_object($pdf_file_data, $objects, $seen, $object, $indent);

Used by write_indirect_objects(), and called by itself recursively, to
write direct objects out to the string of new PDF file data.

=head2 dump_object

  my $output = $pdf->dump_object($object, $label, $seen, $indent, $mode);

Used by dump_pdf(), and called by itself recursively, to dump/outline
the specified PDF object.

=cut
