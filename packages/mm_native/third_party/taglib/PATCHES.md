# Local changes to TagLib 2.3.2

* Removed: mod/it/s3m/xm, shorten, matroska and all CMake files.
* `mpeg/id3v2/id3v2tag.cpp`, `flac/flacfile.cpp`: when the rendered tag fits
  into the existing tag area, the area is reused regardless of how much
  padding remains (upstream shrinks padding larger than 1 % of the file to
  1 KiB / 4 KiB, which turns a small edit into a full file rewrite).
