# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

<!-- insertion marker -->
## [v0.9.0](https://github.com/deven/PDF-Data/releases/tag/v0.9.0) - 2021-01-22

<small>[Compare with v0.1.0](https://github.com/deven/PDF-Data/compare/v0.1.0...v0.9.0)</small>

### Added

- Add PDF content stream minification. ([38f8830](https://github.com/deven/PDF-Data/commit/38f883072ef0da746939dd6990a9a4559eca53bf) by Deven T. Corzine).
- Add PDF content stream validation. ([889fef2](https://github.com/deven/PDF-Data/commit/889fef20b4aa7ac9b9b97baa3797af2024187f03) by Deven T. Corzine).
- Add support for compressing output streams. ([13810e9](https://github.com/deven/PDF-Data/commit/13810e961b9554462dcfb8d5c10eec93469f0c59) by Deven T. Corzine).
- Add optional $time parameters for PDF output. ([eb9a935](https://github.com/deven/PDF-Data/commit/eb9a93581f3ed1c664899f24e192f88f4cf6bbc9) by Deven T. Corzine).
- Add pdf_file_data(), rewrite write_pdf(). ([1351b84](https://github.com/deven/PDF-Data/commit/1351b84be25c29fcaa006ce1feba997bd2ad5925) by Deven T. Corzine).

### Fixed

- Fix the compress_stream() method. ([85f0fce](https://github.com/deven/PDF-Data/commit/85f0fcee4a8f7d58ef99d0c819e05281df9d6d77) by Deven T. Corzine).
- Fix method call to compress streams. ([8e486fe](https://github.com/deven/PDF-Data/commit/8e486fef94ae66d4edbe8a69d001dbdd2b0e0943) by Deven T. Corzine).
- Fix bug in pdf_file_data() mangling xref table. ([ba3ad25](https://github.com/deven/PDF-Data/commit/ba3ad255ec4e7bdc4f2475ee7892ce368a412dbf) by Deven T. Corzine).

### Removed

- Remove filter key from stream after decompressing. ([9113aff](https://github.com/deven/PDF-Data/commit/9113aff05629ce99a208ab344ede4a623858b909) by Deven T. Corzine).

## [v0.1.0](https://github.com/deven/PDF-Data/releases/tag/v0.1.0) - 2020-12-14

<small>[Compare with v0.0.1](https://github.com/deven/PDF-Data/compare/v0.0.1...v0.1.0)</small>

### Added

- Add clone() method. ([17c4920](https://github.com/deven/PDF-Data/commit/17c4920c6ac299a41c132e1be45533ca33759574) by Deven T. Corzine).
- Add new_bbox() and method examples. ([70468f7](https://github.com/deven/PDF-Data/commit/70468f778c1aef985c0fe50ec3b78c251a223d2b) by Deven T. Corzine).
- Add is_hash/is_array/is_stream utility functions. ([20fc11c](https://github.com/deven/PDF-Data/commit/20fc11cbb779475f5019a2ae2b3a76b76be27040) by Deven T. Corzine).

### Fixed

- Fix handling of page count for append_page(). ([c27a915](https://github.com/deven/PDF-Data/commit/c27a9152fae719692e2301b48db045088ff15fb2) by Deven T. Corzine).
- Fix dump_outline() method. ([e71e73c](https://github.com/deven/PDF-Data/commit/e71e73cddc3f89788b2b3fa9761bc916cd0d571f) by Deven T. Corzine).
- Fix enumerate_shared_objects() ancestor check. ([f28b517](https://github.com/deven/PDF-Data/commit/f28b517b98c47e1f96a1b6bcc9117b4026efd20b) by Deven T. Corzine).

## [v0.0.1](https://github.com/deven/PDF-Data/releases/tag/v0.0.1) - 2020-11-17

<small>[Compare with first commit](https://github.com/deven/PDF-Data/compare/d9eacbf5f7c61f4c1b8bad152d5d814cb10a1c7d...v0.0.1)</small>

### Added

- Add initial version of PDF::Data module. (v0.0.1) ([d9eacbf](https://github.com/deven/PDF-Data/commit/d9eacbf5f7c61f4c1b8bad152d5d814cb10a1c7d) by Deven T. Corzine).

