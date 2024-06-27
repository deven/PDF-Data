# NAME

PDF::Data - Manipulate PDF files and objects as data structures

# VERSION

version v1.1.0

# SYNOPSIS

    use PDF::Data;

# DESCRIPTION

This module can read and write PDF files, and represents PDF objects as data
structures that can be readily manipulated.

# METHODS

## new

    my $pdf = PDF::Data->new(-compress => 1, -minify => 1);

Constructor to create an empty PDF::Data object instance.  Any arguments passed
to the constructor are treated as key/value pairs, and included in the `$pdf`
hash object returned from the constructor.  When the PDF file data is generated,
this hash is written to the PDF file as the trailer dictionary.  However, hash
keys starting with "-" are ignored when writing the PDF file, as they are
considered to be flags or metadata.

For example, `$pdf->{-compress}` is a flag which controls whether or not
streams will be compressed when generating PDF file data.  This flag can be set
in the constructor (as shown above), or set directly on the object.

The `$pdf->{-minify}` flag controls whether or not to save space in the
generated PDF file data by removing comments and extra whitespace from content
streams.  This flag can be used along with `$pdf->{-compress}` to make the
generated PDF file data even smaller, but this transformation is not reversible.

## clone

    my $pdf_clone = $pdf->clone;

Deep copy the entire PDF::Data object itself.

## new\_page

    my $page = $pdf->new_page;
    my $page = $pdf->new_page('LETTER');
    my $page = $pdf->new_page(8.5, 11);

Create a new page object with the specified size (in inches).  Alternatively,
certain page sizes may be specified using one of the known keywords: "LETTER"
for U.S. Letter size (8.5" x 11"), "LEGAL" for U.S. Legal size (8.5" x 14"), or
"A0" through "A8" for ISO A-series paper sizes.  The default page size is U.S.
Letter size (8.5" x 11").

## copy\_page

    my $copied_page = $pdf->copy_page($page);

Deep copy a single page object.

## append\_page

    $page = $pdf->append_page($page);

Append the specified page object to the end of the PDF page tree.

## read\_pdf

    my $pdf = PDF::Data->read_pdf($file, %args);

Read a PDF file and parse it with `$pdf->parse_pdf()`, returning a new
object instance.  Any streams compressed with the /FlateDecode filter will be
automatically decompressed.  Unless the `$pdf->{-decompress}` flag is set,
the same streams will also be automatically recompressed again when generating
PDF file data.

## parse\_pdf

    my $pdf = PDF::Data->parse_pdf($data, %args);

Used by `$pdf->read_pdf()` to parse the raw PDF file data and create a new
object instance.  This method can also be called directly instead of calling
`$pdf->read_pdf()` if the PDF file data comes another source instead of a
regular file.

## write\_pdf

    $pdf->write_pdf($file, $time);

Generate and write a new PDF file from the current state of the PDF::Data
object.

The `$time` parameter is optional; if not defined, it defaults to the current
time.  If `$time` is defined but false (zero or empty string), no timestamp
will be set.

The optional `$time` parameter may be used to specify the modification
timestamp to save in the PDF metadata and to set the file modification timestamp
of the output file.  If not specified, it defaults to the current time.  If a
false value is specified, this method will skip setting the modification time in
the PDF metadata, and skip setting the timestamp on the output file.

## pdf\_file\_data

    my $pdf_file_data = $document->pdf_file_data($time);

Generate PDF file data from the current state of the PDF data structure,
suitable for writing to an output PDF file.  This method is used by the
`$pdf->write_pdf()` method to generate the raw string of bytes to be
written to the output PDF file.  This data can be directly used (e.g. as a MIME
attachment) without the need to actually write a PDF file to disk.

The optional `$time` parameter may be used to specify the modification
timestamp to save in the PDF metadata.  If not specified, it defaults to the
current time.  If a false value is specified, this method will skip setting the
modification time in the PDF metadata.

## dump\_pdf

    $pdf->dump_pdf($file, $mode);

Dump the PDF internal structure and data for debugging.  If the `$mode`
parameter is "outline", dump only the PDF internal structure without the data.

## dump\_outline

    $pdf->dump_outline($file);

Dump an outline of the PDF internal structure for debugging.  (This method
simply calls the `$pdf->dump_pdf()` method with the `$mode` parameter
specified as "outline".)

## merge\_content\_streams

    my $stream = $pdf->merge_content_streams($array_of_streams);

Merge multiple content streams into a single content stream.

