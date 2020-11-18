package PDF::Data;

# Require Perl v5.16; enable fatal warnings.
use v5.16;
use warnings FATAL => 'all';

# Declare module version.
use version; our $VERSION = version->declare('v0.0.1');

# Initialize modules.
use Carp                qw[carp croak confess];;
use Compress::Raw::Zlib qw[:status];
use Data::Dump          qw[dd dump];
use List::MoreUtils     qw[minmax];
use List::Util          qw[max];
use POSIX               qw[mktime strftime];

# Basic parsing regular expressions.
our $n = qr/(?:\n|\r\n?)/;                        # Match a newline. (LF, CRLF or CR)
our $ws = qr/(?:(?:(?>%[^\r\n]*)?\s+)+)/;         # Match whitespace, including PDF comments.

# Read and parse PDF file.
sub read_pdf {
  my ($class, $file) = @_;

  # Get class name if called as an instance method.
  $class = ref $class if ref $class;

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

  # Return parsed data as a new instance.
  return bless $trailer, $class;
}

# Generate and write a new PDF file.
sub write_pdf {
  my ($self, $file) = @_;

  # Array of indirect objects, with lookup hash as first element.
  my $objects = [{}];

  # Objects seen while writing the PDF file.
  my $seen = {};

  # Use "stdout" instead of "-" to describe standard input.
  my $filename = $file =~ s/^-$/stdout/r;

  # Open output file.
  open my $OUT, ">$file" or croak "$filename: $!\n";

  # Write PDF header.
  print $OUT "%PDF-1.4\n%\xBF\xF7\xA2\xFE\n\n";

  # Write all indirect objects to PDF file.
  my $xrefs = $self->write_indirect_objects($OUT, $objects, $seen);

  # Write cross-reference table.
  my $startxref = tell $OUT;
  printf $OUT "xref\n0 %d\n", scalar @{$xrefs};
  print $OUT @{$xrefs};

  # Save correct size in trailer dictionary.
  $self->{Size} = scalar @{$xrefs};

  # Write trailer dictionary.
  print $OUT "trailer ";
  $self->write_object($OUT, $objects, $seen, $self, 0);

  # Write startxref value.
  print $OUT "startxref\n$startxref\n";

  # End of PDF file.
  print $OUT "%%EOF\n";

  # Close the output file.
  close $OUT or croak "$filename: $!\n";

  # Print success message.
  print STDERR "Wrote new PDF file \"$file\".\n\n" unless $file eq "-";
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
  return $self->dump_pdf($file // "-", 1);
}

# Merge content streams.
sub merge_content_streams {
  my ($self, $streams) = @_;

  # Make sure content is an array.
  return $streams unless ref($streams) eq "ARRAY";

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

# Find bounding box.
sub find_bbox {
  my ($self, $content_stream, $new) = @_;

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

# Generate timestamp in PDF internal format.
sub timestamp {
  my ($self, $time) = @_;

  $time //= time;
  my @time = localtime $time;
  my $tz = $time[8] * 60 - mktime(gmtime 0) / 60;
  return sprintf "(D:%s%+03d'%02d)", strftime("%Y%m%d%H%M%S", @time), $tz / 60, abs($tz) % 60;
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
  if (ref $object eq "SCALAR") {
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
  if (ref($object) =~ /^(?:HASH|PDF::Data)$/) {
    # Resolve references in hash values.
    foreach my $key (sort { fc($a) cmp fc($b) || $a cmp $b; } keys %{$object}) {
      $object->{$key} = $self->resolve_references($objects, $object->{$key}) if ref $object->{$key};
    }

    # For streams, validate the length metadata.
    if (exists $object->{-data}) {
      substr($object->{-data}, $object->{Length}) =~ s/\A\s+\z// if length($object->{-data}) > $object->{Length};
      my $len = length $object->{-data};
      $len == $object->{Length} or carp "Warning: Object #$object->{-id}: Stream length does not match metadata! ($len != $object->{Length})\n";
    }
  } elsif (ref $object eq "ARRAY") {
    # Resolve references in array values.
    foreach my $i (0 .. $#{$object}) {
      $object->[$i] = $self->resolve_references($objects, $object->[$i]) if ref $object->[$i];
    }
  }

  # Return object with resolved references.
  return $object;
}

# Write all indirect objects to PDF file.
sub write_indirect_objects {
  my ($self, $OUT, $objects, $seen) = @_;

  # Enumerate all indirect objects.
  $self->enumerate_indirect_objects($objects);

  # Cross-reference file offsets.
  my $xrefs = ["0000000000 65535 f \n"];

  # Loop across indirect objects.
  for (my $i = 1; $i <= $#{$objects}; $i++) {
    # Save file offset for cross-reference table.
    push @{$xrefs}, sprintf "%010d 00000 n \n", tell $OUT;

    # Write the indirect object header.
    print $OUT "$i 0 obj\n";

    # Write the object itself.
    $self->write_object($OUT, $objects, $seen, $objects->[$i], 0);

    # Write the indirect object trailer.
    print $OUT "endobj\n\n";
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
    if (ref($object) =~ /^(?:HASH|PDF::Data)$/) {
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
          if (($object->{Type} // "") eq "/ExtGState" and $key eq "Font" and ref $object->{Font} eq "ARRAY" and ref $object->{Font}[0] eq "HASH") {
            push @objects, $object->{Font}[0];
          } elsif ($key =~ /^(?:Data|First|ID|Last|Next|Obj|Parent|ParentTree|Popup|Prev|Root|StmOwn|Threads|Widths)$/
              or $key =~ /^(?:AN|Annotation|B|C|CI|DocMDP|F|FontDescriptor|I|IX|K|Lock|N|P|Pg|RI|SE|SV|V)$/ and ref($object->{$key}) eq "HASH"
              or ref($object->{$key}) eq "HASH" and ($object->{$key}{-data} or $object->{$key}{Kids} or ($object->{$key}{Type} // "") =~ /^\/(?:Filespec|Font)$/)
              or ($object->{S} // "") eq "/Thread" and $key eq "D"
              or ($object->{S} // "") eq "/Hide"   and $key eq "T"
          ) {
            push @objects, $object->{$key};
          } elsif ($key =~ /^(?:Annots|B|C|CO|Fields|K|Kids|O|Pages|TrapRegions)$/ and ref($object->{$key}) eq "ARRAY") {
            push @objects, grep { ref $_ eq "HASH"; } @{$object->{$key}};
          } elsif (ref($object->{$key}) eq "HASH") {
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

  # Add this object to the lookup hash of ancestors.
  $ancestors->{$object}++;

  # Recurse to check entire object tree.
  if (ref($object) =~ /^(?:HASH|PDF::Data)$/) {
    foreach my $key (sort { fc($a) cmp fc($b) || $a cmp $b; } keys %{$object}) {
      $self->enumerate_shared_objects($objects, $seen, $ancestors, $object->{$key}) if ref($object->{$key}) and not $ancestors->{$object->{$key}};
    }
  } elsif (ref $object eq "ARRAY") {
    foreach my $obj (@{$object}) {
      $self->enumerate_shared_objects($objects, $seen, $ancestors, $obj) if ref($obj) and not $ancestors->{$obj};
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

# Write a direct object to the PDF file.
sub write_object {
  my ($self, $OUT, $objects, $seen, $object, $indent) = @_;

  # Make sure the same object isn't written twice.
  if (ref($object) and $seen->{$object}++) {
    croak "Object $object written more than once!\n";
  }

  # Check object type.
  if (ref($object) =~ /^(?:HASH|PDF::Data)$/) {
    # For streams, update length in metadata.
    $object->{Length} = length $object->{-data} if exists $object->{-data};

    # Dictionary object.
    print $OUT "<<\n";
    foreach my $key (sort { fc($a) cmp fc($b) || $a cmp $b; } keys %{$object}) {
      next if $key =~ /^-/;
      my $obj = $object->{$key};
      $self->add_indirect_objects($objects, $obj) if $obj and ref($obj) eq "HASH" and exists $obj->{-data};
      print $OUT " " x ($indent + 2), "/$key ";
      if (not ref $obj) {
        print $OUT "$obj\n";
      } elsif ($objects->[0]{$obj}) {
        print $OUT "$objects->[0]{$obj} 0 R\n";
      } else {
        $self->write_object($OUT, $objects, $seen, $object->{$key}, ref $object ? $indent + 2 : 0);
      }
    }
    print $OUT " " x $indent, ">>\n";

    # For streams, write the stream data.
    if (exists $object->{-data}) {
      croak "Stream written as direct object!\n" if $indent;
      my $newline = substr($object->{-data}, -1) eq "\n" ? "" : "\n";
      print $OUT "stream\n$object->{-data}${newline}endstream\n";
    }
  } elsif (ref($object) eq "ARRAY" and not grep { ref $_; } @{$object}) {
    # Array of simple objects.
    print $OUT "[ @{$object} ]\n";
  } elsif (ref($object) eq "ARRAY") {
    # Array object.
    print $OUT "[\n";
    my $spaces = " " x ($indent + 2);
    foreach my $obj (@{$object}) {
      $self->add_indirect_objects($objects, $obj) if $obj and ref($obj) eq "HASH" and exists $obj->{-data};
      print $OUT $spaces;
      if (not ref $obj) {
        print $OUT $obj;
        $spaces = " ";
      } elsif ($objects->[0]{$obj}) {
        print $OUT "$objects->[0]{$obj} 0 R\n";
        $spaces = " " x ($indent + 2);
      } else {
        $self->write_object($OUT, $objects, $seen, $obj, $indent + 2);
        $spaces = " " x ($indent + 2);
      }
    }
    print $OUT "\n" if $spaces eq " ";
    print $OUT " " x $indent, "]\n";
  } elsif (ref($object) eq "SCALAR") {
    # Unresolved indirect reference.
    my ($id, $gen) = split /-/, ${$object};
    $gen ||= "0";
    print $OUT " " x $indent, "($id $gen R)\n";
  } else {
    # Simple object.
    print $OUT " " x $indent, "$object\n";
  }
}

# Dump PDF object.
sub dump_object {
  my ($self, $object, $label, $seen, $indent, $mode) = @_;

  # Dump output.
  my $output = "";

  # Check mode and object type.
  if ($mode eq "outline") {
    if (ref($object) and $seen->{$object}) {
      # Previously-seen object; dump the label.
      $output = "$seen->{$object}";
    } elsif (ref($object) =~ /^(?:HASH|PDF::Data)$/) {
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
    } elsif (ref($object) eq "ARRAY" and not grep { ref $_; } @{$object}) {
      # Array of simple objects.
      $output = "[...]";
    } elsif (ref($object) eq "ARRAY") {
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
    } elsif (ref($object) eq "SCALAR") {
      # Unresolved indirect reference.
      my ($id, $gen) = split /-/, ${$object};
      $gen ||= "0";
      $output .= "\"$id $gen R\"";
    }
  } elsif (ref($object) and $seen->{$object}) {
    # Previously-seen object; dump the label.
    $output = $seen->{$object};
  } elsif (ref($object) =~ /^(?:HASH|PDF::Data)$/) {
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
  } elsif (ref($object) eq "ARRAY" and not grep { ref $_; } @{$object}) {
    # Array of simple objects.
    $output = sprintf "[%s]", join ", ", map { /^\d+\.\d+$/ ? $_ : dump($_); } @{$object};
  } elsif (ref($object) eq "ARRAY") {
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
  } elsif (ref($object) eq "SCALAR") {
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

version v0.0.1

=head1 SYNOPSIS

  use PDF::Data;

=head1 DESCRIPTION

This module can read and write PDF files, and represents PDF objects as data
structures that can be readily manipulated.

=head1 METHODS

=head2 read_pdf

Read and parse a PDF file, returning a new object instance.

=head2 write_pdf

Generate and write a new PDF file from the current state of the PDF data.

=head2 dump_pdf

Dump the PDF internal structure and data for debugging.

=head2 dump_outline

Dump an outline of the PDF internal structure for debugging.

=head2 merge_content_streams

Merge multiple content streams into a single content stream.

=head2 find_bbox

Find bounding box by analyzing a content stream.  This is only partially implemented.

=head2 new_bbox

Find bounding box by analyzing a content stream.  This is only partially implemented.

=head2 timestamp

Generate timestamp in PDF internal format.

=head1 INTERNAL METHODS

=head2 parse_objects

Used by read_pdf() to parse PDF objects into Perl representations.

=head2 filter_stream

Used by parse_objects() to inflate compressed streams.

=head2 resolve_references

Used by read_pdf() to replace parsed indirect object references with
direct references to the objects in question.

=head2 write_indirect_objects

Used by write_pdf() to write all indirect objects to a new PDF file.

=head2 enumerate_indirect_objects

Used by write_indirect_objects() to identify which objects in the PDF
data structure need to be indirect objects.

=head2 enumerate_shared_objects

Used by enumerate_indirect_objects() to find objects which are already
shared (referenced from multiple objects in the PDF data structure).

=head2 add_indirect_objects

Used by enumerate_indirect_objects() and enumerate_shared_objects() to
add objects to the list of indirect objects to be written out.

=head2 write_object

Used by write_indirect_objects(), and called by itself recursively, to
write direct objects out to the PDF file.

=head2 dump_object

Used by dump_pdf(), and called by itself recursively, to dump/outline
the specified PDF object.

=cut
