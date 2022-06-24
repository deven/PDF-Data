# NAME

PDF::Data - Manipulate PDF files and objects as data structures

# VERSION

version v1.0.0

# SYNOPSIS

    use PDF::Data;

# DESCRIPTION

This module can read and write PDF files, and represents PDF objects as data
structures that can be readily manipulated.

# METHODS

## new

    my $pdf = PDF::Data->new(-compress => 1, -minify => 1);

Constructor to create an empty PDF::Data object instance.  Any arguments
passed to the constructor are treated as key/value pairs, and included in
the `$pdf` hash object returned from the constructor.  When the PDF file
data is generated, this hash is written to the PDF file as the trailer
dictionary.  However, hash keys starting with "-" are ignored when writing
the PDF file, as they are considered to be flags or metadata.

For example, `$pdf->{-compress}` is a flag which controls whether or not
streams will be compressed when generating PDF file data.  This flag can be
set in the constructor (as shown above), or set directly on the object.

The `$pdf->{-minify}` flag controls whether or not to save space in the
generated PDF file data by removing comments and extra whitespace from
content streams.  This flag can be used along with `$pdf->{-compress}`
to make the generated PDF file data even smaller, but this transformation
is not reversible.

## clone

    my $pdf_clone = $pdf->clone;

Deep copy the entire PDF::Data object itself.

## new\_page

    my $page = $pdf->new_page(8.5, 11);

Create a new page object with the specified size.

## copy\_page

    my $copied_page = $pdf->copy_page($page);

Deep copy a single page object.

## append\_page

    $page = $pdf->append_page($page);

Append the specified page object to the end of the PDF page tree.

## read\_pdf

    my $pdf = PDF::Data->read_pdf($file, %args);

Read a PDF file and parse it with `$pdf->parse_pdf()`, returning a new
object instance.  Any streams compressed with the /FlateDecode filter
will be automatically decompressed.  Unless the `$pdf->{-decompress}`
flag is set, the same streams will also be automatically recompressed
again when generating PDF file data.

## parse\_pdf

    my $pdf = PDF::Data->parse_pdf($data, %args);

Used by `$pdf->read_pdf()` to parse the raw PDF file data and create
a new object instance.  This method can also be called directly instead
of calling `$pdf->read_pdf()` if the PDF file data comes another source
instead of a regular file.

## write\_pdf

    $pdf->write_pdf($file, $time);

Generate and write a new PDF file from the current state of the PDF data.

The `$time` parameter is optional; if not defined, it defaults to the
current time.  If `$time` is defined but false (zero or empty string),
no timestamp will be set.

The optional `$time` parameter may be used to specify the modification
timestamp to save in the PDF metadata and to set the file modification
timestamp of the output file.  If not specified, it defaults to the
current time.  If a false value is specified, this method will skip
setting the modification time in the PDF metadata, and skip setting the
timestamp on the output file.

## pdf\_file\_data

    my $pdf_file_data = $document->pdf_file_data($time);

Generate PDF file data from the current state of the PDF data structure,
suitable for writing to an output PDF file.  This method is used by the
`write_pdf()` method to generate the raw string of bytes to be written
to the output PDF file.  This data can be directly used (e.g. as a MIME
attachment) without the need to actually write a PDF file to disk.

The optional `$time` parameter may be used to specify the modification
timestamp to save in the PDF metadata.  If not specified, it defaults to
the current time.  If a false value is specified, this method will skip
setting the modification time in the PDF metadata.

## dump\_pdf

    $pdf->dump_pdf($file);

Dump the PDF internal structure and data for debugging.

## dump\_outline

    $pdf->dump_outline($file);

Dump an outline of the PDF internal structure for debugging.

## merge\_content\_streams

    my $stream = $pdf->merge_content_streams($array_of_streams);

Merge multiple content streams into a single content stream.

## find\_bbox

    $pdf->find_bbox($content_stream);

Find bounding box by analyzing a content stream.  This is only partially implemented.

## new\_bbox

    $new_content = $pdf->new_bbox($content_stream);