## find\_bbox

    $pdf->find_bbox($content_stream, $new);

Analyze a content stream to determine the correct bounding box for the content
stream.  The current implementation was purpose-built for a specific use case
and should not be expected to work correctly for most content streams.

The `$content_stream` parameter may be a stream object or a string containing
the raw content stream data.

The current algorithm breaks the content stream into lines, skips over various
"neutral" lines and examines the coordinates specified for certain PDF drawing
operators: "m" (moveto), "l" (lineto), "v" (curveto, initial point replicated),
"y" (curveto, final point replicated), and "c" (curveto, all points specified).

The minimum and maximum X and Y coordinates seen for these drawing operators are
used to determine the bounding box (left, bottom, right, top) for the content
stream.  The bounding box and equivalent rectangle (left, bottom, width, height)
are printed.

If the `$new` boolean parameter is set, an updated content stream is generated
with the coordinates adjusted to move the lower left corner of the bounding box
to (0, 0).  This would be better done by translating the transformation matrix.

## new\_bbox

    $new_content = $pdf->new_bbox($content_stream);

This method simply calls the `$pdf->find_bbox()` method above with `$new`
set to 1.

## timestamp

    my $timestamp = $pdf->timestamp($time);
    my $now       = $pdf->timestamp;

Generate timestamp in PDF internal format.

# UTILITY METHODS

## round

    my @numbers = $pdf->round(@numbers);

Round numeric values to 12 significant digits to avoid floating-point rounding
error and remove trailing zeroes.

## concat\_matrix

    my $matrix = $pdf->concat_matrix($transformation_matrix, $original_matrix);

Concatenate a transformation matrix with an original matrix, returning a new
matrix.  This is for arrays of 6 elements representing standard 3x3
transformation matrices as used by PostScript and PDF.

## invert\_matrix

    my $inverse = $pdf->invert_matrix($matrix);

Calculate the inverse of a matrix, if possible.  Returns `undef` if the matrix
is not invertible.

## translate

    my $matrix = $pdf->translate($x, $y);

Returns a 6-element transformation matrix representing translation of the origin
to the specified coordinates.

## scale

    my $matrix = $pdf->scale($x, $y);

Returns a 6-element transformation matrix representing scaling of the coordinate
space by the specified horizontal and vertical scaling factors.

## rotate

    my $matrix = $pdf->rotate($angle);

Returns a 6-element transformation matrix representing counterclockwise rotation
of the coordinate system by the specified angle (in degrees).

# INTERNAL METHODS

## validate

    $pdf->validate;

Used by `$pdf->new()`, `$pdf->parse_pdf()` and
`$pdf->write_pdf()` to validate some parts of the PDF structure.
Currently, `$pdf->validate()` uses `$pdf->validate_key()` to verify
that the document catalog and page tree root node exist and have the correct
type, and that the page tree root node has no parent node.  Then it calls
`$pdf->validate_page_tree()` to validate the entire page tree.

By default, if a validation error occurs, it will be output as warnings, but
the `$pdf->{-validate}` flag can be set to make the errors fatal.

## validate\_page\_tree

    my $count = $pdf->validate_page_tree($path, $page_tree_node);

Used by `$pdf->validate()`, and called by itself recursively, to validate
the PDF page tree and its subtrees.  The `$path` parameter specifies the
logical path from the root of the PDF::Data object to the page subtree, and the
`$page_tree_node` parameter specifies the actual page tree node data structure
represented by that logical path.  `$pdf->validate()` initially calls
`$pdf->validate_page_tree()` with "Root/Pages" for `$path` and
`$pdf->{Root}{Pages}` for `$page_tree_node`.

Each child of the page tree node (in `$page_tree_node->{Kids}`) should be
another page tree node for a subtree or a single page node.  In either case, the
parameters used for the next method call will be `"$path\[$i]"` for `$path`
(e.g. "Root/Pages\[0\]\[1\]") and `$page_tree_node->{Kids}[$i]` for
`$page_tree_node` (e.g.  `$pdf->{Root}{Pages}{Kids}[0]{Kids}[1]`).  These
parameters are passed to either `$pdf->validate_page_tree()` recursively
(if the child is a page tree node) or to `$pdf->validate_page()` (if the
child is a page node).

After validating the page tree, `$pdf->validate_resources()` will be called
to validate the page tree's resources, if any.

If the count of pages in the page tree is incorrect, it will be fixed.  This
method returns the total number of pages in the specified page tree.

