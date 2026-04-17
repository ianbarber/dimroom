Regenerate icon artifacts:

    bin/build-icon.sh

This runs `dimroom-icongen` (from `Packages/AppIcon`) to render all icon sizes, then uses `iconutil` to produce the `.icns`. The 1024px PNG is the source-of-record master for visual review.
