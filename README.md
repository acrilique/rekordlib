# Main ideas

  - deal with the pdb and anlz formats manually with zero deps
  - use zig-sqlite plus SQLCipher to deal with the onelibrary format
  - be little opinionated: do not do any media analysis/reencoding/copying, and
  only deal with the aforementioned formats. This means providing info on the
  correct format and/or location of some files like arworks.
  - provide an easy to embed, completely static library that can easily be built
  for any platform
  