## validate\_page

    $pdf->validate_page($path, $page);

Used by `$pdf->validate_page_tree()` to validate a single page of the PDF.
The `$path` parameter specifies the logical path from the root of the PDF::Data
object to the page, and the `$page` parameter specifies the actual page data
structure represented by that logical path.

This method will call `$pdf->merge_content_streams()` to merge the content
streams into a single content stream (if `$page->{Contents}` is an array),
then it will call `$pdf->validate_content_stream()` to validate the page's
content stream.

After validating the page, `$pdf->validate_resources()` will be called to
validate the page's resources, if any.

## validate\_resources

    $pdf->validate_resources($path, $resources);

Used by `$pdf->validate_page_tree()`, `$pdf->validate_page()` and
`$pdf->validate_xobject()` to validate associated resources.  The `$path`
parameter specifies the logical path from the root of the PDF::Data object to
the resources, and the `$resources` parameter specifies the actual resources
data structure represented by that logical path.

This method will call `validate_xobjects` for `$resources->{XObject}`, if
set.

## validate\_xobjects

    $pdf->validate_xobjects($path, $xobjects);

Used by `$pdf->validate_resources()` to validate form XObjects in the
resources.  The `$path` parameter specifies the logical path from the root of
the PDF::Data object to the hash of form XObjects, and the `$xobjects`
parameter specifies the actual hash of form XObjects represented by that logical
path.

This method simply loops across all the form XObjects in `$xobjects` and calls
`$pdf->validate_xobject()` for each of them.

## validate\_xobject

    $pdf->validate_xobject($path, $xobject);

Used by `$pdf->validate_xobjects()` to validate a form XObject.  The
`$path` parameter specifies the logical path from the root of the PDF::Data
object to the form XObject, and the `$xobject` parameter specifies the actual
form XObject represented by that logical path.

This method verifies that `$xobject` is a stream and `$xobject->{Subtype}`
is "/Form", then calls `$pdf->validate_content_stream()` with `$xobject`
to validate the form XObject content stream, then calls
`$pdf->validate_resources()` to validate the form XObject's resources, if
any.

## validate\_content\_stream

    $pdf->validate_content_stream($path, $stream);

Used by `$pdf->validate_page()` and `$pdf->validate_xobject()` to
validate a content stream.  The `$path` parameter specifies the logical path
from the root of the PDF::Data object to the content stream, and the `$stream`
parameter specifies the actual content stream represented by that logical path.

This method calls `$pdf->parse_objects()` to make sure that the content
stream can be parsed.  If the `$pdf->{-minify}` flag is set,
`$pdf->minify_content_stream()` will be called with the array of parsed
objects to minify the content stream.

## minify\_content\_stream

    $pdf->minify_content_stream($stream, $objects);

Used by `$pdf->validate_content_stream()` to minify a content stream.  The
`$stream` parameter specifies the content stream to be modified, and the
optional `$objects` parameter specifies a reference to an array of parsed
objects as returned by `$pdf->parse_objects()`.

This method calls `$pdf->parse_objects()` to populate the `$objects`
parameter if unspecified, then it calls `$pdf->generate_content_stream()`
to generate a minimal content stream for the array of objects, with no comments
and only the minimum amount of whitespace necessary to parse the content stream
correctly.  (Obviously, this means that this transformation is not reversible.)

Currently, this method also performs a sanity check by running the replacement
content stream through `$pdf->parse_objects()` and comparing the entire
list of objects returned against the original list of objects to ensure that the
replacement content stream is equivalent to the original content stream.

## generate\_content\_stream

    my $data = $pdf->generate_content_stream($objects);

Used by `$pdf->minify_content_stream()` to generate a minimal content
stream to replace the original content stream.  The `$objects` parameter
specifies a reference to an array of parsed objects as returned by
`$pdf->parse_objects()`.  These objects will be used to generate the new
content stream.

For each object in the array, this method will call an appropriate serialization
method: `$pdf->serialize_dictionary()` for dictionary objects,
`$pdf->serialize_array()` for array objects, or
`$pdf->serialize_object()` for other objects.  After serializing all the
objects, the newly-generated content stream data is returned.

## serialize\_dictionary

    $pdf->serialize_dictionary($stream, $hash);

Used by `$pdf->generate_content_stream()`,
`$pdf->serialize_dictionary()` (recursively) and
`$pdf->serialize_array()` to serialize a hash as a dictionary object.  The
`$stream` parameter specifies a reference to a string containing the data for
the new content stream being generated, and the `$hash` parameter specifies the
hash reference to be serialized.

