# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

<!-- insertion marker -->
## [v1.0.1](https://github.com/deven/PDF-Data/releases/tag/v1.0.1) - 2022-07-02

<small>[Compare with v1.0.0](https://github.com/deven/PDF-Data/compare/v1.0.0...v1.0.1)</small>

### Added

- Add Dist::Zilla "PruneFiles" plugin to exclude "dist" directory. ([903294f](https://github.com/deven/PDF-Data/commit/903294f4f7efe57a214c3e4393c1a2f2c928b97b) by Deven T. Corzine).
- Add documentation for remaining internal methods. ([4377c79](https://github.com/deven/PDF-Data/commit/4377c79d5f59917403793c3b0207c5dbc4295450) by Deven T. Corzine).
- Add support for U.S. Legal page size (8.5" x 14"). ([c77e2c3](https://github.com/deven/PDF-Data/commit/c77e2c35bde5eba45e9a388d89a53bd18f3b98f4) by Deven T. Corzine).

### Fixed

- Fix validate_page_tree() to return leaf node count. ([9d95ab8](https://github.com/deven/PDF-Data/commit/9d95ab83100da14f2c6313d3914c3fd20167a16c) by Deven T. Corzine).
- Fix default value for --output_file to use standard output. ([bff90aa](https://github.com/deven/PDF-Data/commit/bff90aaa8b5d1c034800c1ca221212334ff28395) by Deven T. Corzine).

### Removed

- Remove unused $last_object variable. ([bf8e491](https://github.com/deven/PDF-Data/commit/bf8e491ab30ff2e218f192cda4d58e5df7d8bf5c) by Deven T. Corzine).

## [v1.0.0](https://github.com/deven/PDF-Data/releases/tag/v1.0.0) - 2022-06-24

<small>[Compare with v0.9.9](https://github.com/deven/PDF-Data/compare/v0.9.9...v1.0.0)</small>

### Added

- Add --compress and --minify options. ([2bc377e](https://github.com/deven/PDF-Data/commit/2bc377e9ed96eb615ee02bd546a11e9e2493bc97) by Deven T. Corzine).
- Add --output_file option. ([a357fc9](https://github.com/deven/PDF-Data/commit/a357fc9e3ec13e16f1f1447a0546a552c451a8ee) by Deven T. Corzine).
- Add generated "README.md" file. ([e34c88b](https://github.com/deven/PDF-Data/commit/e34c88bf32857ca76708e6b7ae8b9d2fc73f4f69) by Deven T. Corzine).
- Add ".gitignore" file. ([8718a5a](https://github.com/deven/PDF-Data/commit/8718a5a0c28f7f2b9b66803c0acc376d2bb06fcd) by Deven T. Corzine).
- Add new Dist::Zilla plugins. ([12070f4](https://github.com/deven/PDF-Data/commit/12070f473e06d3219e71e4fba11fe6912e81e0d0) by Deven T. Corzine).
- Add "dist.ini" file for Dist::Zilla. ([4b818bd](https://github.com/deven/PDF-Data/commit/4b818bd5ebb868b338b04dcde8f5fecd9f78825a) by Deven T. Corzine).
- Add basic test case for loading PDF::Data module. ([2655106](https://github.com/deven/PDF-Data/commit/265510689a8eb123c9004c5a304efe21d53e34f5) by Deven T. Corzine).
- Add support for ISO standard paper sizes A0 through A8. ([a7d5bbb](https://github.com/deven/PDF-Data/commit/a7d5bbbbee4b75915ef9a4371434f1b77742b7d2) by Deven T. Corzine).
- Add "pdf_data" utility script. ([418b38f](https://github.com/deven/PDF-Data/commit/418b38f5bf90929af4c0a938f8c017c6b4a28271) by Deven T. Corzine).

### Fixed

- Fix parsing of larger streams. ([043f98f](https://github.com/deven/PDF-Data/commit/043f98f359d02329f41f62530c3a7d4eb8c3d8c6) by Deven T. Corzine).

### Changed

- Change local library path after moving "pdf_data" script to "bin". ([c046ac5](https://github.com/deven/PDF-Data/commit/c046ac5b8acb46075127ba0c6c78dd1bb95d41d0) by Deven T. Corzine).

## [v0.9.9](https://github.com/deven/PDF-Data/releases/tag/v0.9.9) - 2022-03-04

<small>[Compare with v0.9.0](https://github.com/deven/PDF-Data/compare/v0.9.0...v0.9.9)</small>

### Added

- Add matrix utility methods. ([f764b06](https://github.com/deven/PDF-Data/commit/f764b06414a52cf0e7efea8fa0d5452f97402780) by Deven T. Corzine).
- Add round() utility method. ([c48405f](https://github.com/deven/PDF-Data/commit/c48405fc0e359fd5cc7a162b4de983a2bc044687) by Deven T. Corzine).
- Add PDF::Data->parse_data() method. ([2d81f2f](https://github.com/deven/PDF-Data/commit/2d81f2ff60e8eea90413dd3831d9679f93172b70) by Deven T. Corzine).
- Add byte offsets to parsing error messages. ([e769739](https://github.com/deven/PDF-Data/commit/e769739cc301091ddc41aff4c54f28909a14d31b) by Deven T. Corzine).

### Fixed

- Fix a couple error messages. ([f3baf76](https://github.com/deven/PDF-Data/commit/f3baf76fdcaa0dba81001a32cbf3e0b92672f0c8) by Deven T. Corzine).
- Fix automatic setting of -compress flag. ([ceea208](https://github.com/deven/PDF-Data/commit/ceea208096b6c7b78196fb39f2986ef834d1571f) by Deven T. Corzine).
- Fix stream filter handling to work with array of filters. ([b587f4f](https://github.com/deven/PDF-Data/commit/b587f4fbd8a976336984d32cda356a9cfb861135) by Deven T. Corzine).
- Fix bugs in stream parsing. ([b44d90d](https://github.com/deven/PDF-Data/commit/b44d90dd6baaff179ce703de670703f500e1d58f) by Deven T. Corzine).
- Fix indentation of serialized directories when not minified. ([e78f1f6](https://github.com/deven/PDF-Data/commit/e78f1f67f2f5d065752b142fd33292326f859835) by Deven T. Corzine).

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