Find bounding box by analyzing a content stream.  This is only partially implemented.

## timestamp

    my $timestamp = $pdf->timestamp($time);
    my $now       = $pdf->timestamp;

Generate timestamp in PDF internal format.

# UTILITY METHODS

## round

    my @numbers = $pdf->round(@numbers);

Round numeric values to 12 significant digits to avoid floating-point rounding error and
remove trailing zeroes.

## concat\_matrix

    my $matrix = $pdf->concat_matrix($transformation_matrix, $original_matrix);

Concatenate a transformation matrix with an original matrix, returning a new matrix.
This is for arrays of 6 elements representing standard 3x3 transformation matrices
as used by PostScript and PDF.

## invert\_matrix

    my $inverse = $pdf->invert_matrix($matrix);

Calculate the inverse of a matrix, if possible.  Returns undef if not invertible.

## translate

    my $matrix = $pdf->translate($x, $y);

Returns a 6-element transformation matrix representing translation of the origin to
the specified coordinates.

## scale

    my $matrix = $pdf->scale($x, $y);

Returns a 6-element transformation matrix representing scaling of the coordinate
space by the specified horizontal and vertical scaling factors.

## rotate

    my $matrix = $pdf->rotate($angle);

Returns a 6-element transformation matrix representing counterclockwise rotation of
the coordinate system by the specified angle (in degrees).

# INTERNAL METHODS

## validate

    $pdf->validate;

Used by `new()`, `parse_pdf()` and `write_pdf()` to validate some parts of
the PDF structure.

## validate\_key

    $pdf->validate_key($hash, $key, $value, $label);

Used by `validate()` to validate specific hash key values.

## get\_hash\_node

    my $hash = $pdf->get_hash_node($path);

Used by `validate_key()` to get a hash node from the PDF structure by path.

## parse\_objects

    my @objects = $pdf->parse_objects($objects, $data, $offset);

Used by `parse_pdf()` to parse PDF objects into Perl representations.

## parse\_content

    my @objects = $pdf->parse_data($data);

Uses `parse_objects()` to parse PDF objects from standalone PDF data.

## filter\_stream

    $pdf->filter_stream($stream);

Used by `parse_objects()` to inflate compressed streams.

## compress\_stream

    $new_stream = $pdf->compress_stream($stream);

Used by `write_object()` to compress streams if enabled.  This is controlled
by the `$pdf->{-compress}` flag, which is set automatically when reading a
PDF file with compressed streams, but must be set manually for PDF files
created from scratch, either in the constructor arguments or after the fact.

## resolve\_references

    $object = $pdf->resolve_references($objects, $object);

Used by `parse_pdf()` to replace parsed indirect object references with
direct references to the objects in question.

## write\_indirect\_objects

    my $xrefs = $pdf->write_indirect_objects($pdf_file_data, $objects, $seen);

Used by `write_pdf()` to write all indirect objects to a string of new
PDF file data.

## enumerate\_indirect\_objects

    $pdf->enumerate_indirect_objects($objects);

Used by `write_indirect_objects()` to identify which objects in the PDF
data structure need to be indirect objects.

## enumerate\_shared\_objects

    $pdf->enumerate_shared_objects($objects, $seen, $ancestors, $object);

Used by `enumerate_indirect_objects()` to find objects which are already
shared (referenced from multiple objects in the PDF data structure).

## add\_indirect\_objects

    $pdf->add_indirect_objects($objects, @objects);

Used by `enumerate_indirect_objects()` and `enumerate_shared_objects()`
to add objects to the list of indirect objects to be written out.

## write\_object

    $pdf->write_object($pdf_file_data, $objects, $seen, $object, $indent);

Used by `write_indirect_objects()`, and called by itself recursively, to
write direct objects out to the string of new PDF file data.

## dump\_object

    my $output = $pdf->dump_object($object, $label, $seen, $indent, $mode);

Used by `dump_pdf()`, and called by itself recursively, to dump/outline
the specified PDF object.