This method will serialize all the key-value pairs of `$hash`, prefixing each
key in the hash with "/" to serialize the key as a name object, and calling an
appropriate serialization routine for each value in the hash:
`$pdf->serialize_dictionary()` for dictionary objects (recursive call),
`$pdf->serialize_array()` for array objects, or
`$pdf->serialize_object()` for other objects.

## serialize\_array

    $pdf->serialize_array($stream, $array);

Used by `$pdf->generate_content_stream()`,
`$pdf->serialize_dictionary()` and `$pdf->serialize_array()`
(recursively) to serialize an array.  The `$stream` parameter specifies a
reference to a string containing the data for the new content stream being
generated, and the `$array` parameter specifies the array reference to be
serialized.

This method will serialize all the array elements of `$array`, calling an
appropriate serialization routine for each element of the array:
`$pdf->serialize_dictionary()` for dictionary objects,
`$pdf->serialize_array()` for array objects (recursive call), or
`$pdf->serialize_object()` for other objects.

## serialize\_object

    $pdf->serialize_object($stream, $object);

Used by `$pdf->generate_content_stream()`,
`$pdf->serialize_dictionary()` and `$pdf->serialize_array()`
to serialize a simple object.  The `$stream` parameter specifies a reference to
a string containing the data for the new content stream being generated, and the
`$object` parameter specifies the pre-serialized object to be serialized to the
specified content stream data.

This method will strip leading and trailing whitespace from the pre-serialized
object if the `$pdf->{-minify}` flag is set, then append a newline
to `${$stream}` if appending the pre-serialized object would exceed 255
characters for the last line, then append a space to `${$stream}` if necessary
to parse the object correctly, then append the pre-serialized object to
`${$stream}`.

## validate\_key

    $pdf->validate_key($hash, $key, $value, $label);

Used by `$pdf->validate()` to validate specific hash key values.

## get\_hash\_node

    my $hash = $pdf->get_hash_node($path);

Used by `$pdf->validate_key()` to get a hash node from the PDF structure by
path.

## parse\_objects

    my @objects = $pdf->parse_objects($objects, $data, $offset);

Used by `$pdf->parse_pdf()` to parse PDF objects into Perl representations.

## parse\_data

    my @objects = $pdf->parse_data($data);

Uses `$pdf->parse_objects()` to parse PDF objects from standalone PDF data.

## filter\_stream

    $pdf->filter_stream($stream);

Used by `$pdf->parse_objects()` to inflate compressed streams.

## compress\_stream

    $new_stream = $pdf->compress_stream($stream);

Used by `$pdf->write_object()` to compress streams if enabled.  This is
controlled by the `$pdf->{-compress}` flag, which is set automatically when
reading a PDF file with compressed streams, but must be set manually for PDF
files created from scratch, either in the constructor arguments or after the
fact.

## resolve\_references

    $object = $pdf->resolve_references($objects, $object);

Used by `$pdf->parse_pdf()` to replace parsed indirect object references
with direct references to the objects in question.

## write\_indirect\_objects

    my $xrefs = $pdf->write_indirect_objects($pdf_file_data, $objects, $seen);

Used by `$pdf->write_pdf()` to write all indirect objects to a string of
new PDF file data.

## enumerate\_indirect\_objects

    $pdf->enumerate_indirect_objects($objects);

Used by `$pdf->write_indirect_objects()` to identify which objects in the
PDF data structure need to be indirect objects.

## enumerate\_shared\_objects

    $pdf->enumerate_shared_objects($objects, $seen, $ancestors, $object);

Used by `$pdf->enumerate_indirect_objects()` to find objects which are
already shared (referenced from multiple objects in the PDF data structure).

## add\_indirect\_objects

    $pdf->add_indirect_objects($objects, @objects);

Used by `$pdf->enumerate_indirect_objects()` and
`$pdf->enumerate_shared_objects()` to add objects to the list of indirect
objects to be written out.

## write\_object

    $pdf->write_object($pdf_file_data, $objects, $seen, $object, $indent);

Used by `$pdf->write_indirect_objects()`, and called by itself recursively,
to write direct objects out to the string of new PDF file data.

## dump\_object

    my $output = $pdf->dump_object($object, $label, $seen, $indent, $mode);

Used by `$pdf->dump_pdf()`, and called by itself recursively, to dump (or
outline) the specified PDF object.
